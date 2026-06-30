defmodule Arbiter.Workflows.PRPatrolSupervisorTest do
  # async: false — the PRPatrolSupervisor and its Registry are singletons.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.{PRPatrol, PRPatrolSupervisor}

  @registry Arbiter.Workflows.PRPatrolRegistry

  # PRPatrol's first tick is scheduled interval_ms out; with a long interval the
  # GenServer never touches GitHub or the DB during the test, so we only assert
  # on registration/derivation — the behaviour this module owns.
  defp start(workspace, opts \\ []) do
    opts = Keyword.put_new(opts, :interval_ms, 600_000)
    result = PRPatrolSupervisor.start_patrol(workspace, opts)

    on_exit(fn ->
      for {pid, _} <- Registry.select(@registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]),
          is_pid(pid),
          Process.alive?(pid) do
        DynamicSupervisor.terminate_child(PRPatrolSupervisor, pid)
      end
    end)

    result
  end

  # A bare git checkout with an `origin` remote, so RepoResolver.from_remote/1
  # (which shells out to `git -C <path> remote get-url origin`) resolves a slug.
  defp git_repo_with_origin(remote_url) do
    dir = Path.join(System.tmp_dir!(), "prpatrol-rig-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["-C", dir, "init", "-q"], stderr_to_stdout: true)

    {_, 0} =
      System.cmd("git", ["-C", dir, "remote", "add", "origin", remote_url],
        stderr_to_stdout: true
      )

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp keys_for_workspace(ws_id) do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(fn
      ^ws_id -> true
      key when is_binary(key) -> String.starts_with?(key, ws_id <> ":")
      _ -> false
    end)
    |> Enum.sort()
  end

  describe "start_patrol/2 — single-repo workspace" do
    test "starts exactly one patrol registered under the workspace id" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "single-#{System.unique_integer([:positive])}",
          prefix: "sg#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "octo",
                "repo" => "widget",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            }
          }
        })

      assert {:ok, pid} = start(ws)
      assert is_pid(pid) and Process.alive?(pid)

      # Registered under the bare workspace id (not the ws:owner/repo form).
      assert PRPatrolSupervisor.whereis(ws.id) == pid
      assert keys_for_workspace(ws.id) == [ws.id]

      # The patrol carries the resolved owner/repo slug.
      assert PRPatrol.state(pid).repo == "octo/widget"
    end

    test "duplicate start collapses to {:error, {:already_started, pid}}" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "dup-#{System.unique_integer([:positive])}",
          prefix: "dp#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      assert {:ok, pid} = start(ws)

      assert {:error, {:already_started, ^pid}} =
               PRPatrolSupervisor.start_patrol(ws, interval_ms: 600_000)
    end
  end

  describe "start_patrol/2 — multi-repo workspace (leotech shape)" do
    test "starts one patrol per rig, keyed by workspace_id:owner/repo" do
      # owner is set but repo is absent — the per-rig repo is derived from each
      # rig checkout's origin remote, exactly the leotech jira+github shape.
      rig_a = git_repo_with_origin("git@github.com:leo-technologies-llc/verus_server.git")
      rig_b = git_repo_with_origin("https://github.com/leo-technologies-llc/verus_web.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "multi-#{System.unique_integer([:positive])}",
          prefix: "ml#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{
                "owner" => "leo-technologies-llc",
                "credentials_ref" => "env:GITHUB_TOKEN"
              }
            },
            "repo_paths" => %{"verus_server" => rig_a, "verus_web" => rig_b}
          }
        })

      assert {:ok, _pid} = start(ws)

      assert keys_for_workspace(ws.id) ==
               Enum.sort([
                 "#{ws.id}:leo-technologies-llc/verus_server",
                 "#{ws.id}:leo-technologies-llc/verus_web"
               ])

      # Each patrol carries its own derived slug.
      [{pid_a, _}] = Registry.lookup(@registry, "#{ws.id}:leo-technologies-llc/verus_server")
      [{pid_b, _}] = Registry.lookup(@registry, "#{ws.id}:leo-technologies-llc/verus_web")
      assert PRPatrol.state(pid_a).repo == "leo-technologies-llc/verus_server"
      assert PRPatrol.state(pid_b).repo == "leo-technologies-llc/verus_web"
    end

    test "rigs that resolve to the same repo collapse to a single patrol" do
      rig_a = git_repo_with_origin("git@github.com:leo-technologies-llc/verus_server.git")
      rig_b = git_repo_with_origin("https://github.com/leo-technologies-llc/verus_server.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "dedupe-#{System.unique_integer([:positive])}",
          prefix: "dd#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "leo-technologies-llc"}},
            "repo_paths" => %{"a" => rig_a, "b" => rig_b}
          }
        })

      assert {:ok, pid} = start(ws)

      # Collapsed to one repo → registered under the bare workspace id, exactly
      # like a single-repo workspace (the `length(repos) == 1` registry key).
      assert keys_for_workspace(ws.id) == [ws.id]
      assert PRPatrol.state(pid).repo == "leo-technologies-llc/verus_server"
    end
  end

  describe "start_patrol/2 — skips" do
    test "skips a workspace with no github merge config (direct strategy)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "direct-#{System.unique_integer([:positive])}",
          prefix: "dr#{System.unique_integer([:positive])}"
        })

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end

    test "skips a github workspace from which no repo can be derived" do
      # github strategy, owner only, and no repo_paths → nothing to patrol.
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "norepo-#{System.unique_integer([:positive])}",
          prefix: "nr#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "octo"}}
          }
        })

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end
  end

  describe "whereis/1" do
    test "returns nil for an unknown workspace" do
      assert PRPatrolSupervisor.whereis("ws-nope-#{System.unique_integer([:positive])}") == nil
    end
  end

  describe "whereis_all/1" do
    test "returns empty list for an unknown workspace" do
      assert PRPatrolSupervisor.whereis_all("ws-nope-#{System.unique_integer([:positive])}") == []
    end

    test "returns the pid for a single-repo workspace" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "wa-single-#{System.unique_integer([:positive])}",
          prefix: "wa#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      assert {:ok, pid} = start(ws)
      assert PRPatrolSupervisor.whereis_all(ws.id) == [{ws.id, pid}]
    end

    test "returns all pids for a multi-repo workspace" do
      rig_a = git_repo_with_origin("git@github.com:leo-technologies-llc/verus_server.git")
      rig_b = git_repo_with_origin("https://github.com/leo-technologies-llc/verus_web.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "wa-multi-#{System.unique_integer([:positive])}",
          prefix: "wm#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "leo-technologies-llc"}
            },
            "repo_paths" => %{"verus_server" => rig_a, "verus_web" => rig_b}
          }
        })

      assert {:ok, _} = start(ws)
      pairs = PRPatrolSupervisor.whereis_all(ws.id)
      assert length(pairs) == 2
      keys = Enum.map(pairs, fn {k, _} -> k end) |> Enum.sort()

      assert keys ==
               Enum.sort([
                 "#{ws.id}:leo-technologies-llc/verus_server",
                 "#{ws.id}:leo-technologies-llc/verus_web"
               ])
    end
  end

  describe "start_patrol/2 — stale registration reconciliation" do
    test "N→1: stops the old composite-keyed patrols when repo count drops to one" do
      rig_a = git_repo_with_origin("git@github.com:acme/alpha.git")
      rig_b = git_repo_with_origin("https://github.com/acme/beta.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "recon-n1-#{System.unique_integer([:positive])}",
          prefix: "rn#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "acme"}},
            "repo_paths" => %{"alpha" => rig_a, "beta" => rig_b}
          }
        })

      # Start with two repos — registered under composite keys
      assert {:ok, _} = start(ws)
      assert length(keys_for_workspace(ws.id)) == 2

      # Simulate dropping to one rig (rebuild workspace with single repo_paths entry)
      single_repo_ws = %{ws | config: Map.put(ws.config, "repo_paths", %{"alpha" => rig_a})}

      assert {:ok, _} = PRPatrolSupervisor.start_patrol(single_repo_ws, interval_ms: 600_000)

      # After reconciliation, only the single bare-key patrol remains
      assert keys_for_workspace(ws.id) == [ws.id]
    end

    test "1→N: stops the old bare-keyed patrol when repo count grows to more than one" do
      rig_a = git_repo_with_origin("git@github.com:acme/alpha.git")
      rig_b = git_repo_with_origin("https://github.com/acme/beta.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "recon-1n-#{System.unique_integer([:positive])}",
          prefix: "ro#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "acme"}},
            "repo_paths" => %{"alpha" => rig_a}
          }
        })

      # Start with one repo — registered under bare key
      assert {:ok, _} = start(ws)
      assert keys_for_workspace(ws.id) == [ws.id]

      # Simulate gaining a second rig
      two_repo_ws = %{
        ws
        | config: Map.put(ws.config, "repo_paths", %{"alpha" => rig_a, "beta" => rig_b})
      }

      assert {:ok, _} = PRPatrolSupervisor.start_patrol(two_repo_ws, interval_ms: 600_000)

      # After reconciliation, bare key is gone; only composite keys remain
      assert keys_for_workspace(ws.id) ==
               Enum.sort(["#{ws.id}:acme/alpha", "#{ws.id}:acme/beta"])
    end
  end
end
