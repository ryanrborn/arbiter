defmodule Arbiter.Test.StubFixRoundDispatcher do
  @moduledoc """
  In-memory `Arbiter.Workflows.ReviewGateFixRoundDispatcher` stub for tests.

  Backed by a single named `Agent` (like `Arbiter.Test.StubAutoResumeDispatcher`)
  so calls made from the worker's own process — or from the supervised Task it
  hands the dispatch to — are observable from the test process.

  This is the DEFAULT dispatcher in the test environment (`config/test.exs`), so
  the ReviewGate-rejection auto-fix-round never spawns a real agent or shells
  out to git during the suite. Tests that care assert against `dispatches/0` /
  `escalations/0`; every other test simply gets a no-op.
  """

  @behaviour Arbiter.Workflows.ReviewGateFixRoundDispatcher

  @name __MODULE__.Store

  def reset do
    ensure_started()
    Agent.update(@name, fn _ -> new_state() end)
    :ok
  end

  @doc "Make every subsequent `dispatch/1` return `{:error, reason}`."
  def arm_dispatch_error(reason) do
    ensure_started()
    Agent.update(@name, fn s -> %{s | dispatch_result: {:error, reason}} end)
    :ok
  end

  @doc "Every `dispatch/1` arg map, oldest first."
  def dispatches do
    ensure_started()
    Agent.get(@name, fn s -> Enum.reverse(s.dispatches) end)
  end

  @doc "How many times `dispatch/1` was called."
  def dispatch_count, do: length(dispatches())

  @doc """
  Every `escalate_exhausted/4` call as `{task_id, workspace_id, attempts, reason}`,
  oldest first.
  """
  def escalations do
    ensure_started()
    Agent.get(@name, fn s -> Enum.reverse(s.escalations) end)
  end

  @impl true
  def dispatch(args) do
    ensure_started()

    Agent.get_and_update(@name, fn s ->
      {s.dispatch_result, %{s | dispatches: [args | s.dispatches]}}
    end)
  end

  @impl true
  def escalate_exhausted(task_id, workspace_id, attempts, reason) do
    ensure_started()

    Agent.update(@name, fn s ->
      %{s | escalations: [{task_id, workspace_id, attempts, reason} | s.escalations]}
    end)

    :ok
  end

  defp new_state, do: %{dispatches: [], escalations: [], dispatch_result: {:ok, %{stub: true}}}

  # `Agent.start/2` (not `start_link/2`): the store must outlive the test
  # process that first touched it, exactly as StubAutoResumeDispatcher's does.
  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Agent.start(fn -> new_state() end, name: @name) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
