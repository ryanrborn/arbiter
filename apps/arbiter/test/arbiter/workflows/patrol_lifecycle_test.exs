defmodule Arbiter.Workflows.PatrolLifecycleTest do
  # async: false — starts real patrols under the singleton supervisors/registries.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.{PatrolLifecycle, PRPatrolSupervisor, ReviewPatrolSupervisor}

  @pr_registry Arbiter.Workflows.PRPatrolRegistry
  @review_registry Arbiter.Workflows.ReviewPatrolRegistry

  defp github_ws do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "plc-#{System.unique_integer([:positive])}",
        prefix: "pl#{System.unique_integer([:positive])}",
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{"owner" => "octo", "repo" => "widget"}
          }
        }
      })

    ws
  end

  # Start a PatrolLifecycle subscriber with the effect gate forced on (in test
  # auto_start? is false, so the app's own instance is inert). Long interval on
  # any patrol it starts so nothing ticks the forge during the test.
  defp start_subscriber do
    name = :"PatrolLifecycle_#{System.unique_integer([:positive])}"
    pid = start_supervised!({PatrolLifecycle, enabled?: true, name: name})

    on_exit(fn ->
      for reg <- [@pr_registry, @review_registry],
          {pid, _} <- Registry.select(reg, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]),
          is_pid(pid),
          Process.alive?(pid) do
        DynamicSupervisor.terminate_child(PRPatrolSupervisor, pid)
        DynamicSupervisor.terminate_child(ReviewPatrolSupervisor, pid)
      end
    end)

    {pid, name}
  end

  defp await(fun, tries \\ 50) do
    Enum.reduce_while(1..tries, nil, fn _, _ ->
      case fun.() do
        nil -> {:cont, Process.sleep(10) && nil}
        val -> {:halt, val}
      end
    end)
  end

  describe "classify/1" do
    test "a task with a pr_ref is a fleet PR" do
      assert PatrolLifecycle.classify(%Issue{pr_ref: "octo/widget#3"}) == :fleet_pr
    end

    test "a review_only task with a source_pr is an engagement" do
      assert PatrolLifecycle.classify(%Issue{review_only: true, source_pr: "5"}) == :engagement
    end

    test "a plain task with neither is ignored" do
      assert PatrolLifecycle.classify(%Issue{}) == :ignore
    end

    test "a PRPatrol follow-up (source_pr but not review_only, no pr_ref) is ignored" do
      assert PatrolLifecycle.classify(%Issue{review_only: false, source_pr: "5"}) == :ignore
    end
  end

  describe "engagement lifecycle" do
    test "creating an engagement starts a ReviewPatrol; closing it stops the patrol" do
      {_pid, _name} = start_subscriber()
      ws = github_ws()

      {:ok, eng} =
        Ash.create(Issue, %{
          title: "eng",
          tracker_type: :none,
          source_pr: "7",
          review_only: true,
          workspace_id: ws.id
        })

      pid = await(fn -> ReviewPatrolSupervisor.whereis(ws.id) end)
      assert is_pid(pid) and Process.alive?(pid)

      {:ok, _} = Ash.update(eng, %{}, action: :close)

      assert await(fn -> if ReviewPatrolSupervisor.whereis(ws.id) == nil, do: :gone end) == :gone
    end
  end

  describe "does not resurrect patrols for closed items" do
    test "an :updated event on an already-closed fleet-PR task starts nothing" do
      {_pid, name} = start_subscriber()
      ws = github_ws()

      {:ok, task} =
        Ash.create(Issue, %{
          title: "authored",
          description: "d",
          issue_type: :feature,
          tracker_type: :none,
          workspace_id: ws.id
        })

      {:ok, task} = Ash.update(task, %{pr_ref: "#9"}, action: :update)
      {:ok, closed} = Ash.update(task, %{}, action: :close)

      # Reap the patrol the pr_ref update legitimately started, so the state is
      # "no patrol running" before we test the closed-item update.
      for {_k, pid} <- PRPatrolSupervisor.whereis_all(ws.id),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(PRPatrolSupervisor, pid)

      await(fn -> if PRPatrolSupervisor.whereis(ws.id) == nil, do: :gone end)

      # A lifecycle :updated on the CLOSED task (still carries pr_ref) must not
      # resurrect a patrol.
      send(name, {:task_lifecycle, :updated, closed})
      # Flush the subscriber mailbox, then confirm nothing came back.
      _ = :sys.get_state(name)
      assert PRPatrolSupervisor.whereis(ws.id) == nil
    end
  end

  describe "fleet-PR lifecycle" do
    test "stamping a pr_ref starts a PRPatrol" do
      {_pid, _name} = start_subscriber()
      ws = github_ws()

      {:ok, task} =
        Ash.create(Issue, %{
          title: "authored",
          description: "d",
          issue_type: :feature,
          tracker_type: :none,
          workspace_id: ws.id
        })

      # The MergeQueue stamps pr_ref via :update once it opens the PR.
      {:ok, _} = Ash.update(task, %{pr_ref: "#9"}, action: :update)

      pid = await(fn -> PRPatrolSupervisor.whereis(ws.id) end)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
end
