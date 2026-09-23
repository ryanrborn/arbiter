defmodule Arbiter.Quota.CloudProbe do
  @moduledoc """
  Periodic refresh probe for all quota providers — Anthropic, Codex, Gemini
  CLI, and Antigravity (bd-ajh7bd).

  ## Motivation

  Each provider's quota figures come from endpoints outside Arbiter's control,
  and each has its own rate limits. Rather than fetching on every `GET /api/quota`
  call (latency + rate-limit risk) or binding quota state to worker traffic
  (stale when idle or quota-held), this GenServer polls on a recurring timer.
  A poll writes a persistent snapshot and broadcasts `{:quota_updated, ws_id,
  view}` on the `"quota:<ws_id>"` PubSub topic — the same topic the LiveView
  `:quota` hook subscribes to. The prober becomes the *only* place that calls
  out to the external providers, so `GET /api/quota` and `arb quota` are pure DB
  reads (no request-time latency or rate-limit risk).

  For Codex / Gemini CLI / Antigravity: their figures only ever came from a live
  fetch on each `GET /api/quota` call, and (before this change) Gemini/Antigravity
  were never persisted at all. The web dashboard, which reads only the persisted
  quota tables, could never show them, and there was no history to audit. This
  GenServer closes that gap.

  ## Refresh strategy

    * `Arbiter.Quota.Codex.fetch/2` — one GET to OpenAI's usage endpoint using
      the `codex` CLI's stored token; upserts `CodexQuota` + broadcasts.
    * `Arbiter.Quota.CloudCode.refresh/3` for `:gemini` and `:antigravity` — a
      direct Cloud Code Assist call using the Gemini CLI's stored token; upserts
      `GoogleQuota` + broadcasts.
    * `Arbiter.Quota.capture_oauth_usage_for_group/2` — Anthropic's
      `/api/oauth/usage` source (per-model weekly + `extra_usage` overage,
      bd-8tpha6, *and* the primary gate columns since bd-b0zody). This is the
      only thing that keeps Claude's snapshot current for a fleet making no
      proxied traffic, so it is no longer merely a garnish riding along
      (best-effort; its own 429 cooldown protects it). This endpoint is
      account-wide, so it is fetched **once per distinct provider account**
      represented among this cycle's workspaces (P6,
      `docs/provider-account-design.md` §5 row 10 / §9) — not once per
      workspace, and (since bd-4fbpto) not once for the whole install either:
      three workspaces sharing one plan still produce one fetch, but two
      workspaces on two different accounts now produce two, each
      authenticated with that account's own credential. Its 5 min cadence is
      the endpoint's own per-account budget; the gate absorbs a missed poll by
      trusting a polled row for 600s (`Arbiter.Quota.Gate.staleness_threshold_seconds/1`)
      rather than by polling harder.

      bd-5xuneh originally de-duplicated this call by grouping workspaces on
      `ConfigDir.oauth_token/1` and passing that token explicitly, on the
      theory that workspaces sharing a `worker_env` token could safely share
      one fetch. bd-4fbpto found that theory backwards: a workspace's
      `worker_env` token is scope/rate-limited for this endpoint (empirically
      confirmed — see the status codes recorded in PR #1607) and cannot
      authenticate it at all, so bd-4fbpto deleted that grouping outright
      rather than re-keying it. P6 is the account iteration that replaces it:
      each account's own `cli_credentials_file` credential
      (`Arbiter.Accounts.Credentials.account_oauth_usage_token/1`) — never a
      workspace's `worker_env` token — authenticates its fetch, falling back
      to `Arbiter.Quota.OAuthUsage.fetch/1`'s own default (the operator's
      `.credentials.json` on disk) for an account with no credential row yet.

  The other three providers each degrade to a no-op (no row written, no
  broadcast) when their CLI isn't authenticated on this host, so a logged-out
  provider simply never appears rather than wiping the last good reading.
  Their credentials are host-global, so the figures written under each
  workspace id are identical — we still fan those three out per workspace so
  every workspace's dashboard is fed.

  ## Cadence

  A single `interval_ms` (default 5 min). These are cheap metadata calls that
  spend no model quota, so there's no active/idle split or reset-boundary
  gating — a plain heartbeat is enough.

  ## Configuration

  Via `config :arbiter, :cloud_quota_probe`:

    * `:enabled`     — master switch (default `true`; `false` in test).
    * `:interval_ms` — refresh interval (default 300 000).

  ## Test injection

  Pass `:refresh_fun` — a `fn(workspace_id :: String.t()) :: any()` — to
  `start_link/1` to replace the default three-provider refresh. Tests pass a
  stub so there is no dependency on real CLIs or HTTP.

  Pass `:oauth_opts` — a keyword list forwarded verbatim to
  `Arbiter.Quota.capture_oauth_usage_for_group/2` (and from there to
  `Arbiter.Quota.OAuthUsage.fetch/1`) — to point the account-wide poll at a
  fixture `:source_dir` instead of the real `~/.claude/.credentials.json`, or
  to inject a `:base_url` / `:plug`. Defaults to `[]`.

  Pass `:credential_watchdog` — a `GenServer.server()` — to target a specific
  `Arbiter.Agents.CredentialWatchdog` instance (tests); defaults to the named
  application singleton.

  ## Credential-expiry signals (bd-1pmf9h, generalised bd-1fpjgx)

  Claude, Codex and Gemini/Antigravity each get a **free** expiry signal off
  the same poll cycle that already fetches their quota — no extra billed
  calls, no worker has to die first:

    * **Claude** — a `{:http_error, 401}` from `/api/oauth/usage`.
      `:oauth_401_expiry_threshold` consecutive 401s (via `start_link/1`
      opts, `config :arbiter, :cloud_quota_probe`, default 2) call
      `Arbiter.Agents.CredentialWatchdog.mark_expired/3` for
      `Arbiter.Agents.Claude`. Any other failure (`:rate_limited`,
      `{:backoff, _}`, a transport error, …) is neutral — it does not reset
      the streak, because a real 429 can legitimately interleave with 401s
      here (the endpoint's own burst bucket refills at ~1 request/5min,
      tight against this poll's own 5-minute cadence — see
      `docs/oauth-usage-ratelimit.md`). Only a genuine success resets it.
    * **Codex** — a `401` from the OpenAI usage GET
      (`Arbiter.Quota.Codex.fetch/2`'s `auth_expired` flag).
      `:codex_401_expiry_threshold` consecutive 401s (default: same as
      Claude's) call `mark_expired/3` for `Arbiter.Agents.Codex`. Every other
      outcome (no local credentials, a non-401 error, a transport failure) is
      neutral for the same reason as Claude's case above; only a `200` reply
      resets the streak.
    * **Gemini/Antigravity** — an `agy --print "/usage"` row whose `agy`
      subprocess exited non-zero, the one outcome `Arbiter.Quota.CloudCode`
      itself distinguishes as "not authenticated" (its `auth_expired` flag;
      see that module's moduledoc). `:antigravity_auth_expiry_threshold`
      consecutive occurrences (default: same as Claude's) call
      `mark_expired/3` for `Arbiter.Agents.Gemini` — the adapter both Gemini
      CLI and Antigravity run under (`Arbiter.Agents.adapters/0`). `agy`
      simply not being installed, a subprocess timeout, or unparseable JSON
      say nothing about the credential, so none of them touch the streak;
      only a row with model data (`message: nil`) resets it.

  Each streak is host-global (Codex/Gemini/Antigravity credentials aren't
  per-workspace), so only the *first* result observed in a probe cycle is
  counted — every workspace's independent fetch would otherwise inflate one
  bad cycle into several.

  Each provider's recovery mirrors the Claude path: a qualifying success
  calls `Arbiter.Agents.CredentialWatchdog.mark_recovered/2` for that
  provider's adapter, the symmetric counterpart to `mark_expired/3`. It does
  so after its own failure streak, and also whenever the provider's
  `Arbiter.Agents.AuthHold` is open (bd-21bmdh) — a passing free check is one
  of that hold's documented reset paths. Pass `:auth_hold` to target a
  specific instance (tests).

  ## What these free signals cannot catch (bd-1fpjgx)

  All three checks read the *operator's* host-global CLI credentials
  (`~/.claude/.credentials.json`, `~/.codex/auth.json`, `agy`'s own
  keyring/ADC), the same ones every workspace's worker inherits by default.
  They therefore:

    * **Cannot see a bad per-workspace token.** A workspace whose
      `worker_env` overrides the CLI credential with its own, broken value
      (the failure bd-bw3466 fixed) still reads as healthy here — the probe
      never touches that override, only the operator's own copy.
    * **Do not prove model-level entitlement.** A `200`/exit-`0` response
      only means the credential authenticates against the *usage* endpoint;
      it says nothing about whether the account is entitled to the specific
      model a worker is about to dispatch against.
    * **Never surface credit exhaustion.** Running out of credits/balance is
      its own `StopReason` category (`:credit_exhausted`), not an
      authentication failure, and no branch here maps into it.
  """

  use GenServer
  require Logger

  alias Arbiter.Agents.AuthHold
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Worker.StopReason

  @default_interval_ms 300_000

  # Consecutive `/api/oauth/usage` poll failures before escalating to the
  # coordinator mailbox (bd-4fbpto) — three missed cycles (~15 min at the
  # default cadence) is long enough that a single transient 429 doesn't page
  # anyone, but short enough that a real outage doesn't sit unnoticed for
  # hours the way this one did.
  @oauth_failure_escalation_threshold 3

  # Consecutive `{:http_error, 401}` responses before treating the poll as a
  # credential-expiry signal (bd-1pmf9h). A 401 straight from `/api/oauth/usage`
  # is a far stronger expiry signal than a generic poll failure — a real
  # incident sat undetected for ~15h because the only thing watching for
  # expiry was `CredentialWatchdog`'s own CLI probe, which never saw the
  # trouble until the credentials file was removed outright. Default 2 (not 1)
  # so a single flaky response doesn't trip the fleet-wide dispatch guard.
  @default_oauth_401_expiry_threshold 2

  # Same posture as `@default_oauth_401_expiry_threshold`, generalised to
  # Codex and Gemini/Antigravity (bd-1fpjgx) — default matches Claude's.
  @default_codex_401_expiry_threshold 2
  @default_antigravity_auth_expiry_threshold 2

  defmodule State do
    @moduledoc false
    defstruct [
      :interval_ms,
      :refresh_fun,
      :enabled,
      :oauth_opts,
      :credential_watchdog,
      :auth_hold,
      :oauth_401_expiry_threshold,
      :codex_401_expiry_threshold,
      :antigravity_auth_expiry_threshold,
      probe_count: 0,
      oauth_consecutive_failures: 0,
      oauth_consecutive_401s: 0,
      codex_consecutive_401s: 0,
      antigravity_consecutive_auth_failures: 0,
      codex_result_seen_this_cycle: false,
      antigravity_result_seen_this_cycle: false
    ]
  end

  # ---- public API --------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Force an immediate refresh cycle and wait for it to be dispatched
  (synchronous). Individual provider refreshes still run off the task
  supervisor, so tests should `assert_receive` on their side-effects.
  """
  @spec probe(GenServer.server()) :: :ok
  def probe(server \\ __MODULE__), do: GenServer.call(server, :probe, 60_000)

  @doc "A snapshot of the probe state for inspection / tests."
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  # ---- GenServer callbacks -----------------------------------------------

  @impl true
  def init(opts) do
    state = %State{
      enabled: cfg(:enabled, opts, true),
      interval_ms: cfg(:interval_ms, opts, @default_interval_ms),
      refresh_fun: Keyword.get(opts, :refresh_fun) || default_refresh_fun(self()),
      oauth_opts: Keyword.get(opts, :oauth_opts, []),
      credential_watchdog: Keyword.get(opts, :credential_watchdog, CredentialWatchdog),
      auth_hold: Keyword.get(opts, :auth_hold, AuthHold),
      oauth_401_expiry_threshold:
        cfg(:oauth_401_expiry_threshold, opts, @default_oauth_401_expiry_threshold),
      codex_401_expiry_threshold:
        cfg(:codex_401_expiry_threshold, opts, @default_codex_401_expiry_threshold),
      antigravity_auth_expiry_threshold:
        cfg(
          :antigravity_auth_expiry_threshold,
          opts,
          @default_antigravity_auth_expiry_threshold
        )
    }

    if state.enabled, do: schedule(self(), state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, %State{} = state) do
    {:reply,
     %{
       probe_count: state.probe_count,
       enabled: state.enabled,
       oauth_consecutive_failures: state.oauth_consecutive_failures,
       oauth_consecutive_401s: state.oauth_consecutive_401s,
       codex_consecutive_401s: state.codex_consecutive_401s,
       antigravity_consecutive_auth_failures: state.antigravity_consecutive_auth_failures
     }, state}
  end

  def handle_call(:probe, _from, %State{} = state) do
    {:reply, :ok, do_probe_cycle(state)}
  end

  @impl true
  def handle_info(:probe, %State{enabled: false} = state) do
    schedule(self(), state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:probe, %State{} = state) do
    new_state = do_probe_cycle(state)
    schedule(self(), state.interval_ms)
    {:noreply, new_state}
  end

  def handle_info({:oauth_usage_refresh_result, workspace_ids, result}, %State{} = state) do
    {:noreply, note_oauth_result(state, workspace_ids, result)}
  end

  def handle_info({:codex_refresh_result, result}, %State{} = state) do
    {:noreply, note_codex_result(state, result)}
  end

  def handle_info({:antigravity_refresh_result, result}, %State{} = state) do
    {:noreply, note_antigravity_result(state, result)}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # ---- probe logic -------------------------------------------------------

  defp do_probe_cycle(%State{enabled: false} = state), do: state

  defp do_probe_cycle(%State{} = state) do
    workspaces = list_workspaces()

    if workspaces != [] do
      Logger.debug("Arbiter.Quota.CloudProbe: refreshing #{length(workspaces)} workspace(s)")
      spawn_oauth_usage_refresh(workspaces, state.oauth_opts)
      Enum.each(workspaces, &spawn_refresh(state.refresh_fun, &1.id))
    end

    # Codex/Gemini/Antigravity credentials are host-global, so every
    # workspace's independent fetch this cycle reports the same outcome —
    # only the first result observed per cycle should move the streak (see
    # the moduledoc's "Credential-expiry signals" section).
    %{
      state
      | probe_count: state.probe_count + 1,
        codex_result_seen_this_cycle: false,
        antigravity_result_seen_this_cycle: false
    }
  end

  # `/api/oauth/usage` is account-wide: `Quota.capture_oauth_usage_for_group/2`
  # resolves each workspace to the account it meters under and fetches once
  # per *distinct account* represented here (P6, §9), not once for the whole
  # fleet — see the moduledoc for why this no longer groups by, or passes, a
  # per-workspace token (bd-4fbpto) and how each account's own credential
  # authenticates its fetch (P6).
  defp spawn_oauth_usage_refresh(workspaces, oauth_opts) do
    workspace_ids = Enum.map(workspaces, & &1.id)
    parent = self()

    spawn_task(fn ->
      result = call_oauth_usage_refresh(workspace_ids, oauth_opts)
      send(parent, {:oauth_usage_refresh_result, workspace_ids, result})
    end)
  end

  defp call_oauth_usage_refresh(workspace_ids, oauth_opts) do
    case Arbiter.Quota.capture_oauth_usage_for_group(workspace_ids, oauth_opts) do
      {:error, reason} = err ->
        Logger.warning(
          "Arbiter.Quota.CloudProbe: oauth usage refresh for #{inspect(workspace_ids)} failed: #{inspect(reason)}"
        )

        err

      ok ->
        ok
    end
  rescue
    e ->
      reason = {:exception, Exception.message(e)}

      Logger.warning(
        "Arbiter.Quota.CloudProbe: oauth usage refresh for #{inspect(workspace_ids)} raised: #{Exception.message(e)}"
      )

      {:error, reason}
  catch
    :exit, r ->
      Logger.warning(
        "Arbiter.Quota.CloudProbe: oauth usage refresh for #{inspect(workspace_ids)} exited: #{inspect(r)}"
      )

      {:error, {:exit, r}}
  end

  # Tracks consecutive oauth-usage-poll failures and escalates to the
  # coordinator mailbox the cycle the threshold is first crossed — an
  # edge-trigger, so a sustained outage produces exactly one mailbox item
  # (bd-4fbpto) rather than one per 5-minute cycle. Resets on the next
  # success, so a later, distinct outage escalates again.
  defp note_oauth_result(%State{} = state, workspace_ids, {:ok, results}) do
    failed =
      for {workspace_id, {:error, reason}} <- Enum.zip(workspace_ids, results),
          do: {workspace_id, reason}

    # `Quota.write_once_per_account/4` tags each per-account failure with
    # the stage it came from: `{:fetch, reason}` when that account's own
    # `/api/oauth/usage` call itself failed (401, transport error,
    # unresolvable account), `{:write, reason}` when the fetch succeeded and
    # only the DB write failed.
    fetch_failed = Enum.filter(failed, fn {_ws, reason} -> match?({:fetch, _}, reason) end)
    write_failed = Enum.filter(failed, fn {_ws, reason} -> match?({:write, _}, reason) end)

    cond do
      failed == [] ->
        note_recovered(state, Arbiter.Agents.Claude, state.oauth_consecutive_401s)

        %{state | oauth_consecutive_failures: 0, oauth_consecutive_401s: 0}

      fetch_failed != [] ->
        # At least one account's own fetch failed this cycle, even though
        # other accounts succeeded. A mixed cycle like this must not look
        # like a clean one — pre-P6, the fetch ran once for the whole
        # group, so any fetch error was necessarily a whole-cycle failure;
        # post-P6 each account fetches independently, so this is the exact
        # case the HIGH finding on bd-3j92yv covers: a broken account's 401s
        # must keep tripping `CredentialWatchdog`/the escalation mailbox
        # even while a healthy sibling account keeps polling fine. Prefer a
        # 401 among the failures so the streak that matters most doesn't
        # get starved by an unrelated transport error on another account.
        {_ws, reason} =
          Enum.find(fetch_failed, fn {_ws, {:fetch, r}} -> match?({:http_error, 401}, r) end) ||
            hd(fetch_failed)

        Logger.warning(
          "Arbiter.Quota.CloudProbe: oauth usage fetch failed for #{length(fetch_failed)} account(s) this cycle: #{inspect(fetch_failed)}"
        )

        note_oauth_result(state, workspace_ids, {:error, reason})

      length(write_failed) == length(results) ->
        # Every per-workspace write failed even though every fetch
        # succeeded (e.g. the DB was locked) — this is the ticket's exact
        # symptom ("polls every 5 min and writes nothing") wearing a
        # different cause, so it must count as a failed cycle rather than
        # reset the counter.
        Logger.warning(
          "Arbiter.Quota.CloudProbe: oauth usage fetch succeeded but every write failed: #{inspect(write_failed)}"
        )

        note_oauth_result(state, workspace_ids, {:error, {:all_writes_failed, write_failed}})

      true ->
        Logger.warning(
          "Arbiter.Quota.CloudProbe: oauth usage fetch succeeded but some writes failed: #{inspect(write_failed)}"
        )

        %{state | oauth_consecutive_failures: 0, oauth_consecutive_401s: 0}
    end
  end

  defp note_oauth_result(%State{} = state, workspace_ids, {:error, reason}) do
    failures = state.oauth_consecutive_failures + 1

    if failures == @oauth_failure_escalation_threshold do
      escalate_oauth_failure(workspace_ids, failures, reason)
    end

    # `reason` may still carry a `Quota.write_once_per_account/4` stage tag
    # here — this clause also handles the bare `{:error, reason}` a whole-
    # cycle failure collapses to (`Quota.capture_oauth_usage_for_group/2`'s
    # uniform-failure shortcut), which keeps the tag. Unwrap it so 401
    # detection doesn't care whether it arrived tagged or not.
    state = note_oauth_401(state, workspace_ids, {:error, unwrap_stage(reason)})

    %{state | oauth_consecutive_failures: failures}
  end

  defp note_oauth_result(%State{} = state, _workspace_ids, _other), do: state

  defp unwrap_stage({stage, reason}) when stage in [:fetch, :write], do: reason
  defp unwrap_stage(reason), do: reason

  defp escalate_oauth_failure([ws_id | _], failures, reason) when is_binary(ws_id) do
    safe_escalate(fn ->
      CoordinatorNotifier.quota_poll_failing(%{workspace_id: ws_id}, failures, reason)
    end)
  end

  defp escalate_oauth_failure(_workspace_ids, _failures, _reason), do: :ok

  # Tracks consecutive `{:http_error, 401}` responses from the oauth-usage
  # poll (bd-1pmf9h) — the strongest available expiry signal, independent of
  # `CredentialWatchdog`'s own CLI probe, which only ever saw the outage once
  # `~/.claude/.credentials.json` was removed outright. Any other error
  # (`:rate_limited`, `{:backoff, _}`, a transport error, …) is neutral: it
  # neither confirms nor disproves expiry, so it must not reset the streak —
  # the real incident had 401s and real upstream 429s interleaved for 15h
  # straight (the account's oauth-usage bucket refills at ~1 req/5min, tight
  # against this poll's own 5-minute cadence, so a live 429 here is expected
  # and unrelated to token validity — see `docs/oauth-usage-ratelimit.md`).
  # Only a genuine success resets it (see `note_oauth_result/3`).
  defp note_oauth_401(%State{} = state, workspace_ids, {:error, {:http_error, 401}}) do
    count = state.oauth_consecutive_401s + 1

    if count >= state.oauth_401_expiry_threshold do
      mark_credential_expired(state, workspace_ids, count)
    end

    %{state | oauth_consecutive_401s: count}
  end

  defp note_oauth_401(%State{} = state, _workspace_ids, _error), do: state

  defp mark_credential_expired(%State{} = state, workspace_ids, count) do
    reason = %StopReason{
      category: :auth_expired,
      summary:
        "#{count} consecutive 401s from the /api/oauth/usage poll for #{inspect(workspace_ids)}",
      remediation: "re-authenticate the operator's Claude OAuth credentials (`claude login`)",
      exit_status: nil,
      signal: nil
    }

    CredentialWatchdog.mark_expired(Arbiter.Agents.Claude, reason, state.credential_watchdog)
  end

  # A qualifying success is a recovery signal when this probe's own streak
  # had started (bd-1pmf9h / bd-1fpjgx), and also whenever the provider's
  # `AuthHold` is open (bd-21bmdh): a hold opened by N consecutive *worker*
  # auth deaths marked the watchdog without this probe ever seeing a failure,
  # so the streak alone would never clear it. `AuthHold.held/2` fails open, so
  # an unreadable hold never turns every success into a recovery call. Both
  # casts are idempotent; the direct `recovered/2` also covers a hold whose
  # watchdog mark was already cleared some other way.
  defp note_recovered(%State{} = state, adapter, streak) do
    hold_open? = AuthHold.held(adapter, state.auth_hold) != nil

    if streak > 0 or hold_open? do
      CredentialWatchdog.mark_recovered(adapter, state.credential_watchdog)
    end

    if hold_open?, do: AuthHold.recovered(adapter, state.auth_hold)
    :ok
  end

  # ---- Codex credential-expiry signal (bd-1fpjgx) ------------------------
  #
  # Mirrors `note_oauth_401/3` above, generalised to Codex's usage GET. Only
  # the first result observed this cycle moves the streak (see
  # `do_probe_cycle/1`) — Codex credentials are host-global, so every
  # workspace's independent fetch this cycle would otherwise report the same
  # outcome and double-count it.
  defp note_codex_result(%State{codex_result_seen_this_cycle: true} = state, _result), do: state

  defp note_codex_result(%State{} = state, %{auth_expired: true}) do
    count = state.codex_consecutive_401s + 1

    if count >= state.codex_401_expiry_threshold do
      mark_codex_expired(state, count)
    end

    %{state | codex_consecutive_401s: count, codex_result_seen_this_cycle: true}
  end

  # A real window reading is the only outcome treated as a genuine success —
  # "connected but no windows"/"could not be stored"/transport failures are
  # neutral (like a Claude-side rate-limit) and must not reset the streak.
  defp note_codex_result(%State{} = state, %{codex: codex}) when not is_nil(codex) do
    note_recovered(state, Arbiter.Agents.Codex, state.codex_consecutive_401s)

    %{state | codex_consecutive_401s: 0, codex_result_seen_this_cycle: true}
  end

  defp note_codex_result(%State{} = state, _neutral),
    do: %{state | codex_result_seen_this_cycle: true}

  defp mark_codex_expired(%State{} = state, count) do
    reason = %StopReason{
      category: :auth_expired,
      summary: "#{count} consecutive 401s from the Codex usage poll",
      remediation: "re-authenticate the operator's Codex CLI (`codex login`)",
      exit_status: nil,
      signal: nil
    }

    CredentialWatchdog.mark_expired(Arbiter.Agents.Codex, reason, state.credential_watchdog)
  end

  # ---- Gemini/Antigravity credential-expiry signal (bd-1fpjgx) -----------
  #
  # Mirrors `note_codex_result/2` above, keyed off `CloudCode.antigravity/1`'s
  # `auth_expired` flag (only set on the "agy exited non-zero" outcome —
  # `agy` not installed, a subprocess timeout, or unparseable JSON say
  # nothing about the credential and are left neutral). Gemini CLI and
  # Antigravity share `Arbiter.Agents.Gemini`, so both this and the CLI probe
  # target the same adapter.
  defp note_antigravity_result(%State{antigravity_result_seen_this_cycle: true} = state, _snap),
    do: state

  defp note_antigravity_result(%State{} = state, %{auth_expired: true}) do
    count = state.antigravity_consecutive_auth_failures + 1

    if count >= state.antigravity_auth_expiry_threshold do
      mark_antigravity_expired(state, count)
    end

    %{
      state
      | antigravity_consecutive_auth_failures: count,
        antigravity_result_seen_this_cycle: true
    }
  end

  # A healthy row carries no message; only that counts as a genuine success.
  defp note_antigravity_result(%State{} = state, %{message: nil}) do
    note_recovered(state, Arbiter.Agents.Gemini, state.antigravity_consecutive_auth_failures)

    %{state | antigravity_consecutive_auth_failures: 0, antigravity_result_seen_this_cycle: true}
  end

  defp note_antigravity_result(%State{} = state, _neutral),
    do: %{state | antigravity_result_seen_this_cycle: true}

  defp mark_antigravity_expired(%State{} = state, count) do
    reason = %StopReason{
      category: :auth_expired,
      summary: "#{count} consecutive auth failures from the Antigravity (agy) usage poll",
      remediation: "re-authenticate Antigravity — run `agy` once on this host to sign in",
      exit_status: nil,
      signal: nil
    }

    CredentialWatchdog.mark_expired(Arbiter.Agents.Gemini, reason, state.credential_watchdog)
  end

  defp safe_escalate(fun) do
    fun.()
  rescue
    e ->
      Logger.debug("Arbiter.Quota.CloudProbe: escalation swallowed: #{Exception.message(e)}")
  catch
    :exit, _ -> :ok
  end

  defp spawn_refresh(refresh_fun, workspace_id) do
    spawn_task(fn -> call_refresh(refresh_fun, workspace_id) end)
  end

  defp spawn_task(fun) do
    supervisor = Arbiter.Quota.CloudProbeSupervisor

    case Process.whereis(supervisor) do
      pid when is_pid(pid) ->
        Task.Supervisor.start_child(pid, fun)

      _ ->
        spawn(fun)
    end
  rescue
    _ -> :ok
  end

  defp call_refresh(refresh_fun, workspace_id) do
    refresh_fun.(workspace_id)
  rescue
    e ->
      Logger.debug(
        "Arbiter.Quota.CloudProbe: refresh for #{workspace_id} raised: #{Exception.message(e)}"
      )
  catch
    :exit, r ->
      Logger.debug("Arbiter.Quota.CloudProbe: refresh for #{workspace_id} exited: #{inspect(r)}")
  end

  # `refresh_fun`'s default is bound to the CloudProbe GenServer's own pid at
  # `init/1` time (`self()` there *is* this process) so the spawned refresh
  # Tasks below can report the Codex/Antigravity results back for the
  # credential-expiry streaks in `note_codex_result/2` /
  # `note_antigravity_result/2` — mirroring how `spawn_oauth_usage_refresh/2`
  # reports back for Claude. A caller-supplied `:refresh_fun` (tests) replaces
  # this wholesale and sends no such messages, which is why those tests never
  # see `codex_consecutive_401s` / `antigravity_consecutive_auth_failures`
  # move.
  defp default_refresh_fun(parent) do
    fn workspace_id -> default_refresh(workspace_id, parent) end
  end

  # The real per-workspace provider refresh. Each call persists + broadcasts
  # on success and no-ops (no row written) when its credentials aren't
  # present on this host. Anthropic's `/api/oauth/usage` source (per-model
  # weekly + overage + the primary gate columns) is refreshed separately, once
  # per cycle for the whole fleet, by `spawn_oauth_usage_refresh/2` — see that
  # function and bd-4fbpto for why it isn't fanned out per workspace here.
  defp default_refresh(workspace_id, parent) do
    codex_result = Arbiter.Quota.Codex.fetch(workspace_id)
    send(parent, {:codex_refresh_result, codex_result})

    Arbiter.Quota.CloudCode.refresh(workspace_id, :gemini)

    antigravity_result = Arbiter.Quota.CloudCode.refresh(workspace_id, :antigravity)
    send(parent, {:antigravity_refresh_result, antigravity_result})

    :ok
  end

  # ---- helpers -----------------------------------------------------------

  defp list_workspaces do
    case Ash.read(Arbiter.Tasks.Workspace) do
      {:ok, workspaces} -> workspaces
      _ -> []
    end
  rescue
    _ -> []
  end

  defp schedule(pid, ms), do: Process.send_after(pid, :probe, ms)

  defp cfg(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} ->
        val

      :error ->
        case Application.get_env(:arbiter, :cloud_quota_probe, []) do
          kw when is_list(kw) -> Keyword.get(kw, key, default)
          _ -> default
        end
    end
  end
end
