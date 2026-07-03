defmodule Arbiter.Agents.Claude do
  @moduledoc """
  Claude adapter implementing `Arbiter.Agents.Agent`.

  Wraps the existing `Arbiter.Worker.ClaudeSession` parsing pipeline behind
  the `Agent` behaviour. The session/parsing logic stays in
  `ClaudeSession` (callable as a library); this module is the seam that
  lets a future adapter (Codex / Aider / Gemini) replace just the argv +
  parser without forcing the worker to grow a switch statement.

  Phase B of `docs/agent-harness-design.md` — Claude is the only adapter
  today, intentionally. The two cheaper levers (model-tiering and
  multi-key rotation) ship inside *this* adapter rather than as new
  vendors:

    * `:model` opt routes through `claude --model <name>`. Resolution
      order is `opts[:model]` → `:model_tier` (resolved per-adapter via
      `Claude.Config.model_for_tier/1`) →
      `Arbiter.Agents.Claude.Config.active_model/0` → CLI default
      (no `--model` flag).
    * `:thinking` opt routes through the configured effort argv (default
      `--effort <level>` for low/medium/high; the
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
  `opts[:security]` (Dispatch / ReviewGate resolve it from the workspace);
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
  alias Arbiter.Worker.ClaudeSession

  @done_regex ~r/\barb done\b/

  # Linux enforces MAX_ARG_STRLEN = 131_072 bytes as a *per-argument* limit on
  # execve() (stricter than overall ARG_MAX). A prompt element that exceeds
  # this makes exec() fail with E2BIG (errno 7) *before the child ever runs* —
  # zero stdout, zero stderr, just an immediate exit(7). bd-11abk2: task.notes
  # accumulates the full transcript of every review round with no cap, so a
  # task with a couple of review rounds routinely exceeds this. Prompts over
  # the limit are written to a temp file and piped in via stdin instead of
  # being spliced into argv, mirroring the fix already applied to the
  # code-review diff-checking path (bd-dl49fo,
  # Arbiter.Workflows.CodeReview.Checks.invoke_via_stdin/3).
  @max_prompt_argv_bytes 131_072
  @prompt_tmp_prefix "arb_prompt_"

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

        flags =
          model_flag(opts) ++
            thinking_flag(opts) ++
            Security.permission_argv(policy) ++
            Security.settings_argv(policy) ++
            stream_flags()

        build_argv(claude, prompt, flags)

      {:error, _} = err ->
        err
    end
  end

  # Build the `sh -c` wrapped streaming argv for a `claude --print` invocation.
  # Shared by the workspace-aware path (`default_argv/2` above) and the bare
  # `Arbiter.Worker.ClaudeSession.start/1` path so both get the E2BIG fix.
  #
  # Small prompts (the common case) are spliced into argv exactly as before —
  # `sh -c 'exec "$@" < /dev/null' sh <claude> --print <prompt> <flags...>`.
  #
  # Prompts over MAX_ARG_STRLEN are written to a temp file and delivered via
  # stdin instead: `sh -c 'f="$1"; shift; exec "$@" < "$f"' sh <tmpfile>
  # <claude> --print <flags...>` (no prompt element in argv at all — `claude
  # --print` with no positional prompt reads it from stdin). The temp file's
  # path is recoverable from argv[4] by `prompt_tmpfile/1` (named with
  # `@prompt_tmp_prefix` so that lookup can't misidentify an unrelated path)
  # so the worker can unlink it once the spawned session's port exits.
  @inline_prompt_script ~s(exec "$@" < /dev/null)
  @stdin_prompt_script ~s(f="$1"; shift; exec "$@" < "$f")

  @doc false
  def build_argv(claude, prompt, flags)
      when is_binary(claude) and is_binary(prompt) and is_list(flags) do
    if byte_size(prompt) > @max_prompt_argv_bytes do
      case write_prompt_tmpfile(prompt) do
        {:ok, tmp} ->
          {:ok, ["sh", "-c", @stdin_prompt_script, "sh", tmp, claude, "--print" | flags]}

        {:error, reason} ->
          {:error, {:prompt_tmpfile_failed, reason}}
      end
    else
      {:ok, ["sh", "-c", @inline_prompt_script, "sh", claude, "--print", prompt | flags]}
    end
  end

  defp write_prompt_tmpfile(prompt) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        @prompt_tmp_prefix <> Integer.to_string(System.unique_integer([:positive])) <> ".txt"
      )

    case File.write(tmp, prompt) do
      :ok -> {:ok, tmp}
      {:error, _} = err -> err
    end
  end

  # Extract the stdin-delivery temp file path from an argv built by
  # `build_argv/3`, or `nil` when this argv used inline (mode A) delivery.
  # Used by the worker to unlink the file once the spawned port exits.
  @doc false
  def prompt_tmpfile(argv) when is_list(argv) do
    case Enum.at(argv, 4) do
      path when is_binary(path) -> if tmpfile_path?(path), do: path, else: nil
      _ -> nil
    end
  end

  # Splice `insert` (a list of argv elements, e.g. a swapped-in nudge/resume
  # prompt) right after the `--print` flag in `argv`, discarding whatever was
  # there before — the old inline prompt (mode A) or nothing at all (mode B,
  # stdin delivery, in which case the leading temp-file positional is also
  # dropped so the rebuilt argv is a plain mode-A invocation). Returns
  # `{:error, :no_print_slot}` when `argv` has no `--print` flag at all (test
  # fixtures / custom commands).
  @doc false
  def splice_prompt(argv, insert) when is_list(argv) and is_list(insert) do
    case Enum.find_index(argv, &(&1 == "--print")) do
      nil ->
        {:error, :no_print_slot}

      idx ->
        {head, [print | tail]} = Enum.split(argv, idx)

        case pop_tmpfile_positional(head) do
          {true, head} -> {:ok, head ++ [print] ++ insert ++ tail}
          {false, head} -> {:ok, head ++ [print] ++ insert ++ drop_first(tail)}
        end
    end
  end

  defp pop_tmpfile_positional(head) do
    case Enum.at(head, 4) do
      path when is_binary(path) ->
        if tmpfile_path?(path), do: {true, List.delete_at(head, 4)}, else: {false, head}

      _ ->
        {false, head}
    end
  end

  defp tmpfile_path?(path), do: Path.basename(path) |> String.starts_with?(@prompt_tmp_prefix)

  defp drop_first([_ | rest]), do: rest
  defp drop_first([]), do: []

  # The resolved `Arbiter.Agents.SecurityPolicy` for this spawn. Threaded in by
  # the caller (Dispatch / ReviewGate resolve it from the workspace); falls back to
  # the install-wide hardened default so a bare adapter call is still safe.
  defp security_policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end

  @impl true
  def auth_probe_argv(_opts \\ []) do
    # Cheapest token-validity probe: a one-word `claude --print` round-trip.
    # No streaming/model flags — we only care that the CLI authenticates. stdin
    # is closed via the sh wrapper (same as a real spawn) so the CLI doesn't
    # block waiting for piped input. An expired OAuth / bad key makes this print
    # "401 / invalid authentication credentials" and exit non-zero, which
    # Arbiter.Worker.StopReason classifies as :auth_expired.
    case resolve_claude_executable() do
      {:ok, claude} ->
        {:ok, ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", claude, "--print", "ping"]}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def spawn_env(opts \\ []) do
    # Worker runs get an isolated CLAUDE_CONFIG_DIR so the operator's personal
    # ~/.claude/CLAUDE.md (persona) can't bleed into the worker's context
    # (bd-3y2mda); the optional API key composes on top.
    ConfigDir.env() ++ api_key_env(opts) ++ base_url_env(opts)
  end

  defp api_key_env(opts) do
    case Keyword.get(opts, :api_key) || Config.resolve_api_key() do
      key when is_binary(key) and key != "" -> [{"ANTHROPIC_API_KEY", key}]
      _ -> []
    end
  end

  # Point the CLI at the local quota-capturing proxy (bd-5boun6) when the caller
  # threads an `:anthropic_base_url` opt. Dispatch / Preflight compute the URL
  # (with the workspace id baked into the path) only when the proxy is enabled,
  # so a bare adapter call still spawns against the real api.anthropic.com.
  # Set explicitly so any inherited ANTHROPIC_BASE_URL is overridden.
  defp base_url_env(opts) do
    case Keyword.get(opts, :anthropic_base_url) do
      url when is_binary(url) and url != "" -> [{"ANTHROPIC_BASE_URL", url}]
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
    # The worker already accumulates lines; here we just turn one logical
    # line into display tuples + an updated session. Tool results carry the
    # "arm_done? = false" flag so a `cat`/`grep` of the literal `arb done`
    # phrase from disk can't trip the completion sentinel.
    next = ClaudeSession.handle_data(session, line <> "\n", true)
    display = collect_display(session, next)
    {display, next}
  end

  @impl true
  def async_tool_instruction do
    "*** ASYNC TOOLS: You may run tests, linters, compilers, or any diagnostic\n" <>
      "    tool — including in parallel or with background execution modes. However,\n" <>
      "    you MUST wait for every background task to complete and read its full\n" <>
      "    output before producing your VERDICT. A VERDICT issued while any\n" <>
      "    background task is still running is invalid: you would be judging on\n" <>
      "    incomplete evidence. Do not exit, do not print your VERDICT, and do not\n" <>
      "    print `arb done` until every tool you launched has finished and you have\n" <>
      "    read its result."
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
  # Today the worker lives outside the adapter and owns the buffered
  # state — so `parse_line/2` is only invoked from the adapter test surface
  # and from the agent-routing scaffolding. The ReviewGate/worker hot-path
  # still calls ClaudeSession directly. We keep the adapter parse_line
  # callable so future adapters can plug in without rewriting the worker.
  defp collect_display(prev, next) do
    prev_len = length(Map.get(prev, :output_lines, []))
    new_len = length(Map.get(next, :output_lines, []))

    added =
      next.output_lines
      |> Enum.take(new_len - prev_len)
      |> Enum.reverse()

    # All lines added through ClaudeSession.handle_data are display lines;
    # the only ones the worker treats as non-arming are tool-result lines,
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
