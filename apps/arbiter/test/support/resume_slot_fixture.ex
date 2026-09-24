defmodule Arbiter.Test.ResumeSlotFixture do
  @moduledoc """
  The 2026-09-23 incident as a fixture (bd-92mx1m), shared by every surface
  that resumes a task: a real git repo, `conductor_system_max_concurrent = 1`,
  task A dispatched and then parked for a human (its worker lingers `:failed`,
  which releases its slot), and task B admitted into the slot A freed.

  Real enough that `Arbiter.Worker.Dispatch.resume/2` gets all the way to
  the slot gate on A — preserved worktree, known repo, prior run — so a
  surface's test proves the gate where it actually sits.

  Call `setup_incident/1` from a test's `setup` (it registers its own
  `on_exit` cleanup), with a workspace. It returns `%{a: issue, b: issue,
  first: dispatch_result}`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  @repo "rs/repo"

  @doc "The repo slug the fixture registers."
  def repo, do: @repo

  @doc """
  Build the incident in `ws`. `:park` options go to `Worker.fail/3` (e.g.
  `slot_handoff: true` for the fix-round shape).
  """
  def setup_incident(ws, opts \\ []) do
    setup_repo!()
    {:ok, a} = Ash.create(Issue, %{title: "task A (parked)", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "task B (admitted)", workspace_id: ws.id})
    first = park!(a, Keyword.get(opts, :park, []))
    admit!(ws, b)
    %{a: a, b: b, first: first}
  end

  @doc """
  A real git repo with a remote, registered as `rs/repo`, a private worktree
  root, and a cap of 1 — all restored on exit.
  """
  def setup_repo! do
    tmp = Path.join(System.tmp_dir!(), "resume-slot-#{:erlang.unique_integer([:positive])}")
    repo = Path.join(tmp, "source")
    File.mkdir_p!(repo)

    git!(["init", "-q", "-b", "main", repo])
    git!(["-C", repo, "config", "user.email", "test@example.com"])
    git!(["-C", repo, "config", "user.name", "Test User"])
    git!(["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    git!(["-C", repo, "add", "README.md"])
    git!(["-C", repo, "commit", "-q", "-m", "initial"])

    remote = Path.join(tmp, "remote.git")
    git!(["init", "-q", "--bare", "-b", "main", remote])
    git!(["-C", repo, "remote", "add", "origin", remote])
    git!(["-C", repo, "push", "-q", "origin", "main"])

    worktree_root = Path.join(tmp, "worktrees")
    File.mkdir_p!(worktree_root)

    put_env_restoring(:worktree_root, worktree_root)
    put_env_restoring(:repo_paths, %{@repo => repo})
    # The 2026-09-23 incident's cap.
    put_env_restoring(:conductor_system_max_concurrent, 1)

    on_exit(fn -> File.rm_rf!(tmp) end)
    :ok
  end

  @doc "Dispatch `task`, then fail its worker: parked for a human."
  def park!(%Issue{id: id}, fail_opts \\ []) do
    {:ok, first} = Dispatch.dispatch(id, repo: @repo, start_driver: false)
    :ok = Worker.fail(first.worker_pid, :review_gate_rejected, fail_opts)
    on_exit(fn -> stop_quietly(id) end)
    first
  end

  @doc "A running worker for `task`: it holds a slot."
  def admit!(ws, %Issue{id: id}) do
    {:ok, pid} = Worker.start(task_id: id, repo: @repo, workspace_id: ws.id)
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> stop_quietly(id) end)
    pid
  end

  @doc "The `slot_cap_override` audit events recorded in `ws`."
  def overrides(ws) do
    require Ash.Query

    Arbiter.Events.Record
    |> Ash.Query.filter(workspace_id == ^ws.id and topic == "slot_cap_override")
    |> Ash.read!()
  end

  defp stop_quietly(task_id) do
    if Worker.whereis(task_id), do: Worker.stop(task_id, :normal)
  catch
    :exit, _ -> :ok
  end

  defp git!(args) do
    {_, 0} = System.cmd("git", args)
  end

  defp put_env_restoring(key, value) do
    prior = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    on_exit(fn ->
      case prior do
        {:ok, v} -> Application.put_env(:arbiter, key, v)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)
  end
end
