defmodule Arbiter.Worker.ResumeSlotTest do
  @moduledoc """
  bd-92mx1m: a resume is gated on whether the task **currently holds a slot**,
  not on who is resuming it. A task that still holds its slot passes through
  uncapped (the #1969/#1995 no-deadlock guarantee); one that released it —
  human-parked, stopped, completed — re-acquires one like a new admission.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Events.Record
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.ResumeSlot
  alias Arbiter.Workers.Run

  require Ash.Query

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resume-slot-#{System.unique_integer([:positive])}",
        prefix: "rsl#{System.unique_integer([:positive])}"
      })

    {:ok, a} = Ash.create(Issue, %{title: "task A", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "task B", workspace_id: ws.id})
    %{ws: ws, a: a, b: b}
  end

  defp author(task, status, meta \\ %{}),
    do: %{task_id: task.id, registry_key: task.id, status: status, role: nil, meta: meta}

  defp run!(task, attrs) do
    {:ok, run} =
      Ash.create(
        Run,
        Map.merge(
          %{
            task_id: task.id,
            repo: "test/repo",
            workspace_id: task.workspace_id,
            worker_type: :main,
            status: :failed,
            started_at: DateTime.utc_now()
          },
          attrs
        )
      )

    run
  end

  describe "a task that still holds its slot" do
    test "passes through at a full cap, whoever resumes it", %{a: a, b: b} do
      workers = [author(a, :awaiting_review), author(b, :running)]

      for origin <- [:human, :automatic] do
        assert {:ok, :held} = ResumeSlot.admit(a, origin: origin, workers: workers, cap: 1)
      end
    end

    # The fix-round shape: the ReviewGate failed the author only so the
    # implementer round can replace it. The slot was never given up.
    test "a worker failed mid hand-off still holds its slot", %{a: a, b: b} do
      workers = [author(a, :failed, %{slot_handoff: true}), author(b, :running)]

      assert {:ok, :held} = ResumeSlot.admit(a, origin: :automatic, workers: workers, cap: 1)
    end

    # After a reboot the registry is empty: a task whose run was cut off by the
    # restart was in flight, and its resume is a reboot of in-flight work.
    test "no worker, but the last run was cut off by a restart", %{a: a, b: b} do
      run!(a, %{status: :failed, failure_reason: "server restarted"})

      assert {:ok, :held} =
               ResumeSlot.admit(a, origin: :automatic, workers: [author(b, :running)], cap: 1)

      {:ok, c} = Ash.create(Issue, %{title: "task C", workspace_id: a.workspace_id})
      run!(c, %{status: :interrupted, failure_reason: "server shutdown"})

      assert {:ok, :held} =
               ResumeSlot.admit(c, origin: :automatic, workers: [author(b, :running)], cap: 1)
    end
  end

  describe "a task that released its slot" do
    test "re-acquires a free one", %{a: a, b: b} do
      workers = [author(a, :failed), author(b, :running)]
      assert {:ok, :acquired} = ResumeSlot.admit(a, workers: workers, cap: 2)
    end

    test "a human resume at a full cap is refused, naming the cap and the holders", %{
      a: a,
      b: b
    } do
      workers = [author(a, :failed), author(b, :running)]

      assert {:error, {:slot_cap_full, info}} =
               ResumeSlot.admit(a, origin: :human, workers: workers, cap: 1)

      assert info.cap == 1
      assert info.holders == [b.id]
      assert info.task_id == a.id

      message = ResumeSlot.refusal_message(info)
      assert message =~ "1"
      assert message =~ b.id
      assert message =~ a.id
      assert message =~ "force"
    end

    test "the default origin is human — refuse, never bypass", %{a: a, b: b} do
      workers = [author(a, :failed), author(b, :running)]
      assert {:error, {:slot_cap_full, _}} = ResumeSlot.admit(a, workers: workers, cap: 1)
    end

    test "an automatic resume at a full cap is deferred", %{a: a, b: b} do
      workers = [author(a, :completed), author(b, :running)]

      assert {:defer, %{cap: 1, holders: [holder]}} =
               ResumeSlot.admit(a, origin: :automatic, workers: workers, cap: 1)

      assert holder == b.id
    end

    test "a stopped task (no worker, run not cut off by a restart) released it", %{a: a, b: b} do
      run!(a, %{status: :failed, failure_reason: ":review_gate_rejected"})

      assert {:error, {:slot_cap_full, _}} =
               ResumeSlot.admit(a, workers: [author(b, :running)], cap: 1)
    end

    test "force overrides the cap and records the override", %{ws: ws, a: a, b: b} do
      workers = [author(a, :failed), author(b, :running)]

      assert {:ok, :forced} =
               ResumeSlot.admit(a,
                 origin: :human,
                 force: true,
                 actor: "coordinator",
                 workers: workers,
                 cap: 1
               )

      [event] =
        Record
        |> Ash.Query.filter(workspace_id == ^ws.id and topic == "slot_cap_override")
        |> Ash.read!()

      assert event.payload["task_id"] == a.id
      assert event.payload["cap"] == 1
      assert event.payload["holders"] == [b.id]
      assert event.payload["actor"] == "coordinator"
    end

    test "force with a free slot is a plain admission, not an override", %{ws: ws, a: a} do
      assert {:ok, :acquired} = ResumeSlot.admit(a, force: true, workers: [], cap: 1)

      assert [] =
               Record
               |> Ash.Query.filter(workspace_id == ^ws.id and topic == "slot_cap_override")
               |> Ash.read!()
    end

    test "a resume the scheduler already admitted is not re-checked", %{a: a, b: b} do
      workers = [author(a, :failed), author(b, :running)]

      assert {:ok, :admitted} =
               ResumeSlot.admit(a,
                 origin: :automatic,
                 slot_admitted: true,
                 workers: workers,
                 cap: 1
               )
    end
  end

  describe "reading the world" do
    setup do
      prior = Application.get_env(:arbiter, :conductor_system_max_concurrent)
      Application.put_env(:arbiter, :conductor_system_max_concurrent, 1)

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :conductor_system_max_concurrent, prior),
          else: Application.delete_env(:arbiter, :conductor_system_max_concurrent)
      end)
    end

    test "reads live workers and the configured cap when not handed them", %{ws: ws, a: a, b: b} do
      {:ok, pid_a} = Arbiter.Worker.start(task_id: a.id, repo: "test/repo", workspace_id: ws.id)
      {:ok, pid_b} = Arbiter.Worker.start(task_id: b.id, repo: "test/repo", workspace_id: ws.id)

      on_exit(fn ->
        for {id, pid} <- [{a.id, pid_a}, {b.id, pid_b}],
            Process.alive?(pid),
            do: Arbiter.Worker.stop(id, :normal)
      end)

      :ok = Arbiter.Worker.advance(pid_b, :implement)
      :ok = Arbiter.Worker.advance(pid_a, :implement)
      :ok = Arbiter.Worker.fail(pid_a, :token_exhausted)

      assert {:error, {:slot_cap_full, %{cap: 1, holders: holders}}} = ResumeSlot.admit(a)
      assert b.id in holders
    end
  end
end
