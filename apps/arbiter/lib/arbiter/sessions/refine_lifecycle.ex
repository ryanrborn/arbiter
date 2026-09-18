defmodule Arbiter.Sessions.RefineLifecycle do
  @moduledoc """
  Ends a refine session when its bound issue leaves the conversation behind
  it: the operator decision recorded in `Arbiter.Sessions.RefineDoctrine`
  (child 4 of epic bd-cksar2, bd-cvfjms) is that a refine session has no
  further work once its bound issue is promoted or closed — promotion is the
  handoff, and a close means the issue is no longer worth refining.

  Subscribes to the same `"tasks"` PubSub topic `Arbiter.Workflows.
  PatrolLifecycle` already reacts to (`Issue.broadcast_lifecycle/2`), and
  reacts to exactly two shapes:

    * `{:task_lifecycle, :updated, %Issue{refined: true}}` — the issue this
      event names just got promoted (via `task_promote`, whether the
      session's own call or anyone else's, or the `Move to Ready` button).
      Ends with `end_reason: "promoted"`.
    * `{:task_lifecycle, :closed, issue}` — ends with `end_reason:
      "issue_closed"`.

  Every other `:task_lifecycle` event (including a plain `:updated` that
  leaves `refined` false — an edit, a title change) is ignored outright: only
  these two shapes can possibly be the bound issue's terminal transition.

  ## Scoped by construction, not by tracking state

  There is no bookkeeping here of "which issue is this session bound to" —
  `Arbiter.Sessions.Refine.live_session/1` is queried fresh for `issue.id` on
  every matching event, and a `:none` result (no live refine session bound to
  *this* issue) is silently a no-op. That is what keeps promoting a **child**
  issue from ending the session that filed it: a child has its own `id`, so
  its `:updated` event never matches the bound issue's `live_session/1`
  lookup. The refine doctrine already tells the agent to promote children and
  the bound issue together, last — this module doesn't need to enforce an
  order, because only the bound issue's own promotion can ever be the trigger.

  ## Why `:promote_to_ready` broadcasts post-commit

  `Issue.broadcast_lifecycle/2` for `:promote_to_ready` fires from an
  `after_transaction` hook (matching `:close`'s own reasoning, stated on that
  action: a separate-connection subscriber must see the committed row). This
  module writes a fallback summary note to the same issue row it just read
  off the broadcast (`ensure_summary/1`) — reading and writing that row from
  this process, before the promoting transaction has committed, would be the
  exact race `:close`'s comment warns about.

  ## The refinement summary fallback

  The refine doctrine instructs the agent to write a short summary via
  `task_update`'s `notes` field before promoting. An agent that skips this
  (the conversation ran out of context, an ended session, an operator
  promoting from the dashboard without ever opening a refine session) must
  not leave the issue with nothing — so `ensure_summary/1` writes a plain
  system note only when `notes` is still blank at end time. It never
  overwrites a summary the agent did write.

  ## Gating

  Same switch as `Arbiter.Workflows.PatrolLifecycle`:
  `:arbiter, :auto_start_refineries` (default `true`, `false` in test) — off
  by default in the suite so a global instance started by the application
  tree never touches an issue/session outside the sandbox connection a given
  test allowed it. Tests that need this behavior start their own named
  instance with `enabled?: true` (and usually `runner: SessionRunnerStub`).
  """

  use GenServer

  require Logger

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Refine
  alias Arbiter.Tasks.Issue

  @topic "tasks"

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    enabled? =
      Keyword.get(opts, :enabled?, Application.get_env(:arbiter, :auto_start_refineries, true))

    if enabled?, do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @topic)

    {:ok, %{enabled?: enabled?, runner: Keyword.get(opts, :runner)}}
  end

  @impl true
  def handle_info(
        {:task_lifecycle, :updated, %Issue{refined: true} = issue},
        %{enabled?: true} = state
      ) do
    end_bound_session(issue, "promoted", state)
    {:noreply, state}
  rescue
    e ->
      log_reaction_failure(issue.id, e)
      {:noreply, state}
  end

  def handle_info({:task_lifecycle, :closed, %Issue{} = issue}, %{enabled?: true} = state) do
    end_bound_session(issue, "issue_closed", state)
    {:noreply, state}
  rescue
    e ->
      log_reaction_failure(issue.id, e)
      {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- internals ----------------------------------------------------------

  defp end_bound_session(%Issue{} = issue, reason, state) do
    case Refine.live_session(issue.id) do
      {:ok, session} ->
        ensure_summary(issue, reason)

        kill_opts =
          if state.runner, do: [reason: reason, runner: state.runner], else: [reason: reason]

        case Sessions.kill(session.id, kill_opts) do
          {:ok, _ended} ->
            :ok

          {:error, error} ->
            Logger.warning(
              "RefineLifecycle: could not end session #{session.id} bound to " <>
                "#{issue.id} (reason=#{reason}): #{inspect(error)}"
            )

            :ok
        end

      :none ->
        :ok
    end
  end

  defp ensure_summary(%Issue{} = issue, reason) do
    if blank?(issue.notes) do
      case Ash.update(issue, %{notes: fallback_note(reason)}, action: :update) do
        {:ok, _updated} ->
          :ok

        {:error, error} ->
          Logger.warning(
            "RefineLifecycle: could not write the fallback summary for #{issue.id}: " <>
              inspect(error)
          )

          :ok
      end
    else
      :ok
    end
  end

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")

  defp fallback_note(reason) do
    "_Refinement summary unavailable — this refine session ended (#{reason}) " <>
      "without writing one via `task_update`. See the session's archived " <>
      "transcript, linked on this issue, for the refinement conversation._"
  end

  # Never let a lifecycle reaction crash the subscriber — losing the
  # subscription would silently stop every future promote/close from ending
  # its refine session.
  defp log_reaction_failure(issue_id, error) do
    Logger.warning(
      "RefineLifecycle: reaction to a lifecycle event for #{issue_id} failed: " <>
        Exception.message(error)
    )
  end
end
