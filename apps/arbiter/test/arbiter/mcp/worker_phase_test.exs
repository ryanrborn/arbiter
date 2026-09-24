defmodule Arbiter.MCP.WorkerPhaseTest do
  @moduledoc """
  bd-aw2cyt: `worker_list` / `worker_show` report the phase a worker is
  actually in, and whether its agent subprocess is live, alongside the
  unchanged `status` every existing consumer still matches on.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "phase-ws-#{System.unique_integer([:positive])}",
        prefix: "phs#{System.unique_integer([:positive])}"
      })

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    %{ws: ws, coordinator: coordinator}
  end

  defp task(ws) do
    {:ok, t} =
      Ash.create(Issue, %{
        title: "phase-#{System.unique_integer([:positive])}",
        workspace_id: ws.id
      })

    t
  end

  defp start_worker(ws, task_id, opts \\ []) do
    opts = Keyword.merge([task_id: task_id, repo: "test/repo", workspace_id: ws.id], opts)
    {:ok, pid} = Worker.start(opts)
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(task_id, :normal) end)
    pid
  end

  describe "worker_list/2" do
    test "a worker parked on a question is not reported as running work", ctx do
      t = task(ctx.ws)
      pid = start_worker(ctx.ws, t.id)
      :ok = Worker.advance(pid, :implement)
      :ok = Worker.await(pid, "which base branch?")

      assert {:ok, %{workers: workers}} = Tools.worker_list(ctx.coordinator, %{})
      entry = Enum.find(workers, &(&1.task_id == t.id))

      # `status` is unchanged for existing consumers…
      assert entry.status == "awaiting"
      # …and the phase says what is actually happening.
      assert entry.phase == "waiting_on_you"
      assert entry.phase_label == "waiting on you"
      assert entry.agent_live == false
    end

    test "an author whose agent has exited stops reading as running work", ctx do
      # The bd-aw2cyt report, on this surface: `vs-8iqckq` showed
      # `status=running` with no process anywhere. The status still says
      # `running` (consumers depend on it); the phase no longer pretends.
      t = task(ctx.ws)
      author = start_worker(ctx.ws, t.id)
      :ok = Worker.advance(author, :implement)

      start_worker(ctx.ws, t.id <> "#review", meta: %{role: :reviewer, reviews: t.id})

      assert {:ok, %{workers: workers}} = Tools.worker_list(ctx.coordinator, %{})

      entry = Enum.find(workers, &(&1.task_id == t.id))
      assert entry.status == "running"
      assert entry.agent_live == false
      refute entry.phase == "implementing"

      reviewer = Enum.find(workers, &(&1.task_id == t.id <> "#review"))
      assert reviewer.role == "reviewer"
      assert reviewer.agent_live == false
      assert is_binary(reviewer.phase)
    end
  end

  describe "worker_show/2" do
    test "carries the phase, its label and the agent liveness", ctx do
      t = task(ctx.ws)
      pid = start_worker(ctx.ws, t.id)
      :ok = Worker.advance(pid, :implement)

      assert {:ok, snap} = Tools.worker_show(ctx.coordinator, %{"task_id" => t.id})

      assert snap.status == "running"
      assert snap.agent_live == false
      assert snap.phase == "handing_off"
      assert is_binary(snap.phase_label)
    end
  end
end
