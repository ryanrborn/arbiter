defmodule Arbiter.Test.StubAutoResumeDispatcher do
  @moduledoc """
  In-memory `Arbiter.Workflows.MergeQueue.AutoResumeDispatcher` stub for tests.

  Backed by a single named `Agent` (like `Arbiter.Test.StubFixPassDispatcher`) so
  calls made from the Watchdog's own process are observable from the test
  process. Records every `resume/1` and `escalate_exhausted/5` call, and returns
  `{:ok, %{stub: true}}` from `resume/1` so the Watchdog treats the auto-resume
  as having succeeded.

  `arm_resume_error/1` makes the next (and all subsequent) `resume/1` calls
  return `{:error, reason}` instead — used to prove the Watchdog falls back to
  escalating when the auto-resume itself can't run (e.g. `:no_outpost`).
  """

  @behaviour Arbiter.Workflows.MergeQueue.AutoResumeDispatcher

  @name __MODULE__.Store

  def reset do
    ensure_started()
    Agent.update(@name, fn _ -> new_state() end)
    :ok
  end

  @doc "Make every subsequent `resume/1` return `{:error, reason}`."
  def arm_resume_error(reason) do
    ensure_started()
    Agent.update(@name, fn s -> %{s | resume_result: {:error, reason}} end)
    :ok
  end

  @doc "Every `resume/1` arg map, oldest first."
  def resumes do
    ensure_started()
    Agent.get(@name, fn s -> Enum.reverse(s.resumes) end)
  end

  @doc "How many times `resume/1` was called."
  def resume_count, do: length(resumes())

  @doc """
  Every `escalate_exhausted/5` call as `{task_id, ws_id, mr_ref, attempts, reason}`,
  oldest first.
  """
  def escalations do
    ensure_started()
    Agent.get(@name, fn s -> Enum.reverse(s.escalations) end)
  end

  @impl true
  def resume(args) do
    ensure_started()

    Agent.get_and_update(@name, fn s ->
      {s.resume_result, %{s | resumes: [args | s.resumes]}}
    end)
  end

  @impl true
  def escalate_exhausted(task_id, workspace_id, mr_ref, attempts, reason) do
    ensure_started()

    Agent.update(@name, fn s ->
      %{s | escalations: [{task_id, workspace_id, mr_ref, attempts, reason} | s.escalations]}
    end)

    :ok
  end

  defp new_state, do: %{resumes: [], escalations: [], resume_result: {:ok, %{stub: true}}}

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
