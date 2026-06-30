defmodule Arbiter.Workflows.ConductorReconciler do
  @moduledoc """
  Crash-safe boot recovery for `Arbiter.Workflows.Conductor` processes.

  On a clean boot the `ConductorSupervisor` starts empty. Any graph that was
  `:running` when the node died has no Conductor driving it. This module sweeps
  those orphaned graphs and re-spawns a Conductor for each — deriving all state
  from the DB (graph scope, edges, and member statuses) rather than from lost
  in-memory state.

  ## Why no double-dispatch

  A restarted Conductor calls its `initial_drain` which reads `Issue.ready/0`.
  That function only returns `:open` issues. Tasks that were already claimed by
  a worker before the crash are `:in_progress` in the DB and therefore excluded
  from dispatch. Tasks already completed are `:closed`. Only genuinely unclaimed
  work is re-dispatched — the DB is the source of truth.

  ## Single-instance gate

  The sweep is gated on `Arbiter.SingleInstance.primary?/0`. A secondary
  instance (e.g. a dev `iex` session while the server is up) skips the sweep
  entirely so it cannot start a duplicate Conductor that races the primary's
  live processes.

  ## Pattern

  Mirrors `Arbiter.Workers.Reconciler` — best-effort, logs on failure, returns
  `{:ok, count}`, `{:ok, :skipped}`, or `{:error, reason}`.

  Part of C6 (bd-81iaxo). Depends on C5 (C5 adds failure handling; C6 adds
  crash-safe boot).
  """

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.Graph
  alias Arbiter.Workflows.ConductorSupervisor

  @doc """
  Restart a Conductor for each graph whose `run_state` is `:running` but has
  no live Conductor process.

  Returns `{:ok, count}` where `count` is the number of Conductors started
  (already-running ones are skipped silently), `{:ok, :skipped}` when this
  instance is not the primary, or `{:error, reason}` when the graph read fails.

  ## Options

    * `:primary?` — whether this instance may start Conductors. Defaults to
      `true`; the boot path supplies `Arbiter.SingleInstance.primary?()`.
      When `false`, the sweep is skipped and `{:ok, :skipped}` is returned
      without touching any process.

  Any other options are forwarded to `ConductorSupervisor.start_conductor/2`
  (e.g. `:dispatcher` for tests, `:workspace_max_concurrent`, `:quota_gate`).
  """
  @spec reconcile_running_graphs(keyword()) ::
          {:ok, non_neg_integer() | :skipped} | {:error, term()}
  def reconcile_running_graphs(opts \\ []) do
    if Keyword.get(opts, :primary?, true) do
      do_reconcile(Keyword.delete(opts, :primary?))
    else
      Logger.info(
        "ConductorReconciler: not the primary instance; skipping conductor boot recovery " <>
          "(advisory lock held elsewhere)"
      )

      {:ok, :skipped}
    end
  end

  defp do_reconcile(conductor_opts) do
    running_state = :running

    graphs =
      Graph
      |> Ash.Query.filter(run_state == ^running_state)
      |> Ash.read!()

    started =
      Enum.count(graphs, fn graph ->
        case ConductorSupervisor.start_conductor(graph.id, conductor_opts) do
          {:ok, _pid} ->
            Logger.info("ConductorReconciler: started Conductor for running graph #{graph.id}")

            true

          {:error, {:already_started, _pid}} ->
            false

          {:error, reason} ->
            Logger.warning(
              "ConductorReconciler: failed to start Conductor for graph #{graph.id}: " <>
                inspect(reason)
            )

            false
        end
      end)

    if started > 0 do
      Logger.info("ConductorReconciler: recovered #{started} Conductor(s) on boot")
    end

    {:ok, started}
  rescue
    e ->
      Logger.warning("ConductorReconciler: boot recovery failed: #{Exception.message(e)}")
      {:error, e}
  end
end
