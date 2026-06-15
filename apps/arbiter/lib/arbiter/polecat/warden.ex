defmodule Arbiter.Polecat.Warden do
  @moduledoc """
  Watchdog process for a polecat parked at `:awaiting_review`.

  When an acolyte finishes its work it opens a merge request and the paired
  `Arbiter.Polecat` transitions `:running -> :awaiting_review`, spawning one
  Warden. The Warden polls `Arbiter.Mergers.get/1` on an interval and drives
  the polecat to its terminal state based on the MR's fate:

      MR merged           -> Polecat.complete(:merged)
      MR approved         -> (auto_merge) Mergers.merge/1 then complete(:merged)
                          -> (manual)     stay parked; a human merges, next
                                          poll sees :merged, then complete
      MR closed/rejected  -> Polecat.fail({:mr_closed, ref})

  One Warden supervises one polecat. It is started under
  `Arbiter.Polecat.WardenSupervisor` (a `DynamicSupervisor`, `restart:
  :temporary`) and monitors the polecat: if the polecat dies, the Warden
  stops.

  ## Approval detection lives in one function

  `classify/1` maps a `Mergers.get/1` result map to one of `:merged |
  :approved | :closed | :pending`. It is the *single* decision surface — the
  poll loop and any future push trigger both route through it.

  ### Webhook upgrade (design only — not implemented here)

  Polling is the shipped mechanism. A future push path would add
  `POST /webhooks/gitlab` and `POST /webhooks/github` controllers that, on a
  merge-request event, look up the Warden for the affected `mr_ref` and send
  it `{:mr_event, get_result}`. Because `classify/1` already encapsulates the
  approval logic, the webhook handler reuses it verbatim and the poll interval
  becomes a slow safety-net backstop rather than the primary trigger. No state
  machine changes are required to make that swap — only a new inbound message
  that calls the same `apply_outcome/2` path the poll uses.

  ## Adapter config

  Hosted-forge adapters (GitLab) resolve host/project/token from the process
  dictionary. The Warden runs in its own process, so it seeds that config via
  `Arbiter.Mergers.prepare/1` in `init/1` (a no-op for `Direct`).
  """

  use GenServer

  require Logger

  alias Arbiter.Mergers
  alias Arbiter.Polecat

  @default_interval_ms 60_000
  # Watchdog ceiling on consecutive :pending polls before we escalate and stop.
  #
  # auto_merge ON (CI/forge merges): 30 polls × 60s = 30 min. If auto-merge
  # hasn't fired after that long, something is broken — fail loudly (bd-66ey1o).
  #
  # auto_merge OFF (human-merge lanes): :infinity — a human reviewer may take
  # hours or overnight. Failing the polecat after 30 min was a false negative
  # (bd-akr4il, VR-17739). The Warden polls indefinitely until the MR is
  # merged or closed. Override via workspace config["merge"]["warden_max_polls"].
  @default_max_polls_auto 30
  @default_max_polls_manual :infinity

  @type opt ::
          {:bead_id, String.t()}
          | {:polecat, pid() | String.t()}
          | {:mr_ref, String.t()}
          | {:adapter, module()}
          | {:workspace, Arbiter.Beads.Workspace.t() | nil}
          | {:auto_merge, boolean()}
          | {:via_tribunal, boolean()}
          | {:interval_ms, non_neg_integer()}
          | {:initial_delay_ms, non_neg_integer()}
          | {:max_polls, non_neg_integer()}
          | {:watch_pipeline, boolean()}

  @type opts :: [opt()]

  # ---- public API ---------------------------------------------------------

  @doc """
  Start a Warden under `Arbiter.Polecat.WardenSupervisor`.

  Required opts: `:bead_id`, `:polecat` (pid or bead_id), `:mr_ref`,
  `:adapter`. Optional:

    * `:workspace`
    * `:auto_merge` (default `false`)
    * `:via_tribunal` (default `false`) — when true, the Tribunal gate has
      already approved this MR; the Warden treats every non-terminal poll as
      `:approved` and forces auto-merge, so the merge fires on the first poll
      without waiting for a hosted-forge approval the gate never posts.
    * `:interval_ms` (default `#{@default_interval_ms}`)
    * `:initial_delay_ms` (default `0` — poll once promptly, then on the interval)
    * `:max_polls` — consecutive `:pending` polls before the Warden escalates.
      Default is `#{@default_max_polls_auto}` when `auto_merge: true` (fail
      loudly — auto-merge should fire quickly) and `:infinity` when
      `auto_merge: false` (human-merge lanes; a human may take overnight or
      longer, so the Warden parks rather than hard-fails). When a finite cap is
      reached on a manual lane the polecat is **left parked** in
      `:awaiting_review` and the Warden stops polling — it is NOT failed.
      Pass `:infinity` to disable the watchdog entirely.
  """
  @spec start(opts()) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Polecat.WardenSupervisor, {__MODULE__, opts})
  end

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc "Default poll interval in milliseconds."
  @spec default_interval_ms() :: pos_integer()
  def default_interval_ms, do: @default_interval_ms

  @doc """
  Default watchdog cap for `auto_merge: true` lanes (30 polls).
  For `auto_merge: false` lanes the default is `:infinity`.
  """
  @spec default_max_polls_auto() :: pos_integer()
  def default_max_polls_auto, do: @default_max_polls_auto

  @doc "Default watchdog cap for `auto_merge: false` (manual-merge) lanes."
  @spec default_max_polls_manual() :: :infinity
  def default_max_polls_manual, do: @default_max_polls_manual

  @doc """
  Classify a `Arbiter.Mergers.get/1` result map into an approval outcome.

  This is the single approval-detection decision point — see the moduledoc's
  webhook note. `:merged` wins over `:approved` (a merged MR may also report
  `approved: true`); `:closed` is terminal-fail; everything else is `:pending`.
  """
  @spec classify(map()) :: :merged | :approved | :closed | :pending
  def classify(%{status: :merged}), do: :merged
  def classify(%{status: :closed}), do: :closed
  def classify(%{approved: true}), do: :approved
  def classify(_), do: :pending

  # ---- GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    bead_id = Keyword.fetch!(opts, :bead_id)
    adapter = Keyword.fetch!(opts, :adapter)
    mr_ref = Keyword.fetch!(opts, :mr_ref)

    polecat_pid =
      case Keyword.fetch!(opts, :polecat) do
        pid when is_pid(pid) -> pid
        ref when is_binary(ref) -> Polecat.whereis(ref)
      end

    cond do
      not is_pid(polecat_pid) ->
        # Nothing to watch — the polecat is already gone.
        :ignore

      true ->
        workspace = Keyword.get(opts, :workspace)
        Mergers.prepare(workspace)

        via_tribunal = Keyword.get(opts, :via_tribunal, false)
        # A Tribunal-approved MR has no pending hosted-forge approval to wait
        # for, so auto_merge is implicit. Honor any explicit override (for
        # tests) but default to true when the gate has approved.
        auto_merge = Keyword.get(opts, :auto_merge, via_tribunal)

        default_max_polls =
          if auto_merge, do: @default_max_polls_auto, else: @default_max_polls_manual

        watch_pipeline =
          case Keyword.get(opts, :watch_pipeline) do
            flag when is_boolean(flag) -> flag
            _ -> watch_pipeline_from_workspace(workspace)
          end

        state = %{
          bead_id: bead_id,
          polecat_pid: polecat_pid,
          mr_ref: mr_ref,
          adapter: adapter,
          workspace: workspace,
          auto_merge: auto_merge,
          via_tribunal: via_tribunal,
          interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
          max_polls: Keyword.get(opts, :max_polls, default_max_polls),
          poll_count: 0,
          watch_pipeline: watch_pipeline,
          last_pipeline: nil
        }

        Process.monitor(polecat_pid)
        schedule(self(), Keyword.get(opts, :initial_delay_ms, 0))
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case safe_get(state) do
      {:ok, result} when is_map(result) ->
        record_status(state, result)
        state = maybe_escalate_pipeline(state, result)
        apply_outcome(effective_outcome(state, result), result, state)

      {:error, reason} ->
        Logger.debug(
          "Polecat.Warden: get/1 error for bead=#{state.bead_id} mr=#{state.mr_ref}: #{inspect(reason)}"
        )

        reschedule(state)
    end
  end

  # Polecat died — nothing left to watch.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{polecat_pid: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The Tribunal gate approves in-process — hosted-forge adapters never see
  # that approval on the PR/MR itself, so `classify/1` would forever return
  # `:pending`. When the polecat told us the gate already approved, treat any
  # non-terminal status as `:approved` so the auto-merge path fires on the
  # first poll. `:merged` / `:closed` still win because they're terminal facts
  # about the MR itself, not approval-state interpretation.
  defp effective_outcome(%{via_tribunal: true} = _state, result) do
    case classify(result) do
      :pending -> :approved
      other -> other
    end
  end

  defp effective_outcome(_state, result), do: classify(result)

  # ---- outcome handling ---------------------------------------------------
  #
  # The poll loop and any future webhook trigger both funnel through
  # apply_outcome/3, so the approval semantics stay in one place.

  defp apply_outcome(:merged, _result, state) do
    Logger.info("Polecat.Warden: MR #{state.mr_ref} merged for bead=#{state.bead_id}")
    safe(fn -> Polecat.complete(state.polecat_pid, :merged) end)
    {:stop, :normal, state}
  end

  defp apply_outcome(:closed, _result, state) do
    Logger.info("Polecat.Warden: MR #{state.mr_ref} closed for bead=#{state.bead_id}")
    safe(fn -> Polecat.fail(state.polecat_pid, {:mr_closed, state.mr_ref}) end)
    {:stop, :normal, state}
  end

  defp apply_outcome(:approved, _result, %{auto_merge: true} = state) do
    case safe_merge(state) do
      :ok ->
        Logger.info(
          "Polecat.Warden: auto-merged approved MR #{state.mr_ref} for bead=#{state.bead_id}"
        )

        safe(fn -> Polecat.complete(state.polecat_pid, :merged) end)
        {:stop, :normal, state}

      {:error, reason} ->
        # Merge failed (race, branch conflict, transient). Stay parked and let
        # the next poll re-attempt rather than failing the bead outright.
        Logger.warning(
          "Polecat.Warden: auto-merge failed for bead=#{state.bead_id} mr=#{state.mr_ref}: #{inspect(reason)}; will retry"
        )

        reschedule(state)
    end
  end

  defp apply_outcome(:approved, _result, state) do
    # Approved but auto_merge is off: park until a human merges. The next poll
    # will see :merged and complete.
    reschedule(state)
  end

  defp apply_outcome(:pending, _result, state), do: reschedule(state)

  # ---- internals ----------------------------------------------------------

  defp record_status(state, result) do
    safe(fn ->
      Polecat.record_merger_status(state.polecat_pid, result)
    end)
  end

  # When watch_pipeline is enabled, escalate to the Admiral on the first poll
  # that reports a failed pipeline. Stay parked — a human may force-merge or
  # rerun. Only escalates once per failure sequence (tracks last_pipeline to
  # suppress repeated alerts on consecutive :failed polls).
  defp maybe_escalate_pipeline(%{watch_pipeline: false} = state, _result), do: state

  defp maybe_escalate_pipeline(state, result) do
    current_pipeline = Map.get(result, :pipeline)

    if current_pipeline == :failed and state.last_pipeline != :failed do
      Logger.warning(
        "Polecat.Warden: CI pipeline failed for bead=#{state.bead_id} mr=#{state.mr_ref}; " <>
          "escalating to Admiral, staying parked"
      )

      safe(fn ->
        snap =
          case safe_snapshot(state.polecat_pid) do
            %{} = s -> s
            _ -> %{bead_id: state.bead_id, workspace_id: nil}
          end

        Arbiter.Messages.AdmiralNotifier.pipeline_failed(snap, state.mr_ref)
      end)
    end

    %{state | last_pipeline: current_pipeline}
  end

  defp watch_pipeline_from_workspace(nil), do: false

  defp watch_pipeline_from_workspace(%Arbiter.Beads.Workspace{} = ws),
    do: Arbiter.Beads.Workspace.watch_pipeline?(ws)

  defp watch_pipeline_from_workspace(_), do: false

  # Watchdog: bd-66ey1o / bd-akr4il. After `:max_polls` consecutive non-terminal
  # polls, escalate to the Admiral and either:
  #   - auto_merge ON  → fail the polecat (auto-merge should fire quickly; a 30-
  #                       min timeout means something is broken on the forge side)
  #   - auto_merge OFF → park the polecat (a human reviewer may take overnight or
  #                       longer; failing here was a false negative — VR-17739).
  #                       The Warden stops polling to free resources, and the
  #                       polecat stays in :awaiting_review so a boot-resume or
  #                       webhook can re-attach it later.
  # Pass `max_polls: :infinity` to disable.
  defp reschedule(%{max_polls: cap, poll_count: count, auto_merge: true} = state)
       when is_integer(cap) and cap > 0 and count + 1 >= cap do
    Logger.warning(
      "Polecat.Warden: bead=#{state.bead_id} mr=#{state.mr_ref} exceeded " <>
        "#{cap} polls without a terminal outcome; escalating + failing"
    )

    escalate_watchdog(state)
    safe(fn -> Polecat.fail(state.polecat_pid, {:awaiting_review_timeout, cap}) end)
    {:stop, :normal, %{state | poll_count: count + 1}}
  end

  defp reschedule(%{max_polls: cap, poll_count: count, auto_merge: false} = state)
       when is_integer(cap) and cap > 0 and count + 1 >= cap do
    Logger.warning(
      "Polecat.Warden: bead=#{state.bead_id} mr=#{state.mr_ref} exceeded " <>
        "#{cap} polls on a manual-merge lane; parking (polecat stays :awaiting_review)"
    )

    escalate_watchdog(state)
    {:stop, :normal, %{state | poll_count: count + 1}}
  end

  defp reschedule(state) do
    schedule(self(), state.interval_ms)
    {:noreply, %{state | poll_count: state.poll_count + 1}}
  end

  defp escalate_watchdog(state) do
    snap =
      case safe_snapshot(state.polecat_pid) do
        %{} = s -> s
        _ -> %{bead_id: state.bead_id, workspace_id: nil}
      end

    safe(fn ->
      Arbiter.Messages.AdmiralNotifier.awaiting_review_stuck(snap, state.mr_ref)
    end)
  end

  defp safe_snapshot(pid) do
    Polecat.state(pid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp schedule(pid, ms) when is_integer(ms) and ms >= 0 do
    Process.send_after(pid, :poll, ms)
  end

  defp safe_get(%{adapter: adapter, mr_ref: mr_ref}) do
    adapter.get(mr_ref)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe_merge(%{adapter: adapter, mr_ref: mr_ref}) do
    case adapter.merge(mr_ref) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_return, other}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
