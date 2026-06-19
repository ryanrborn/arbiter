defmodule Arbiter.Workflows.PRPatrol do
  @moduledoc """
  Per-repo GenServer that polls open PRs and dispatches follow-up workers
  when reviews need attention. Replaces the Go GT `mol-pr-feedback-patrol`
  cron loop.

  ## Triggers

  A PR is considered "actionable" when any of these is true:

    * Any review on the PR has `state == "CHANGES_REQUESTED"`
      (highest-priority signal).

  Future triggers (deferred to a follow-up bead — see BUILD-SUMMARY):

    * `statusCheckRollup` contains FAILURE — needs the GraphQL API or a
      separate `check-runs` fetch keyed off the PR head SHA.
    * Unresolved review threads — only available via GraphQL
      `pullRequest.reviewThreads`.

  Both deferred triggers require API surface that doesn't exist on
  `Arbiter.GitHub` yet; rather than building the surface speculatively, the
  CHANGES_REQUESTED case (the most common in practice) is shipped first and
  the other two are filed as follow-ups.

  ## Dedup

  Each follow-up bead is tagged with `tracker_type: :github, tracker_ref:
  to_string(pr_number)`. Before dispatching, PRPatrol queries `Issue` for
  open beads with that combination — if one exists, the PR has already been
  handled this cycle.

  ## Lifecycle

  Not in `Application.children`. Started manually per-workspace:

      Arbiter.Workflows.PRPatrol.start_link(
        repo: "leo-technologies-llc/verus_server",
        workspace_id: ws.id,
        interval_ms: 60_000
      )

  Test convenience: `tick/1` forces a synchronous patrol cycle without
  waiting for the next interval.
  """

  use GenServer

  alias Arbiter.Beads.Issue
  alias Arbiter.GitHub
  alias Arbiter.Worker
  require Ash.Query

  @default_interval_ms 60_000

  defstruct [
    :repo,
    :workspace_id,
    :interval_ms,
    :timer_ref,
    ticks: 0,
    last_dispatched: %{},
    last_tick_at: nil
  ]

  # ---- public API ----

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Synchronously force a patrol cycle. Returns :ok after the cycle completes."
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc "Snapshot of internal state."
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    state = %__MODULE__{
      repo: repo,
      workspace_id: workspace_id,
      interval_ms: interval_ms
    }

    {:ok, schedule_next(state)}
  end

  @impl true
  def handle_call(:tick, _from, state) do
    new_state = do_tick(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:state, _from, state),
    do:
      {:reply,
       %{
         repo: state.repo,
         workspace_id: state.workspace_id,
         interval_ms: state.interval_ms,
         ticks: state.ticks,
         last_dispatched: state.last_dispatched,
         last_tick_at: state.last_tick_at
       }, state}

  @impl true
  def handle_info(:tick, state) do
    new_state = do_tick(state) |> schedule_next()
    {:noreply, new_state}
  end

  # ---- tick logic ----

  defp do_tick(state) do
    case GitHub.pr_list_open(state.repo) do
      {:ok, prs} ->
        Enum.each(prs, &maybe_dispatch(&1, state))
        %{state | ticks: state.ticks + 1, last_tick_at: DateTime.utc_now()}

      {:error, _} ->
        # On API failure, still bump the tick counter so callers can detect
        # the patrol is alive. The next cycle will retry.
        %{state | ticks: state.ticks + 1, last_tick_at: DateTime.utc_now()}
    end
  end

  defp maybe_dispatch(%{"number" => pr_number} = pr, state) do
    if actionable?(state.repo, pr_number) and not deduped?(pr_number) do
      bead = create_follow_up(pr, state)
      _ = Worker.start(bead_id: bead.id, repo: state.repo, workspace_id: state.workspace_id)
      :ok
    end
  end

  defp actionable?(repo, pr_number) do
    case GitHub.pr_list_reviews(repo, pr_number) do
      {:ok, reviews} when is_list(reviews) ->
        Enum.any?(reviews, fn r -> r["state"] == "CHANGES_REQUESTED" end)

      _ ->
        false
    end
  end

  defp deduped?(pr_number) do
    ref = to_string(pr_number)

    Issue
    |> Ash.Query.filter(tracker_type == :github and tracker_ref == ^ref and status != :closed)
    |> Ash.read!()
    |> Enum.any?()
  end

  defp create_follow_up(pr, state) do
    title = "PR ##{pr["number"]}: #{pr["title"]} needs follow-up"

    description =
      """
      Auto-filed by PRPatrol against #{state.repo}.

      Trigger: at least one review with state=CHANGES_REQUESTED.

      Original PR: #{pr["html_url"] || ""}
      """

    {:ok, bead} =
      Ash.create(Issue, %{
        title: title,
        description: description,
        issue_type: :task,
        priority: 2,
        tracker_type: :github,
        tracker_ref: to_string(pr["number"]),
        workspace_id: state.workspace_id
      })

    bead
  end

  defp schedule_next(state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :tick, state.interval_ms)
    %{state | timer_ref: ref}
  end
end
