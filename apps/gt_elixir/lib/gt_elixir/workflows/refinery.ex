defmodule GtElixir.Workflows.Refinery do
  @moduledoc """
  Per-workspace merge-queue GenServer. Picks up "polecat done" events,
  opens PRs (or merges directly per workspace config), polls them for
  approval + CI, merges with the configured strategy, and transitions
  beads to `:closed` when the merge lands.

  ## Lifecycle

      start_link(workspace_id: ws.id)
        │
        ▼
      subscribes to PubSub topic "polecat:done:" <> workspace_id
        │
        ▼
      receives {:polecat_done, bead_id}
        │
        ▼
      loads bead → reads merge_strategy → opens PR (or skips for :direct)
        │
        ▼
      tick/0 (every poll_interval_ms) → polls in-flight PRs → merges → closes bead

  ## State machine (per in-flight item)

  The status is an explicit atom enum, not a polymorphic struct or behaviour:

      :opening
        │   pr_open succeeded
        ▼
      :awaiting_approval
        │   reviewDecision == "APPROVED"
        ▼
      :ci_running
        │   mergeStateStatus == "clean"
        ▼
      :ready_to_merge
        │   pr_merge accepted
        ▼
      :merging
        │   merge confirmed
        ▼
      :done   →   bead transitioned to :closed, item removed

  Errors anywhere set status to `:failed` and stop further polling on that
  item; the bead is NOT closed on failure. The reviewer can drive recovery
  manually.

  ## merge_strategy

  Read from `workspace.config["merge"]["strategy"]`. Valid values:

    * `"squash"` (default) — `GitHub.pr_merge/4` with `:squash`
    * `"merge"`            — `:merge`
    * `"rebase"`           — `:rebase`
    * `"direct"`           — **never opens a PR**. The bead is immediately
      transitioned to `:done` (and then `:closed`). This is the "personal
      project" path; the polecat is assumed to have already pushed +
      merged its branch out-of-band. It exists specifically because
      verus_server-style team workflows must default to `pr`, and earlier
      Phase-3 code conflated "merge directly" with "no PR" in a way that
      was hostile to the team default.

  In particular, **`merge_strategy="pr"` (or any non-direct value) MUST
  NEVER call `Worktree.push/2` from this module**. The polecat that
  produced the "done" event is responsible for pushing its branch. The
  refinery's job ends at the PR boundary.

  ## PubSub topic

  Subscribes to `"polecat:done:" <> workspace_id`. Per-workspace because
  each Refinery process runs against exactly one workspace and shouldn't
  see other workspaces' events. The polecat (or the orchestrator that
  drives it) is responsible for broadcasting to that topic when its
  workflow completes successfully.

  Subscribers to `"refinery:" <> workspace_id` will receive
  `{:bead_closed_by_refinery, bead_id}` once the merge lands.

  ## Supervision

  This GenServer is **NOT** started under `GtElixir.Application` by
  default. Workspaces are dynamic — there's no static list to enumerate at
  boot — so a future supervisor (gte-024 territory) will start one
  refinery per workspace lazily. For now, tests and CLI tools start it
  manually with `start_link/1`.

  ## Configuration knobs (start_link/1 opts)

    * `:workspace_id` (string, required) — the workspace this refinery serves.
    * `:name` — process name (default `__MODULE__`).
    * `:poll_interval_ms` — how often `:tick` fires (default 30_000).
    * `:repo` / `:base` — override the repo + base branch instead of reading
      them from `workspace.config["merge"]`. Convenient for tests.
    * `:github_token` — passed through to every `GtElixir.GitHub` call.
    * `:auto_tick` — when `false` (default `true`), the periodic `:tick`
      timer is not scheduled. Tests use `false` and drive ticks via
      `tick/1` so they don't race with real time.
  """

  use GenServer

  require Logger

  alias GtElixir.Beads.Issue
  alias GtElixir.GitHub

  @default_poll_interval_ms 30_000
  @default_strategy "squash"

  @typedoc "Status atom for an in-flight item."
  @type status ::
          :opening
          | :awaiting_approval
          | :ci_running
          | :ready_to_merge
          | :merging
          | :done
          | :failed

  @typedoc "An in-flight merge queue item."
  @type item :: %{
          bead_id: String.t(),
          pr_number: pos_integer() | nil,
          status: status(),
          strategy: String.t(),
          opened_at: DateTime.t() | nil,
          last_polled_at: DateTime.t() | nil,
          last_error: term() | nil
        }

  defmodule State do
    @moduledoc false
    defstruct [
      :workspace_id,
      :repo,
      :base,
      :github_token,
      :poll_interval_ms,
      :auto_tick,
      :pubsub_topic,
      items: []
    ]
  end

  # ---- public API ---------------------------------------------------------

  @doc """
  Start a refinery for a workspace. See moduledoc for options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Synchronously enqueue a bead for merging. Behaves the same as receiving
  a `{:polecat_done, bead_id}` PubSub message. Returns `:ok` on enqueue
  even if the actual PR open / merge hasn't happened yet (it runs inside
  the GenServer's `handle_call` though, so by the time this returns the
  initial state transition has been recorded).
  """
  @spec enqueue(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def enqueue(server \\ __MODULE__, bead_id) when is_binary(bead_id) do
    GenServer.call(server, {:enqueue, bead_id})
  end

  @doc """
  Return a snapshot of the refinery state for inspection / tests.
  """
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  end

  @doc """
  Force a poll cycle. In tests, prefer this over waiting for the periodic
  timer. Returns `:ok` once the cycle completes.
  """
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__) do
    GenServer.call(server, :tick)
  end

  # ---- GenServer callbacks ------------------------------------------------

  @impl true
  def init(opts) do
    workspace_id =
      case Keyword.fetch(opts, :workspace_id) do
        {:ok, id} when is_binary(id) and id != "" -> id
        _ -> raise ArgumentError, "Refinery requires :workspace_id"
      end

    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    auto_tick = Keyword.get(opts, :auto_tick, true)
    topic = "polecat:done:" <> workspace_id

    # Subscribe to polecat done events for this workspace.
    :ok = Phoenix.PubSub.subscribe(GtElixir.PubSub, topic)

    state = %State{
      workspace_id: workspace_id,
      repo: Keyword.get(opts, :repo),
      base: Keyword.get(opts, :base, "main"),
      github_token: Keyword.get(opts, :github_token),
      poll_interval_ms: poll_interval_ms,
      auto_tick: auto_tick,
      pubsub_topic: topic,
      items: []
    }

    if auto_tick, do: schedule_tick(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:enqueue, bead_id}, _from, %State{} = state) do
    {reply, state} = do_enqueue(state, bead_id)
    {:reply, reply, state}
  end

  def handle_call(:state, _from, %State{} = state) do
    {:reply, snapshot(state), state}
  end

  def handle_call(:tick, _from, %State{} = state) do
    {:reply, :ok, poll_all(state)}
  end

  @impl true
  def handle_info({:polecat_done, bead_id}, %State{} = state) when is_binary(bead_id) do
    {_reply, state} = do_enqueue(state, bead_id)
    {:noreply, state}
  end

  def handle_info(:tick, %State{} = state) do
    state = poll_all(state)
    if state.auto_tick, do: schedule_tick(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- enqueue + state-machine driver -------------------------------------

  defp do_enqueue(state, bead_id) do
    case Ash.get(Issue, bead_id) do
      {:ok, bead} ->
        # Reload workspace to pick up the merge config block. Issue belongs_to
        # workspace but the relationship isn't always loaded.
        {:ok, bead} = Ash.load(bead, [:workspace])
        strategy = strategy_for(bead.workspace, "merge", "strategy", @default_strategy)

        cond do
          already_queued?(state, bead_id) ->
            {{:ok, :already_queued}, state}

          strategy == "direct" ->
            # direct: never call PR APIs. The polecat owned the push + merge;
            # we just transition the bead. This is the explicit escape hatch
            # for personal projects that don't use the PR workflow.
            item = new_item(bead_id, strategy, status: :done)
            state = %{state | items: [item | state.items]}
            state = close_bead_and_finalize(state, item)
            {:ok, state}

          true ->
            open_pr_for(state, bead, strategy)
        end

      {:error, _} = err ->
        {err, state}
    end
  end

  defp open_pr_for(state, bead, strategy) do
    repo = state.repo || strategy_for(bead.workspace, "merge", "repo", nil)
    base = state.base || strategy_for(bead.workspace, "merge", "base", "main") || "main"
    branch = strategy_for(bead.workspace, "merge", "branch_prefix", "") <> bead.id
    title = bead.title
    body = bead.description || ""

    cond do
      is_nil(repo) ->
        item = new_item(bead.id, strategy, status: :failed, last_error: :no_repo_configured)
        {{:error, :no_repo_configured}, %{state | items: [item | state.items]}}

      true ->
        case GitHub.pr_open(repo, branch, base, title, body, gh_opts(state)) do
          {:ok, %{"number" => pr_number}} when is_integer(pr_number) ->
            item =
              new_item(bead.id, strategy,
                pr_number: pr_number,
                status: :awaiting_approval,
                opened_at: DateTime.utc_now()
              )

            # Record PR number on the bead via tracker_ref if it doesn't already
            # have one. Best-effort: failure to update the bead doesn't fail the
            # whole enqueue.
            _ = maybe_record_tracker_ref(bead, pr_number)

            {:ok, %{state | items: [item | state.items]}}

          {:ok, _other} ->
            item = new_item(bead.id, strategy, status: :failed, last_error: :pr_open_no_number)
            {{:error, :pr_open_no_number}, %{state | items: [item | state.items]}}

          {:error, reason} ->
            item = new_item(bead.id, strategy, status: :failed, last_error: reason)
            {{:error, reason}, %{state | items: [item | state.items]}}
        end
    end
  end

  defp poll_all(%State{items: items} = state) do
    {new_items, state} =
      Enum.map_reduce(items, state, fn item, acc -> poll_item(acc, item) end)

    # Drop items that have reached :done — they've been closed already.
    new_items = Enum.reject(new_items, &(&1.status == :done))
    %{state | items: new_items}
  end

  defp poll_item(state, %{status: :failed} = item), do: {item, state}
  defp poll_item(state, %{status: :done} = item), do: {item, state}

  defp poll_item(state, %{pr_number: nil} = item) do
    # Should not happen: only the :direct path skips pr_number, and that path
    # sets status to :done immediately. Defensive.
    {item, state}
  end

  defp poll_item(state, item) do
    case GitHub.pr_get(repo_for(state, item), item.pr_number, gh_opts(state)) do
      {:ok, pr_payload} ->
        advance_status(state, item, pr_payload)

      {:error, reason} ->
        {%{item | status: :failed, last_error: reason, last_polled_at: DateTime.utc_now()},
         state}
    end
  end

  # Walk the PR payload through the status machine. We re-evaluate the
  # *current* status against the payload on every tick so a long-lived item
  # can climb several rungs in one cycle (e.g. open → approved + clean in
  # one poll → ready_to_merge → merging → done).
  defp advance_status(state, item, pr_payload) do
    review = Map.get(pr_payload, "reviewDecision")
    merge_state = Map.get(pr_payload, "mergeStateStatus")
    mergeable = Map.get(pr_payload, "mergeable")
    now = DateTime.utc_now()

    item = %{item | last_polled_at: now}

    cond do
      # Top-priority guard: a non-mergeable PR never advances state, even when
      # the review is APPROVED. Human/reviewer must rebase or resolve conflicts
      # before the queue does anything.
      mergeable == false ->
        {item, state}

      item.status == :awaiting_approval and review == "APPROVED" and merge_state == "clean" ->
        try_merge(state, %{item | status: :ready_to_merge})

      item.status == :awaiting_approval and review == "APPROVED" ->
        {%{item | status: :ci_running}, state}

      item.status == :ci_running and merge_state == "clean" ->
        try_merge(state, %{item | status: :ready_to_merge})

      item.status == :ready_to_merge and merge_state == "clean" ->
        try_merge(state, item)

      true ->
        # No transition this cycle.
        {item, state}
    end
  end

  defp try_merge(state, item) do
    strategy_atom = strategy_to_atom(item.strategy)
    repo = repo_for(state, item)

    case GitHub.pr_merge(repo, item.pr_number, strategy_atom, gh_opts(state)) do
      {:ok, _payload} ->
        item = %{item | status: :merging}
        # Synchronously finalize. We could leave :merging in place and confirm
        # on the next tick, but pr_merge returning {:ok, ...} is the merge
        # confirmation from GitHub's perspective, so it's safe to close now.
        item = %{item | status: :done}
        state = close_bead_and_finalize(state, item)
        {item, state}

      {:error, reason} ->
        {%{item | status: :failed, last_error: reason}, state}
    end
  end

  defp close_bead_and_finalize(state, item) do
    case Ash.get(Issue, item.bead_id) do
      {:ok, bead} ->
        case Ash.update(bead, %{}, action: :close) do
          {:ok, _closed} ->
            broadcast_refinery_event(state, {:bead_closed_by_refinery, item.bead_id})

          {:error, reason} ->
            Logger.warning(
              "Refinery: failed to close bead #{item.bead_id}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "Refinery: bead #{item.bead_id} vanished before close: #{inspect(reason)}"
        )
    end

    state
  end

  # ---- helpers ------------------------------------------------------------

  defp new_item(bead_id, strategy, overrides) do
    base = %{
      bead_id: bead_id,
      pr_number: nil,
      status: :opening,
      strategy: strategy,
      opened_at: nil,
      last_polled_at: nil,
      last_error: nil
    }

    Map.merge(base, Map.new(overrides))
  end

  defp already_queued?(%State{items: items}, bead_id) do
    Enum.any?(items, fn i -> i.bead_id == bead_id and i.status not in [:done, :failed] end)
  end

  defp strategy_for(workspace, key1, key2, default) do
    case workspace && workspace.config do
      %{} = config ->
        config
        |> Map.get(key1, %{})
        |> case do
          %{} = inner -> Map.get(inner, key2, default)
          _ -> default
        end

      _ ->
        default
    end
  end

  defp strategy_to_atom("squash"), do: :squash
  defp strategy_to_atom("merge"), do: :merge
  defp strategy_to_atom("rebase"), do: :rebase
  defp strategy_to_atom(_), do: :squash

  defp gh_opts(%State{github_token: nil}), do: []
  defp gh_opts(%State{github_token: token}), do: [token: token]

  defp repo_for(state, _item), do: state.repo

  defp maybe_record_tracker_ref(%Issue{tracker_ref: ref}, _pr_number)
       when is_binary(ref) and ref != "" do
    :ok
  end

  defp maybe_record_tracker_ref(%Issue{} = bead, pr_number) do
    case Ash.update(bead, %{tracker_ref: to_string(pr_number)}, action: :update) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_tick(%State{poll_interval_ms: ms}) do
    Process.send_after(self(), :tick, ms)
  end

  defp broadcast_refinery_event(%State{workspace_id: ws_id}, msg) do
    _ = Phoenix.PubSub.broadcast(GtElixir.PubSub, "refinery:" <> ws_id, msg)
    :ok
  end

  defp snapshot(%State{} = s) do
    %{
      workspace_id: s.workspace_id,
      repo: s.repo,
      base: s.base,
      poll_interval_ms: s.poll_interval_ms,
      auto_tick: s.auto_tick,
      pubsub_topic: s.pubsub_topic,
      items: s.items
    }
  end
end
