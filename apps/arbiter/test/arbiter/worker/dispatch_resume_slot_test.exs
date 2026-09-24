defmodule Arbiter.Worker.DispatchResumeSlotTest do
  @moduledoc """
  bd-92mx1m: `Dispatch.resume/2` and `Dispatch.resume_session/2` consult
  `Arbiter.Worker.ResumeSlot` before re-entering a task. Driven end to end
  against a real git repo and real workers, so the gate is proven where it
  actually sits — after the resume's own validity checks, before the prior
  worker is stopped.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Events.Record
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  require Ash.Query

  @env_key :repo_paths

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resume-slot-dispatch-#{System.unique_integer([:positive])}",
        prefix: "rsd#{System.unique_integer([:positive])}"
      })

    tmp = Path.join(System.tmp_dir!(), "resume-slot-#{:erlang.unique_integer([:positive])}")
    repo = Path.join(tmp, "source")
    File.mkdir_p!(repo)

    git = fn args -> {_, 0} = System.cmd("git", args) end
    git.(["init", "-q", "-b", "main", repo])
    git.(["-C", repo, "config", "user.email", "test@example.com"])
    git.(["-C", repo, "config", "user.name", "Test User"])
    git.(["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    git.(["-C", repo, "add", "README.md"])
    git.(["-C", repo, "commit", "-q", "-m", "initial"])

    remote = Path.join(tmp, "remote.git")
    git.(["init", "-q", "--bare", "-b", "main", remote])
    git.(["-C", repo, "remote", "add", "origin", remote])
    git.(["-C", repo, "push", "-q", "origin", "main"])

    worktree_root = Path.join(tmp, "worktrees")
    File.mkdir_p!(worktree_root)

    prior_wt_root = Application.get_env(:arbiter, :worktree_root)
    prior_repo_paths = Application.get_env(:arbiter, @env_key)
    prior_cap = Application.get_env(:arbiter, :conductor_system_max_concurrent)

    Application.put_env(:arbiter, :worktree_root, worktree_root)
    Application.put_env(:arbiter, @env_key, %{"rs/repo" => repo})
    # The 2026-09-23 incident's cap.
    Application.put_env(:arbiter, :conductor_system_max_concurrent, 1)

    on_exit(fn ->
      restore(:worktree_root, prior_wt_root)
      restore(@env_key, prior_repo_paths)
      restore(:conductor_system_max_concurrent, prior_cap)
      File.rm_rf!(tmp)
    end)

    {:ok, a} = Ash.create(Issue, %{title: "task A (parked)", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "task B (admitted)", workspace_id: ws.id})

    %{ws: ws, a: a, b: b}
  end

  defp restore(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore(key, value), do: Application.put_env(:arbiter, key, value)

  # Task A ran, then parked for a human: its worker lingers :failed, which
  # releases its slot (bd-45pwo1).
  defp park_a(a, fail_opts \\ []) do
    {:ok, first} = Dispatch.dispatch(a.id, repo: "rs/repo", start_driver: false)
    :ok = Worker.fail(first.worker_pid, :review_gate_rejected, fail_opts)
    on_exit(fn -> stop_quietly(a.id) end)
    first
  end

  # Task B was admitted into the slot A freed.
  defp admit_b(ws, b) do
    {:ok, pid} = Worker.start(task_id: b.id, repo: "rs/repo", workspace_id: ws.id)
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> stop_quietly(b.id) end)
    pid
  end

  defp stop_quietly(task_id) do
    if Worker.whereis(task_id), do: Worker.stop(task_id, :normal)
  catch
    :exit, _ -> :ok
  end

  defp overrides(ws) do
    Record
    |> Ash.Query.filter(workspace_id == ^ws.id and topic == "slot_cap_override")
    |> Ash.read!()
  end

  describe "the 2026-09-23 incident (cap 1, A parked, B admitted)" do
    test "a human resume of A is refused, naming the cap and B; the parked worker is untouched",
         %{ws: ws, a: a, b: b} do
      first = park_a(a)
      admit_b(ws, b)

      assert {:error, {:slot_cap_full, info}} =
               Dispatch.resume(a.id, start_driver: false, claude_command: ["true"])

      assert info.cap == 1
      assert info.holders == [b.id]
      # Refused before `stop_prior_worker/1`: nothing about A changed.
      assert Worker.whereis(a.id) == first.worker_pid
      assert Worker.state(first.worker_pid).status == :failed
      assert overrides(ws) == []
    end

    test "with force it is admitted, over the cap, and the override is recorded",
         %{ws: ws, a: a, b: b} do
      first = park_a(a)
      admit_b(ws, b)

      assert {:ok, result} =
               Dispatch.resume(a.id,
                 start_driver: false,
                 claude_command: ["sleep", "2"],
                 force_slot: true,
                 slot_override_actor: "coordinator"
               )

      assert result.worker_pid != first.worker_pid
      assert Worker.state(result.worker_pid).meta[:slot_cap_override] == true

      assert [event] = overrides(ws)
      assert event.payload["task_id"] == a.id
      assert event.payload["holders"] == [b.id]
      assert event.payload["actor"] == "coordinator"
    end
  end

  describe "an automatic resume of a task that released its slot" do
    test "is deferred to the scheduler at a full cap — not failed, not bypassed",
         %{ws: ws, a: a, b: b} do
      first = park_a(a)
      admit_b(ws, b)
      me = self()

      defer = fn task_id, kind, opts ->
        send(me, {:deferred, task_id, kind, opts})
        :ok
      end

      assert {:ok, %{deferred: true, task_id: task_id, cap: 1, holders: holders}} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 defer_resume: defer,
                 revise_feedback: "address the review",
                 start_driver: false
               )

      assert task_id == a.id
      assert holders == [b.id]
      assert_received {:deferred, ^task_id, :resume, opts}
      # The resume is replayed with the caller's own options, minus the seam.
      assert opts[:revise_feedback] == "address the review"
      assert opts[:resume_origin] == :automatic
      refute Keyword.has_key?(opts, :defer_resume)

      # Nothing was started or stopped.
      assert Worker.whereis(a.id) == first.worker_pid
    end

    test "a deferral nobody can take is a refusal, never a bypass", %{ws: ws, a: a, b: b} do
      park_a(a)
      admit_b(ws, b)

      assert {:error, {:slot_cap_full, _}} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 defer_resume: fn _, _, _ -> {:error, :no_scheduler} end,
                 start_driver: false
               )
    end
  end

  describe "a resume of a task that still holds its slot" do
    # Acceptance 1: the fix-round shape. The ReviewGate fails the author only
    # so the implementer round can replace it (`slot_handoff`), and the round
    # spawns even though B has filled the cap — #1969/#1995's no-deadlock rule.
    test "a ReviewGate fix round spawns at a full cap", %{ws: ws, a: a, b: b} do
      first = park_a(a, slot_handoff: true)
      admit_b(ws, b)

      assert {:ok, result} =
               Dispatch.resume(a.id,
                 resume_origin: :automatic,
                 defer_resume: fn _, _, _ -> flunk("a held slot must not defer") end,
                 review_gate_fix_round_attempts: 1,
                 start_driver: false,
                 claude_command: ["sleep", "2"]
               )

      assert result.worker_pid != first.worker_pid
      assert overrides(ws) == []
    end
  end

  describe "resume_session/2" do
    test "is gated the same way", %{ws: ws, a: a, b: b} do
      park_a(a)
      admit_b(ws, b)

      {:ok, _} =
        Ash.create(UsageEvent, %{
          task_id: a.id,
          workspace_id: ws.id,
          repo: "rs/repo",
          step: :work,
          provider: "claude",
          session_id: "sess-#{:erlang.unique_integer([:positive])}",
          occurred_at: DateTime.utc_now()
        })

      assert {:error, {:slot_cap_full, %{holders: [holder]}}} =
               Dispatch.resume_session(a.id, start_driver: false, preflight: false)

      assert holder == b.id
    end
  end
end
