defmodule Arbiter.Agents.Gemini do
  @moduledoc """
  Gemini agent adapter implementing `Arbiter.Agents.Agent`.

  Favors `agy` CLI binary, falling back to `gemini` CLI binary if `agy` is not on PATH.
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Gemini.Config
  alias Arbiter.Agents.SecurityPolicy

  @done_regex ~r/\barb done\b/

  # The gemini-cli's own default model (`DEFAULT_GEMINI_MODEL`) — what the CLI
  # runs when we pass no `--model`. Used only to stamp the usage ledger /
  # dashboards via `resolved_model/1`; dispatch behaviour is unchanged.
  @default_model "gemini-2.5-pro"

  @impl true
  def provider, do: "gemini"

  # Gemini/agy CLIs have no per-tool deny lists or fine-grained permission modes
  # analogous to Claude's --permission-mode + --settings. The policy is honored
  # at the coarse level: :bypass maps to --dangerously-skip-permissions / --skip-trust;
  # :auto and :strict omit those flags so the tool does not bypass its own
  # permission checks. Operator-level deny rules and sandbox scoping are not yet
  # enforceable — hence enforced? returns false so the REST posture surface can
  # show the gap rather than claiming full enforcement.
  @impl true
  def security_enforced?, do: false

  @impl true
  def done_sentinel, do: @done_regex

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    case resolve_executable() do
      {:ok, {type, exec}} ->
        policy = security_policy(opts)
        inner = build_argv(type, exec, prompt, opts, policy)
        {:ok, ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | inner]}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def auth_probe_argv(_opts \\ []) do
    # Cheap token-validity probe for whichever CLI is on PATH. A bad/expired key
    # makes Gemini print "API key not valid" / "RESOURCE_EXHAUSTED" (or 401) and
    # exit non-zero — classified by Arbiter.Worker.StopReason.
    case resolve_executable() do
      {:ok, {_type, exec}} ->
        {:ok, ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", exec, "-p", "ping"]}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def spawn_env(opts \\ []) do
    api_key_env(opts) ++ thinking_env(opts)
  end

  defp api_key_env(opts) do
    case Keyword.get(opts, :api_key) || Config.resolve_api_key() do
      key when is_binary(key) and key != "" ->
        [
          {"GEMINI_API_KEY", key},
          {"GOOGLE_GENAI_API_KEY", key}
        ]

      _ ->
        []
    end
  end

  defp thinking_env(opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) and level != "" -> Config.thinking_env(level)
      _ -> []
    end
  end

  @impl true
  def async_tool_instruction do
    "*** TOOLS: Run all tools synchronously — wait inline for each result\n" <>
      "    before proceeding to the next. Do not use background execution modes. When\n" <>
      "    calling `run_command`, you MUST set `WaitMsBeforeAsync` to `10000` to prevent\n" <>
      "    the command from being backgrounded, as background execution is not supported\n" <>
      "    in this environment and will abort your session prematurely."
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
    # Gemini and agy print output line-by-line. Since they may output plain text
    # or json, we support basic text streaming fallback: treat each line as a
    # raw output line.
    next = Map.update!(session, :output_lines, &[line | &1])
    {[{line, !tool_result_line?(line)}], next}
  end

  @impl true
  def usage_attrs(session) do
    Map.get(session, :usage, %{})
    |> Map.put(:provider, provider())
  end

  # The gemini / agy CLI emits no stream-json `init` event the worker can read
  # the model from (unlike Claude), so we resolve it up front for the ledger /
  # dashboards. Mirrors `resolve_model/1` (explicit `:model` → tier → workspace
  # `active_model`) but adds a concrete terminal fallback: when nothing is
  # configured the CLI defaults to `gemini-2.5-pro` (`DEFAULT_GEMINI_MODEL` in
  # the gemini-cli), so recording that is accurate even though we pass no
  # `--model` flag in that case.
  #
  # bd-d2yut8: agy does accept `--model` (bd-2fzwlc's "agy has no overlapping
  # model catalogue" read only applied to the *upstream-gemini* ids this
  # module tried first; agy has its own catalogue, now covered by
  # `Config.default_tier_models(:agy)`). So agy runs the same explicit →
  # tier → workspace `active_model` chain as the gemini branch, just against
  # its own tier map — no more forced-`nil` short-circuit. There is still no
  # known agy-CLI default to fall back to when nothing resolves (unlike
  # gemini-cli's documented `DEFAULT_GEMINI_MODEL`), so that terminal
  # fallback stays gemini-only.
  @impl true
  def resolved_model(opts \\ []) do
    case resolve_executable() do
      {:ok, {:agy, _}} ->
        resolve_model(:agy, opts)

      _ ->
        resolve_model(:gemini, opts) || @default_model
    end
  end

  # ---- Internals ---------------------------------------------------------

  defp tool_result_line?(line) when is_binary(line),
    do: String.starts_with?(line, "⏴ ")

  defp tool_result_line?(_), do: false

  # Splice `insert` (a nudge/resume prompt, see the two shapes below) into a
  # stashed `default_argv/2` invocation. Both the `:agy` and `:gemini`
  # branches build argv as `[…, exec, "-p", prompt, flags…]` (no `--`
  # separator, no `--print` name — see `build_argv/5` above), so the prompt
  # slot is always the element right after `"-p"`; only the resume
  # (`--conversation`) translation differs between the two CLIs.
  #
  # `["--resume", session_id, prompt]` → the worker's resume insert. Only
  # `agy` accepts a `--conversation <id>` flag (bd-b7e33c); the upstream
  # `gemini` CLI has no session-resume mechanism at all, so that branch
  # returns an explicit error instead of emitting an invocation `gemini`
  # would reject or silently misinterpret. `--print-timeout`/`--model`/
  # `--effort` (and every other flag) are left exactly where they were —
  # only the prompt is swapped and `--conversation <id>` is inserted right
  # after it.
  #
  # `[nudge]` → a gate-nudge swap-in: only the prompt changes, on either
  # branch.
  #
  # Returns `{:error, :no_print_slot}` when `argv` has no `"-p"` flag at all
  # (test fixtures / custom commands).
  @doc false
  def splice_prompt(argv, insert) when is_list(argv) and is_list(insert) do
    case Enum.find_index(argv, &(&1 == "-p")) do
      nil ->
        {:error, :no_print_slot}

      idx ->
        {head, [_old_prompt | tail]} = Enum.split(argv, idx + 1)
        exec = Enum.at(head, -2)

        case insert do
          ["--resume", session_id, prompt] ->
            if agy_executable?(exec) do
              {:ok, head ++ [prompt, "--conversation", session_id] ++ tail}
            else
              {:error, :resume_unsupported}
            end

          [nudge] ->
            {:ok, head ++ [nudge] ++ tail}
        end
    end
  end

  defp agy_executable?(exec) when is_binary(exec), do: Path.basename(exec) == "agy"
  defp agy_executable?(_), do: false

  @doc """
  Which Gemini-family CLI this host will actually run, and where.

  Returns `{:ok, {:agy, path}}` when the Antigravity fork is on `PATH` (it wins),
  `{:ok, {:gemini, path}}` for the upstream CLI, or
  `{:error, {:executable_not_found, "agy or gemini"}}` when neither is installed.

  Public because the two CLIs do not share a config format: which one is on
  `PATH` decides whether a worktree-local MCP config is even readable
  (`Arbiter.MCP.AgentConfig.Gemini`, bd-m8geh4). Also public so
  `Arbiter.Quota.provider_code/1` (bd-7qj58o) can key the quota-gate lookup
  off the same PATH probe instead of duplicating it and risking drift.
  """
  @spec resolve_executable() ::
          {:ok, {:agy | :gemini, String.t()}} | {:error, {:executable_not_found, String.t()}}
  def resolve_executable do
    case System.find_executable("agy") do
      path when is_binary(path) ->
        {:ok, {:agy, path}}

      nil ->
        case System.find_executable("gemini") do
          path when is_binary(path) ->
            {:ok, {:gemini, path}}

          nil ->
            {:error, {:executable_not_found, "agy or gemini"}}
        end
    end
  end

  # The resolved `Arbiter.Agents.SecurityPolicy` for this spawn. Falls back to
  # the install-wide default so a bare adapter call is still safe.
  defp security_policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end

  # :bypass → pass skip-permissions so the tool doesn't gate on confirmations.
  # :auto/:strict → omit the flag; the tool will not bypass its own permission
  # checks. Operator deny rules are not enforceable on Gemini/agy (no --settings
  # equivalent) — see security_enforced?/0.
  defp build_argv(:agy, exec, prompt, opts, %SecurityPolicy{permissions: %{mode: :bypass}}) do
    [exec, "-p", prompt, "--dangerously-skip-permissions"] ++
      agy_model_and_effort_argv(opts) ++ output_format_flag() ++ print_timeout_flag(opts)
  end

  defp build_argv(:agy, exec, prompt, opts, _policy) do
    [exec, "-p", prompt] ++
      agy_model_and_effort_argv(opts) ++ output_format_flag() ++ print_timeout_flag(opts)
  end

  defp build_argv(:gemini, exec, prompt, opts, %SecurityPolicy{permissions: %{mode: :bypass}}) do
    [exec, "-p", prompt, "--skip-trust", "-y"] ++
      model_flag(:gemini, opts) ++ thinking_flag(:gemini, opts) ++ output_format_flag()
  end

  defp build_argv(:gemini, exec, prompt, opts, _policy) do
    [exec, "-p", prompt] ++
      model_flag(:gemini, opts) ++ thinking_flag(:gemini, opts) ++ output_format_flag()
  end

  # Both the upstream `gemini` CLI and the `agy` fork support
  # `--output-format stream-json` (confirmed live against installed agy
  # v1.1.11 — bd-2fzwlc). Prior to bd-2fzwlc this flag was omitted on the
  # `:agy` branches on the mistaken belief that agy had no stream-json
  # support; in fact agy was being invoked in plain-text mode the whole time,
  # so every agy session emitted nothing `Arbiter.Agents.Gemini.Stream` could
  # parse — the root cause of every Gemini `usage_events` row carrying zero
  # tokens/cost, since `resolve_executable/0` prefers `agy` over `gemini`.
  defp output_format_flag, do: ["--output-format", "stream-json"]

  # bd-1xss5z: `agy` hard-codes a 5-minute `--print-timeout` on print-mode
  # turns — a review that reads ~300k tokens of diff/context routinely blows
  # past that, and agy responds by cutting the turn short and returning
  # partial output under a `SUCCESS` status (see
  # `Arbiter.Worker.StopReason`'s `:agent_print_timeout` category and
  # `Arbiter.Agents.Gemini.Stream`'s docs on agy's wire schema). Threading the
  # caller's own `:timeout_ms` (ReviewGate resolves it from
  # `review_gate.timeout_ms`, live, per pass) through as `--print-timeout`
  # gives agy a budget that actually matches the harness's own — the
  # alternative is agy timing out silently well inside a longer harness-level
  # deadline that never gets a chance to fire.
  #
  # Upstream `gemini` has no equivalent flag, so this is agy-only; the
  # `:gemini` branches never call it.
  defp print_timeout_flag(opts) do
    case Keyword.get(opts, :timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ["--print-timeout", "#{max(div(ms, 1000), 1)}s"]
      _ -> []
    end
  end

  # bd-d2yut8 Finding 2: model ids in the agy tier map carry their own effort
  # suffix (`-low`/`-medium`/`-high`, e.g. `gemini-3.1-pro-high`). Passing
  # `--effort` alongside such an id sends two conflicting effort signals with
  # undefined precedence in agy — the operator decision is "never both", so
  # `--effort` is only emitted for a suffix-free resolved model (or when no
  # model resolves at all).
  defp agy_model_and_effort_argv(opts) do
    model = resolve_model(:agy, opts)

    model_part =
      case model do
        nil -> []
        m -> ["--model", m]
      end

    effort_part = if effort_suffixed?(model), do: [], else: thinking_flag(:agy, opts)

    model_part ++ effort_part
  end

  defp effort_suffixed?(model) when is_binary(model),
    do: Regex.match?(~r/-(low|medium|high)$/, model)

  defp effort_suffixed?(_), do: false

  defp model_flag(executable, opts) do
    case resolve_model(executable, opts) do
      nil -> []
      model when is_binary(model) -> ["--model", model]
    end
  end

  defp resolve_model(executable, opts) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        case Keyword.get(opts, :model_tier) do
          tier when is_binary(tier) and tier != "" ->
            Config.model_for_tier(tier, executable) || Config.active_model()

          _ ->
            Config.active_model()
        end
    end
  end

  defp thinking_flag(executable, opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) and level != "" -> Config.thinking_argv(level, executable)
      _ -> []
    end
  end
end
