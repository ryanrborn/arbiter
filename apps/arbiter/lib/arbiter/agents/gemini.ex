defmodule Arbiter.Agents.Gemini do
  @moduledoc """
  Gemini agent adapter implementing `Arbiter.Agents.Agent`.

  Favors `agy` CLI binary, falling back to `gemini` CLI binary if `agy` is not on PATH.

  The two CLIs are not interchangeable — see `resolve_executable/0`. On the agy
  branch the spawn's security posture is split across
  `Arbiter.Agents.Gemini.Security` (argv + the generated settings document) and
  `Arbiter.Agents.Gemini.ConfigDir` (the isolated `$HOME` that document lands
  in, injected by `spawn_env/1`); the upstream `gemini` branch has no analogue
  of either (bd-7s29yq).
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Gemini.Config
  alias Arbiter.Agents.Gemini.ConfigDir
  alias Arbiter.Agents.Gemini.Security
  alias Arbiter.Agents.SecurityPolicy

  @done_regex ~r/\barb done\b/

  # The gemini-cli's own default model (`DEFAULT_GEMINI_MODEL`) — what the CLI
  # runs when we pass no `--model`. Used only to stamp the usage ledger /
  # dashboards via `resolved_model/1`; dispatch behaviour is unchanged.
  @default_model "gemini-2.5-pro"

  # bd-svczq4: the auth probe's prompt, and the two numbers that bound it. The
  # fraction keeps agy's own `--print-timeout` strictly inside the harness
  # watchdog so agy is always the one to yield; the fallback only applies to a
  # bare adapter call that names no watchdog, since `Arbiter.Agents.Preflight`
  # always threads one through.
  @probe_prompt "ping"
  @probe_timeout_fraction_pct 80
  @probe_fallback_watchdog_ms 120_000

  @impl true
  def provider, do: "gemini"

  @doc """
  Whether this host's Gemini-family spawn actually enforces the resolved
  `Arbiter.Agents.SecurityPolicy` (bd-7s29yq / T6b).

  True only when **both** halves of the seam are present:

    * the CLI on `PATH` is `agy` — the upstream `gemini` CLI has no analogue of
      `permissions.allow/deny` and still runs with whatever posture it
      inherits, so it answers `false`; and
    * worker config isolation is on (`Arbiter.Agents.Gemini.ConfigDir.enabled?/0`)
      — agy reads its posture only from `$HOME/.gemini/antigravity-cli/settings.json`,
      so without an Arbiter-owned `$HOME` there is nowhere to put the generated
      document and the spawn silently inherits the operator's
      `always-proceed`-with-no-deny-list file. That is precisely the state
      bd-7s29yq found, and the REST posture surface must keep showing it as
      *not* enforced.

  When both hold, `permissions.deny` is a hard block in every mode — confirmed
  live, including under `--dangerously-skip-permissions`; see
  `Arbiter.Agents.Gemini.Security`'s moduledoc for the probe results and for
  the two things agy does *not* enforce.
  """
  @impl true
  def security_enforced? do
    match?({:ok, {:agy, _}}, resolve_executable()) and ConfigDir.enabled?()
  end

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
  def auth_probe_argv(opts \\ []) do
    # Cheap token-validity probe for whichever CLI is on PATH. A bad/expired key
    # makes Gemini print "API key not valid" / "RESOURCE_EXHAUSTED" (or 401) and
    # exit non-zero — classified by Arbiter.Worker.StopReason.
    #
    # bd-481sz7 AC3: without `--output-format stream-json` the probe's stdout
    # is plain text `Arbiter.Agents.Gemini.Stream` can't parse for usage, so
    # every preflight row landed with zero tokens even on a healthy probe —
    # the same root cause bd-2fzwlc found on the main spawn path.
    #
    # bd-svczq4: the word "ping" is not a ping to an agentic CLI. This probe
    # runs with tools enabled and an Arbiter-worker `GEMINI.md` in its isolated
    # HOME, and a measured run answered it with 21 model calls over 102s — well
    # past the harness watchdog, which then reported a hang that had not
    # happened. Without a `--print-timeout` agy runs on its own 5-minute
    # print-mode default, so nothing makes agy yield before the harness gives
    # up and no exit status is ever observed. Deriving one from the harness
    # watchdog makes agy the first to yield and report a real status.
    case resolve_executable() do
      {:ok, {:agy, exec}} ->
        {:ok,
         ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", exec, "-p", @probe_prompt] ++
           output_format_flag() ++ probe_print_timeout_flag(opts)}

      {:ok, {:gemini, exec}} ->
        # Upstream `gemini` has no `--print-timeout` (see `print_timeout_flag/1`);
        # the harness watchdog stays its only bound.
        {:ok,
         ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", exec, "-p", @probe_prompt] ++
           output_format_flag()}

      {:error, _} = err ->
        err
    end
  end

  # agy's own turn budget for a probe, kept strictly *inside* the harness
  # watchdog (`Arbiter.Agents.Preflight.timeout_ms/2`, threaded in as
  # `:timeout_ms`) so agy always yields first and the harness sees a real exit
  # status instead of having to guess from silence. A bare adapter call that
  # names no watchdog still gets a bound — never agy's 5-minute default.
  defp probe_print_timeout_flag(opts) do
    watchdog =
      case Keyword.get(opts, :timeout_ms) do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> @probe_fallback_watchdog_ms
      end

    seconds = max(div(watchdog * @probe_timeout_fraction_pct, 100 * 1000), 1)
    ["--print-timeout", "#{seconds}s"]
  end

  @doc """
  Env pairs for an agy/gemini spawn.

  Besides the API key and thinking level, this injects the isolated `HOME`
  (`Arbiter.Agents.Gemini.ConfigDir`) that carries the generated agy permission
  posture and the Arbiter-owned `GEMINI.md` — without it agy reads the
  operator's own `~/.gemini` (bd-7s29yq). Pass the spawn's `:worktree` (or
  `:worktree_path`) and `:security` policy so the right directory and posture
  are prepared; a caller with neither still gets an isolated (default-policy)
  HOME rather than the operator's.
  """
  @impl true
  def spawn_env(opts \\ []) do
    api_key_env(opts) ++ thinking_env(opts) ++ home_env(opts)
  end

  # Only the agy fork reads its config from $HOME; the upstream gemini CLI
  # keeps its own state there too, and redirecting HOME for it would buy
  # nothing while risking its auth. Gate on the resolved executable.
  defp home_env(opts) do
    case resolve_executable() do
      {:ok, {:agy, _}} -> ConfigDir.env(opts)
      _ -> []
    end
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

  # bd-apq1g6 (spike, answered 2026-09-19): agy print mode has NO flag-based
  # way to force a long command to run synchronously. The documented
  # synchronous form from agy's own stock system prompt — `"Blocking": true`
  # with `"WaitMsBeforeAsync": 0` — was invoked verbatim against a `sleep 20`
  # and agy backgrounded it anyway ("The command has been launched in the
  # background"), then terminated the task ~5s later on exit. Both arguments
  # are accepted; neither is honoured as a wait switch. So this text must NOT
  # promise foreground/synchronous execution — the only remedy with a positive
  # control behind it is behavioural: bd-40h2to measured 1-2 `manage_task
  # status` polls in the runs that died against 73 in the run that survived.
  # Keep the instruction anchored on "never end a turn while a task is
  # RUNNING", not on the flags.
  @impl true
  def async_tool_instruction do
    async_tool_instruction(
      "your VERDICT",
      "a VERDICT issued while a background task is still running is invalid,\n" <>
        "you would be judging on incomplete evidence",
      commit_first: false
    )
  end

  @impl true
  def async_tool_instruction(completion_signal, coda \\ nil, opts \\ []) do
    tail =
      case coda do
        nil -> "before you print #{completion_signal}."
        extra -> "before you print #{completion_signal} —\n#{extra}."
      end

    commit_bullet =
      if Keyword.get(opts, :commit_first, true) do
        """
          * COMMIT correct work BEFORE running any long verification. Verification
            confirms work; it must never be the thing that loses it.
        """
      else
        ""
      end

    """
    *** ASYNC TOOLS: THIS SESSION IS HEADLESS AND NON-INTERACTIVE: ending your
    turn ends the session outright, and no notification can ever reach you
    afterward. The process that would receive it no longer exists. If you
    background a long command (`mix test`, `mix precommit`, `dialyzer`, or
    similar) and end your turn to "wait" for it, the run ends on the spot, the
    command is killed with it, and any uncommitted work is lost. So:

    #{commit_bullet}\
      * When calling `run_command`, set `"Blocking": true` with
        `"WaitMsBeforeAsync": 0`. Be aware that this does NOT keep a long
        command in the foreground: agy accepts both arguments and backgrounds
        the command anyway once it runs long. Treat every command you start as
        one that may go to the background, and drain it yourself as below.
      * NEVER end your turn expecting to be woken up later. There is no "later"
        in a headless session. If a task goes to the background and is RUNNING,
        you MUST keep calling `manage_task status` repeatedly within the SAME turn
        until the task reports finished. Ending a turn while a task reports
        RUNNING terminates the session and discards the work.

    You MUST read every command's full output #{tail}\
    """
  end

  # bd-1zz5mn: agy's OWN markers for "a tool call went async and the turn
  # ended before it drained" — despite `async_tool_instruction/0` above telling
  # it not to, agy's `run_command` backgrounds a call once it outlasts
  # `WaitMsBeforeAsync` regardless, the model ends its turn, and the CLI is
  # non-interactive: there is no session left to deliver a completion
  # notification to. None of these match the Claude CLI's wording, so the
  # shared Claude-shaped signature never fired for agy and every one of these
  # early-quits was misclassified as a plain `:exited_without_done`.
  @async_arm_signature ~r/
      step[ _]is[ _]still[ _]running
    | status:[ _]running
    | was[ _]canceled[ _]with[ _]result:[ _]tool[ _]execution[ _]was[ _]canceled
  /ix

  @impl true
  def async_arm_signature, do: @async_arm_signature

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

  # The agy branch's permission posture lives in TWO places and they must agree:
  # the argv fragment here (`Arbiter.Agents.Gemini.Security.permission_argv/1`)
  # and the generated `settings.json` that `Arbiter.Agents.Gemini.ConfigDir`
  # drops into the spawn's isolated `$HOME` (injected by `spawn_env/1`). The
  # settings document is the load-bearing half — it carries `toolPermission`
  # and the allow/deny rules; the flag is the part agy only accepts on the
  # command line. See `Arbiter.Agents.Gemini.Security` for the mode table.
  defp build_argv(:agy, exec, prompt, opts, %SecurityPolicy{} = policy) do
    [exec, "-p", prompt] ++
      Security.permission_argv(policy) ++
      agy_model_and_effort_argv(opts) ++ output_format_flag() ++ print_timeout_flag(opts)
  end

  # The upstream `gemini` CLI has no allow/deny mechanism and no settings file
  # we can generate, so its branches stay coarse: `:bypass` skips its own trust
  # and confirmation gates, `:auto`/`:strict` leave them on. Nothing here
  # enforces the policy's deny rules, which is why `security_enforced?/0`
  # answers `false` on a host where `gemini` (not `agy`) is the resolved CLI.
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
