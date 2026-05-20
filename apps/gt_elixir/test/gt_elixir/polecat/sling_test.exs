defmodule GtElixir.Polecat.SlingTest do
  use GtElixir.DataCase, async: false

  alias GtElixir.Beads.{Issue, Workspace}
  alias GtElixir.Polecat
  alias GtElixir.Polecat.Sling

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "sling-test-ws", prefix: "st"})
    {:ok, ws: ws}
  end

  describe "sling/2 happy path" do
    test "spawns a polecat and starts a workflow machine", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "hello world", workspace_id: ws.id})

      assert {:ok, result} = Sling.sling(bead.id, rig: "test/rig", start_driver: false)
      assert result.bead.status == :in_progress
      assert is_pid(result.polecat_pid)
      assert is_pid(result.machine_pid)
      assert is_binary(result.machine_id)
      assert result.driver_pid == nil

      # polecat is registered
      assert Polecat.whereis(bead.id) == result.polecat_pid
    end

    test "idempotent for already-in_progress beads", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      {:ok, _first} = Sling.sling(bead.id, rig: "r", start_driver: false)

      # Second sling: bead is already :in_progress; polecat already exists.
      # Should NOT crash; should return the existing polecat pid.
      assert {:ok, second} = Sling.sling(bead.id, rig: "r", start_driver: false)
      assert second.bead.status == :in_progress
      assert Polecat.whereis(bead.id) == second.polecat_pid
    end

    test "starts a Driver by default and drives bead to :closed", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "drive me", workspace_id: ws.id})

      assert {:ok, result} = Sling.sling(bead.id, rig: "test/rig", interval_ms: 5)
      assert is_pid(result.driver_pid)
      assert Process.alive?(result.driver_pid)

      # Wait for the driver to walk Workflows.Work to completion. The work
      # workflow has 5 no-op steps; at 5ms intervals it should finish well
      # under 500ms.
      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end

  describe "sling/2 error cases" do
    test "non-existent bead returns {:error, {:bead_not_found, _}}" do
      assert {:error, {:bead_not_found, "no-such-bead-123"}} =
               Sling.sling("no-such-bead-123")
    end

    test "closed beads cannot be slung", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      {:ok, _closed} = Ash.update(bead, %{}, action: :close)

      assert {:error, {:bead_closed, _}} = Sling.sling(bead.id)
    end
  end

  describe "sling/2 result shape" do
    test "returns a map with the standard keys", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "shape", workspace_id: ws.id})
      {:ok, result} = Sling.sling(bead.id, rig: "test/rig", start_driver: false)

      for key <- [:bead, :polecat_pid, :machine_id, :machine_pid, :driver_pid, :worktree_path] do
        assert Map.has_key?(result, key), "missing #{key}"
      end
    end
  end

  describe "worktree provisioning" do
    @env_key :rig_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "sling-wt-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:gt_elixir, :worktree_root)
      prior_rig_paths = Application.get_env(:gt_elixir, @env_key)

      Application.put_env(:gt_elixir, :worktree_root, worktree_root)
      Application.put_env(:gt_elixir, @env_key, %{"st/rig" => repo})

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:gt_elixir, :worktree_root, prior_wt_root),
          else: Application.delete_env(:gt_elixir, :worktree_root)

        if prior_rig_paths,
          do: Application.put_env(:gt_elixir, @env_key, prior_rig_paths),
          else: Application.delete_env(:gt_elixir, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo, worktree_root: worktree_root}
    end

    test "creates a worktree on a derived branch when rig is configured",
         %{ws: ws, worktree_root: root} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "implement the thing",
          workspace_id: ws.id,
          issue_type: :feature
        })

      {:ok, result} =
        Sling.sling(bead.id, rig: "st/rig", start_driver: false)

      assert is_binary(result.worktree_path)
      assert String.starts_with?(result.worktree_path, root)
      assert File.dir?(result.worktree_path)

      # Branch matches BranchNamer's derivation.
      branch = GtElixir.Polecat.BranchNamer.derive(bead)
      assert {:ok, ^branch} = GtElixir.Polecat.Worktree.current_branch(result.worktree_path)
    end

    test "skips worktree when rig is not in rig_paths", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "unmapped", workspace_id: ws.id})

      {:ok, result} = Sling.sling(bead.id, rig: "no-such-rig", start_driver: false)
      assert result.worktree_path == nil
    end

    test "skips worktree when provision_worktree: false", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "opt-out", workspace_id: ws.id})

      {:ok, result} =
        Sling.sling(bead.id, rig: "st/rig", start_driver: false, provision_worktree: false)

      assert result.worktree_path == nil
    end
  end
end
