defmodule Arbiter.Agents.Claude do
  @moduledoc """
  Claude adapter implementing `Arbiter.Agents.Agent`.

  Wraps the existing `Arbiter.Polecat.ClaudeSession` parsing pipeline behind
  the `Agent` behaviour. The session/parsing logic stays in
  `ClaudeSession` (callable as a library); this module is the seam that
  lets a future adapter (Codex / Aider / Gemini) replace just the argv +
  parser without forcing the polecat to grow a switch statement.

  Phase B of `docs/agent-harness-design.md` — Claude is the only adapter
  today, intentionally. The two cheaper levers (model-tiering and
  multi-key rotation) ship inside *this* adapter rather than as new
  vendors:

    * `:model` opt routes through `claude --model <name>`. Resolution
      order is `opts[:model]` → `:model_tier` (resolved per-adapter via
      `Claude.Config.model_for_tier/1`) →
      `Arbiter.Agents.Claude.Config.active_model/0` → CLI default
      (no `--model` flag).
    * `:thinking` opt routes through the configured reasoning-effort
      argv (default `--reasoning-effort <level>` for low/medium/high; the
      cheap second lever the moduledoc has always called out). Resolved
      via `Claude.Config.thinking_argv/1`.
    * Multi-key rotation: when `api_keys` is set on the workspace, each
      session picks the next key via per-process round-robin and exports
      `ANTHROPIC_API_KEY` for the spawn — addresses rate-limit relief
      without new harness code.

  All three default off, so workspaces that haven't opted in see
  unchanged behavior.

  ## Security posture

  `default_argv/2` also bakes in the spawn's **security posture**. The
  caller threads a resolved `Arbiter.Agents.SecurityPolicy` in via
  `opts[:security]` (Sling / Tribunal resolve it from the workspace);
  `Arbiter.Agents.Claude.Security` maps it to `--permission-mode` /
  `--dangerously-skip-permissions` + an inline `--settings` deny/allow
  document. A bare call with no `:security` opt falls back to the install-wide
  hardened default (`SecurityPolicy.default/0`) — so every spawn is
  safe-by-default and **none** inherits the operator's personal
  `~/.claude/settings.json`.
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Claude.Config
  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Agents.Claude.Security
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Polecat.ClaudeSession

  @done_regex ~r/\barb done\b/

  @impl true
  def provider, do: "claude"

  @impl true
  def security_enforced?, do: true

  @impl true
  def done_sentinel, do: @done_regex

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    case resolve_claude_executable() do
      {:ok, claude} ->
        policy = security_policy(opts)

        inner =
          [claude, "--print", prompt] ++
            model_flag(opts) ++
            thinking_flag(opts) ++
            Security.permission_argv(policy) ++
            Security.settings_argv(policy) ++
            stream_flags()

        {:ok, ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | inner]}

      {:error, _} = err ->
        err
    end
  end

  # The resolved `Arbiter.Agents.SecurityPolicy` for this spawn. Threaded in by
  # the caller (Sling / Tribunal resolve it from the workspace); falls back to
  # the install-wide hardened default so a bare adapter call is still safe.
  defp security_policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end

  @impl true
  def spawn_env(opts \\ []) do
    # Acolyte runs get an isolated CLAUDE_CONFIG_DIR so the operator's personal
    # ~/.claude/CLAUDE.md (persona) can't bleed into the worker's context
    # (bd-3y2mda); the optional API key composes on top.
    ConfigDir.env() ++ api_key_env(opts)
  end

  defp api_key_env(opts) do
    case Keyword.get(opts, :api_key) || Config.resolve_api_key() do
      key when is_binary(key) and key != "" -> [{"ANTHROPIC_API_KEY", key}]
      _ -> []
    end
  end

  @impl true
  def init_session(_opts \\ []) do
    %{
      line_buf: "",
      output_lines: [],
      usage: %{},
      activity: nil,
      activity_at: nil
    }
  end

  @impl true
  def parse_line(session, line) when is_binary(line) do
    # The polecat already accumulates lines; here we just turn one logical
    # line into display tuples + an updated session. Tool results carry the
    # "arm_done? = false" flag so a `cat`/`grep` of the literal `arb done`
    # phrase from disk can't trip the completion sentinel.
    next = ClaudeSession.handle_data(session, line <> "\n", true)
    display = collect_display(session, next)
    {display, next}
  end

  @impl true
  def usage_attrs(session),
    do: ClaudeSession.usage_summary(session) |> Map.put(:provider, provider())

  # ---- Internals ---------------------------------------------------------

  # The session map updated by ClaudeSession.handle_data/3 contains an
  # :output_lines list (newest-first). Whatever lines were appended on this
  # call are the display tuples we owe the caller. We diff old vs new and
  # synthesize the {text, arm_done?} tuples.
  #
  # Today the polecat lives outside the adapter and owns the buffered
  # state — so `parse_line/2` is only invoked from the adapter test surface
  # and from the agent-routing scaffolding. The Tribunal/polecat hot-path
  # still calls ClaudeSession directly. We keep the adapter parse_line
  # callable so future adapters can plug in without rewriting the polecat.
  defp collect_display(prev, next) do
    prev_len = length(Map.get(prev, :output_lines, []))
    new_len = length(Map.get(next, :output_lines, []))

    added =
      next.output_lines
      |> Enum.take(new_len - prev_len)
      |> Enum.reverse()

    # All lines added through ClaudeSession.handle_data are display lines;
    # the only ones the polecat treats as non-arming are tool-result lines,
    # which ClaudeSession's emit path already exempts from the done sentinel
    # via the `detect_done?` flag. We mirror that here as a best-effort:
    # lines starting with the tool-result glyph are not arming.
    Enum.map(added, fn line ->
      {line, !tool_result_line?(line)}
    end)
  end

  defp tool_result_line?(line) when is_binary(line),
    do: String.starts_with?(line, "⏴ ")

  defp tool_result_line?(_), do: false

  defp model_flag(opts) do
    case resolve_model(opts) do
      nil -> []
      model when is_binary(model) -> ["--model", model]
    end
  end

  defp resolve_model(opts) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        case Keyword.get(opts, :model_tier) do
          tier when is_binary(tier) and tier != "" ->
            Config.model_for_tier(tier) || Config.active_model()

          _ ->
            Config.active_model()
        end
    end
  end

  defp thinking_flag(opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) and level != "" -> Config.thinking_argv(level)
      _ -> []
    end
  end

  defp stream_flags, do: ["--output-format", "stream-json", "--verbose"]

  defp resolve_claude_executable do
    case System.find_executable("claude") do
      nil -> {:error, {:executable_not_found, "claude"}}
      path -> {:ok, path}
    end
  end
end
