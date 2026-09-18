defmodule Arbiter.Agents.Preflight do
  @moduledoc """
  Cheap, provider-agnostic auth probe for the agent CLI (bd-awi4nw).

  The confirmed failure mode: the operator's Claude OAuth (or Gemini key)
  expires, every worker spawn 401s, and the fleet burns cycles dispatching a
  wave of workers that all fail with a buried generic error. The original fix
  was to probe *before every dispatch*; bd-2jgs2h retired that, because a
  billed model turn per dispatch and per resume (~760/day fleet-wide) bought
  nothing a fast-failing spawn does not (see `docs/quota-and-auth.md`).

  **Who calls this now:** `Arbiter.Agents.CredentialWatchdog`'s periodic
  liveness poll, for the adapters in its `:adapters` setting, and nothing else.
  `Arbiter.Worker.Dispatch` reads the Watchdog's *state* (`expired?/1`) — a
  free lookup — and never spawns a probe. So a probe's verdict no longer gates
  an individual dispatch; it moves an adapter's expiry flag, and *that* bounds
  the fleet.

  This module owns the **probe execution**: it spawns the adapter's probe argv
  through an Erlang `Port` (the same liveness-first mechanism the worker uses
  for real workers), captures output + exit status under a timeout, and hands
  the result to `Arbiter.Worker.StopReason` for classification. The adapter
  supplies *what* to run via the optional `auth_probe_argv/1` callback; an
  adapter that doesn't implement it is unprobeable and `check/2` returns
  `:skipped` (we never block on an absent probe).

  ## Result

    * `:ok` — the probe authenticated and exited cleanly.
    * `{:error, %StopReason{}}` — the probe failed; the reason carries the
      classified cause (`:auth_expired`, `:credit_exhausted`, …) + remediation.
    * `{:warn, %StopReason{}}` — the probe outran its watchdog. Advisory: the
      caller should log it and **proceed**. See the decision below.
    * `:skipped` — the adapter exposes no probe, so there's nothing to check.

  ## Decision: a pre-flight timeout fails open (bd-svczq4)

  A timeout is the one probe outcome that says nothing about the credentials.
  `arb dispatch … --provider gemini` was refused on 2026-09-18 with "agent
  produced no output within the watchdog window (possible hang)" for a probe
  that had authenticated fine and made 21 model calls — it had simply taken
  102s against a hard-coded 30s watchdog, and two earlier probes the same day
  finished in 16s. When the *probe's own* reliability is the variable, a
  blocking verdict is a coin flip on valid work.

  So: **a timeout fails open**. `check/2` returns `{:warn, reason}`, distinct
  from `{:error, reason}`, and no caller may treat it as evidence about the
  credentials: the `CredentialWatchdog` logs it and leaves the adapter's flag
  exactly as it was — a slow probe neither marks an adapter expired (which
  would refuse *every* dispatch fleet-wide) nor recovers one a dying worker
  just flagged. A genuinely broken CLI still fails, loudly, at the spawn it
  would have failed at anyway — which is exactly the state the fleet was in
  before any pre-flight existed. Every other outcome (a 401, exhausted credit,
  a missing CLI) is conclusive evidence and still counts.

  An operator who wants a timeout to count against the adapter sets:

      config :arbiter, Arbiter.Agents.Preflight, on_timeout: :refuse

  which turns the timeout back into an `{:error, reason}` — note that with the
  `:preflight_timeout` category it still is not `:auth_expired`, so it is a
  logged non-auth failure rather than a fleet-wide refusal.

  ## Configuration

      config :arbiter, Arbiter.Agents.Preflight,
        # install-wide watchdog default (falls back to 30s)
        timeout_ms: 30_000,
        # per-adapter watchdog — resolution order: `:timeout_ms` opt, this map,
        # `:timeout_ms` above, the built-in per-provider default, 30s
        timeout_ms_by_provider: %{"gemini" => 120_000},
        # `:proceed` (default) | `:refuse`
        on_timeout: :proceed

  The watchdog was a bare module attribute until bd-svczq4, shared by every
  adapter and reachable from no CLI or MCP dispatch path — every real dispatch
  got 30s and the operator had no lever at all. The per-provider default for
  `gemini` is above `agy`'s observed cold-start floor on the arbiter host.

  ## Where the probe runs (bd-svczq4)

  `Port.open` carried no `:cd`, so the probe inherited the BEAM's cwd — on the
  dogfooded host, `/home/ryan/dev/arbiter`, the live checkout Phoenix
  hot-reloads from. An agy probe's generated settings carry
  `toolPermission: "always-proceed"`; the failing run only *read* six files,
  but nothing in the argv stopped the next one writing, and a write there has
  taken the install down before. Every probe now runs in `probe_cwd/0`, an
  empty directory under the system temp dir.

  A probe that outruns its watchdog also has its **process tree killed**
  (`Arbiter.Worker.OsProcess.kill_tree/1`): `Port.close/1` does not reap a
  `:spawn_executable` child, and the agy probe that triggered this ticket
  outlived the watchdog by 72 seconds, still calling the API.

  ## The CLI's own result is the verdict (bd-svczq4)

  A clean exit *plus* a successful structured result object is conclusive: the
  probe authenticated. The lines around it are not re-scanned for failure
  signatures, because they are the agent's work product, not a diagnostic about
  our credentials — and treating them as one was dangerous. Measured live on
  2026-09-18: agy, carrying the Arbiter-worker `GEMINI.md` from its isolated
  HOME, answered `ping` with a 14-step agentic turn that shelled out to
  `arb prime`. The backlog it printed contained a task titled "…generalise the
  401-shaped detection", and the classifier read that text as `:auth_expired` —
  which, from the `CredentialWatchdog`, marks the adapter dead and refuses every
  dispatch for it fleet-wide. The same run also drew `:context_thrash` from
  agy's falling per-step `input_tokens`.

  `Arbiter.Usage.Probe.parse/1` only yields usage for a *successful* result
  payload (Claude's `is_error`, agy's non-SUCCESS `status`), so a CLI that
  reports its own failure still falls through to the classifier, as does one
  that prints an auth error and exits 0 without any result object at all.

  That the probe is *still an agentic turn* — 7 `run_command` calls and ~71K
  input tokens to say "pong" — is not fixed here. The neutral cwd (below) means
  it has no repo to wander into, and bd-2jgs2h means it no longer runs per
  dispatch, so what remains is cost and noise on the Watchdog's poll rather than
  a correctness problem.

  ## The spend this costs (bd-adyhvn, bd-2jgs2h)

  A probe is not free: a one-word prompt still ships the CLI's whole system
  prompt and tool definitions (~39K cache-read tokens a call, measured). The
  per-dispatch/per-resume caller is gone (bd-2jgs2h), so what remains is the
  Watchdog's poll — one round-trip per probed adapter per interval, bounded by
  its `:adapters` setting, which the operator can empty. Every probe that
  actually spawns writes one `usage_events` row with `source: :preflight` via
  `Arbiter.Usage.Probe` — carrying real token counts when the CLI returned a
  structured result, and an explained null cost when it didn't. The ledger
  write is best-effort and never changes the verdict.

  A `:skipped` (adapter has no probe) or an un-runnable probe (CLI missing)
  writes nothing: no process ran, so nothing was spent.

  ## Test injection

  Pass `:probe_command` (an argv list) to bypass the adapter and run an
  arbitrary script — tests use this to simulate a 401 / a clean ping without a
  real CLI. `:probe_env` overrides the spawn env; `:timeout_ms` overrides the
  default wait.
  """

  require Logger

  alias Arbiter.Usage
  alias Arbiter.Worker.OsProcess
  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.StopReason

  @default_timeout_ms 30_000

  # Per-provider watchdog floors. `agy`'s cold start on the arbiter host was
  # measured at 102s for a one-word prompt (bd-svczq4) — a shared 30s constant
  # refused valid dispatches nondeterministically. The adapter also derives its
  # own `--print-timeout` from whatever this resolves to, so agy yields and
  # reports a real exit status before the harness gives up.
  @builtin_timeout_ms_by_provider %{"gemini" => 120_000}

  # An empty directory the probe can run in. The probe used to inherit the
  # BEAM's cwd — the live checkout, with the CLI's tools enabled.
  @probe_dir "arbiter-preflight"

  @type result :: :ok | {:warn, StopReason.t()} | {:error, StopReason.t()} | :skipped

  @doc """
  Run the auth pre-flight for `adapter`.

  `opts`:
    * `:probe_command` — argv override (tests); bypasses the adapter.
    * `:probe_env` — env override (`[{name, value}]`); defaults to the
      adapter's `spawn_env/1` so the probe authenticates exactly as a real
      worker spawn would.
    * `:timeout_ms` — max wait before declaring the probe hung; defaults to
      `timeout_ms/2` for this adapter.
    * `:usage_task_id` — the task this check is gating, when there is one.
      Recorded on the ledger row (bd-adyhvn).
    * `:usage_workspace_id` — workspace to attribute the spend to; defaults to
      the id of the `:workspace` opt when one is threaded through.
    * any keys the adapter's `auth_probe_argv/1` / `spawn_env/1` read
      (`:api_key`, `:model`, …).
  """
  @spec check(module(), keyword()) :: result()
  def check(adapter, opts \\ []) when is_atom(adapter) and is_list(opts) do
    # Resolve the watchdog FIRST and thread it into the adapter's argv builder:
    # an agentic CLI has its own turn budget, and unless it is derived from ours
    # (agy's default is 5m — 10x the old harness constant) nothing makes the CLI
    # yield before we give up, so we never see a real exit status (bd-svczq4).
    timeout = timeout_ms(adapter, opts)
    opts = Keyword.put(opts, :timeout_ms, timeout)

    case resolve_argv(adapter, opts) do
      {:ok, argv} -> run(adapter, argv, opts, timeout)
      :skipped -> :skipped
      {:error, reason} -> {:error, probe_unavailable(reason)}
    end
  end

  @doc """
  The watchdog this `adapter`'s probe gets, in milliseconds.

  Resolution order (first hit wins):

    1. an explicit `:timeout_ms` opt;
    2. `config :arbiter, #{inspect(__MODULE__)}, timeout_ms_by_provider: %{provider => ms}`;
    3. `config :arbiter, #{inspect(__MODULE__)}, timeout_ms: ms` (install-wide);
    4. the built-in per-provider default;
    5. #{@default_timeout_ms}ms.
  """
  @spec timeout_ms(module(), keyword()) :: pos_integer()
  def timeout_ms(adapter, opts \\ []) do
    provider = safe_provider(adapter)

    positive(Keyword.get(opts, :timeout_ms)) ||
      positive(configured_provider_timeout(provider)) ||
      positive(Keyword.get(config(), :timeout_ms)) ||
      positive(Map.get(@builtin_timeout_ms_by_provider, provider)) ||
      @default_timeout_ms
  end

  @doc """
  The neutral directory every probe runs in.

  Never a repo, and never the BEAM's own cwd — see the moduledoc. Falls back to
  the bare temp dir if the subdirectory can't be created.
  """
  @spec probe_cwd() :: String.t()
  def probe_cwd do
    dir = Path.join(System.tmp_dir!(), @probe_dir)
    File.mkdir_p!(dir)
    dir
  rescue
    _ -> System.tmp_dir!()
  end

  defp config, do: Application.get_env(:arbiter, __MODULE__, [])

  defp configured_provider_timeout(nil), do: nil

  defp configured_provider_timeout(provider) do
    case Keyword.get(config(), :timeout_ms_by_provider) do
      %{} = map -> Map.get(map, provider)
      _ -> nil
    end
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  defp on_timeout do
    case Keyword.get(config(), :on_timeout) do
      :refuse -> :refuse
      _ -> :proceed
    end
  end

  # ---- argv resolution ---------------------------------------------------

  defp resolve_argv(adapter, opts) do
    case Keyword.get(opts, :probe_command) do
      [exec | _] = argv when is_binary(exec) ->
        {:ok, argv}

      _ ->
        adapter_argv(adapter, opts)
    end
  end

  defp adapter_argv(adapter, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :auth_probe_argv, 1) do
      adapter.auth_probe_argv(opts)
    else
      :skipped
    end
  end

  # ---- probe execution ---------------------------------------------------

  defp run(adapter, [exec | _] = argv, opts, timeout) do
    case resolve_executable(exec) do
      {:ok, resolved} ->
        env = Keyword.get(opts, :probe_env) || safe_spawn_env(adapter, opts)
        spawn_and_classify(resolved, argv, env, timeout, adapter, opts)

      {:error, reason} ->
        {:error, probe_unavailable(reason)}
    end
  end

  defp spawn_and_classify(resolved, [_ | rest], env, timeout, adapter, opts) do
    port =
      Port.open(
        {:spawn_executable, resolved},
        [
          {:args, rest},
          {:line, 65_536},
          :binary,
          :exit_status,
          :stderr_to_stdout,
          # bd-svczq4 Hazard A: never the BEAM's cwd. An agentic CLI probe with
          # tools enabled, rooted in the live hot-reloading checkout, is one
          # curious turn away from writing there.
          {:cd, probe_cwd()}
        ] ++ env_opt(env)
      )

    started_at = System.monotonic_time(:millisecond)
    os_pid = safe_os_pid(port)
    {outcome, lines} = collect(port, timeout, [])
    elapsed = System.monotonic_time(:millisecond) - started_at

    if outcome == :timeout, do: terminate_probe(port, os_pid)

    status =
      case outcome do
        {:exit, code} -> code
        :timeout -> nil
      end

    # bd-adyhvn: the process ran, so it spent — split the CLI's structured
    # result out of the output *before* classifying (its integers would
    # otherwise read as provider-error signatures) and record the draw.
    {usage, diagnostic_lines} = Usage.Probe.parse(lines)
    record_usage(adapter, usage, status, opts, elapsed)

    verdict(outcome, diagnostic_lines, adapter, timeout, elapsed, usage != nil)
  rescue
    e -> {:error, probe_unavailable(Exception.message(e))}
  end

  # Accumulate output lines (oldest-first) until the port exits or we time out.
  # Returns `{{:exit, status} | :timeout, lines}`; classification happens in
  # `verdict/6` once the structured usage payload has been split off.
  defp collect(port, timeout, acc) do
    receive do
      {^port, {:data, {:eol, line}}} -> collect(port, timeout, [line | acc])
      {^port, {:data, {:noeol, line}}} -> collect(port, timeout, [line | acc])
      {^port, {:exit_status, status}} -> {{:exit, status}, Enum.reverse(acc)}
    after
      timeout -> {:timeout, Enum.reverse(acc)}
    end
  end

  defp safe_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # bd-svczq4 Hazard B: `Port.close/1` closes the pipes, it does not reap the
  # child. The agy probe that triggered this ticket survived the watchdog by 72
  # seconds, still calling the provider API and spending quota.
  defp terminate_probe(port, os_pid) do
    if is_integer(os_pid) do
      case OsProcess.kill_tree(os_pid) do
        [] ->
          :ok

        survivors ->
          Logger.warning(
            "Preflight: probe os_pid(s) #{Enum.join(survivors, ",")} still alive after SIGKILL"
          )
      end
    end

    safe_close(port)
  end

  # A clean exit usually means auth is fine — but a CLI can print an auth/credit
  # error and still exit 0, so we run the output through the classifier and only
  # accept when it sees no failure signature.
  # A timeout is the one outcome that says nothing about the credentials, so it
  # fails open by default — see the moduledoc's decision section.
  defp verdict(:timeout, lines, adapter, timeout, elapsed, _structured_result?) do
    reason =
      StopReason.preflight_timeout(
        timeout_ms: timeout,
        elapsed_ms: elapsed,
        lines: lines,
        provider: safe_provider(adapter)
      )

    Logger.warning("Preflight: #{reason.summary}")

    case on_timeout() do
      :refuse -> {:error, reason}
      :proceed -> {:warn, reason}
    end
  end

  defp verdict({:exit, status}, lines, _adapter, _timeout, _elapsed, structured_result?),
    do: verdict_for_exit(status, lines, structured_result?)

  # bd-svczq4: when the CLI exited 0 *and* returned its own successful result
  # object, that is the verdict — full stop. Scraping the lines around it for
  # failure signatures is reading the agent's work product as a diagnostic about
  # our credentials, and it is actively dangerous: a healthy agy probe (which,
  # carrying the Arbiter-worker `GEMINI.md`, answers "ping" with a real agentic
  # turn) shelled out to `arb prime`, and the backlog it printed contained a
  # task titled "…generalise the 401-shaped detection". The classifier called
  # that `:auth_expired`. Under `CredentialWatchdog` that verdict marks the
  # adapter dead and refuses every dispatch for it, fleet-wide, off a probe that
  # had authenticated perfectly. `Arbiter.Usage.Probe.parse/1` only yields usage
  # for a *successful* result payload — a failed one (Claude's `is_error`, agy's
  # non-SUCCESS `status`) stays in the haystack below.
  defp verdict_for_exit(0, _lines, true), do: :ok

  defp verdict_for_exit(0, lines, false) do
    reason = StopReason.classify(0, lines)

    case reason.category do
      :exited_without_done -> :ok
      # bd-606zlr: also a clean exit with no failure signature — the probe's
      # auth verdict must not flip just because its output happened to refine
      # into the async-wait category.
      :async_wait_abandoned -> :ok
      _ -> {:error, reason}
    end
  end

  defp verdict_for_exit(status, lines, _structured_result?),
    do: {:error, StopReason.classify(status, lines)}

  defp record_usage(adapter, usage, status, opts, elapsed_ms) do
    Usage.Probe.record(:preflight, usage,
      task_id: Keyword.get(opts, :usage_task_id),
      workspace_id: usage_workspace_id(opts),
      provider: safe_provider(adapter),
      exit_status: status,
      duration_ms: elapsed_ms
    )

    :ok
  end

  defp usage_workspace_id(opts) do
    case Keyword.get(opts, :usage_workspace_id) do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        case Keyword.get(opts, :workspace) do
          %{id: id} when is_binary(id) -> id
          _ -> nil
        end
    end
  end

  defp safe_provider(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :provider, 0) do
      adapter.provider()
    end
  rescue
    _ -> nil
  end

  # ---- helpers -----------------------------------------------------------

  defp resolve_executable(exec) do
    cond do
      String.contains?(exec, "/") and File.exists?(exec) -> {:ok, exec}
      String.contains?(exec, "/") -> {:error, {:executable_not_found, exec}}
      true -> find_on_path(exec)
    end
  end

  defp find_on_path(exec) do
    case System.find_executable(exec) do
      nil -> {:error, {:executable_not_found, exec}}
      path -> {:ok, path}
    end
  end

  defp safe_spawn_env(adapter, opts) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :spawn_env, 1) do
      adapter.spawn_env(opts)
    else
      []
    end
  end

  # bd-2oelme: the probe is a `claude --print` round-trip, so it must not
  # inherit the release's ROOTDIR/BINDIR/RELEASE_* (the `cannot get bootfile`
  # signature of bd-4hkzn3 for any BEAM the CLI's own hooks might start). The
  # scrub is applied here rather than at the two `env` sources so it covers
  # both the adapter's `spawn_env/1` and a caller-supplied `:probe_env`.
  defp env_opt(pairs) do
    case ReleaseEnv.port_env(pairs) do
      [] -> []
      merged -> [{:env, env_charlists(merged)}]
    end
  end

  defp env_charlists(pairs) do
    Enum.map(pairs, fn
      {name, false} -> {to_charlist(name), false}
      {name, value} when is_binary(value) -> {to_charlist(name), to_charlist(value)}
    end)
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  # The probe couldn't even run (CLI missing, spawn failed). That's still a
  # refuse-to-dispatch condition — dispatching would fail the same way — but it's a
  # crash/setup issue, not credential expiry, so classify it as such.
  defp probe_unavailable({:executable_not_found, exec}) do
    %StopReason{
      category: :crashed,
      summary: "agent CLI not found on PATH (#{exec})",
      remediation: "Install / fix the agent CLI on the host before dispatching.",
      exit_status: nil,
      signal: nil
    }
  end

  defp probe_unavailable(reason) do
    %StopReason{
      category: :crashed,
      summary: "agent auth pre-flight could not run: #{inspect(reason)}",
      remediation: "Check the agent CLI install + host before dispatching.",
      exit_status: nil,
      signal: nil
    }
  end
end
