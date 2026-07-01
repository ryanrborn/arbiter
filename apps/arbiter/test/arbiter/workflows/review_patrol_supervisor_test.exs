defmodule Arbiter.Workflows.ReviewPatrolSupervisorTest do
  # async: false — the ReviewPatrolSupervisor and its Registry are singletons.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.{ReviewPatrol, ReviewPatrolSupervisor}

  @registry Arbiter.Workflows.ReviewPatrolRegistry

  # A long interval means the GenServer never touches the DB/forge during the
  # test; we only assert on registration/derivation — the behaviour this module
  # owns (mirrors PRPatrolSupervisorTest).
  defp start(workspace, opts \\ []) do
    opts = Keyword.put_new(opts, :interval_ms, 600_000)
    result = ReviewPatrolSupervisor.start_patrol(workspace, opts)

    on_exit(fn ->
      for {pid, _} <- Registry.select(@registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]),
          is_pid(pid),
          Process.alive?(pid) do
        DynamicSupervisor.terminate_child(ReviewPatrolSupervisor, pid)
      end
    end)

    result
  end

  defp git_repo_with_origin(remote_url) do
    dir = Path.join(System.tmp_dir!(), "reviewpatrol-rig-#{System.unique_integer([:positive])}")
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
          name: "rp-single-#{System.unique_integer([:positive])}",
          prefix: "rs#{System.unique_integer([:positive])}",
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

      assert ReviewPatrolSupervisor.whereis(ws.id) == pid
      assert keys_for_workspace(ws.id) == [ws.id]
      assert ReviewPatrol.state(pid).repo == "octo/widget"
    end

    test "duplicate start collapses to {:error, {:already_started, pid}}" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-dup-#{System.unique_integer([:positive])}",
          prefix: "rd#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      assert {:ok, pid} = start(ws)

      assert {:error, {:already_started, ^pid}} =
               ReviewPatrolSupervisor.start_patrol(ws, interval_ms: 600_000)
    end
  end

  describe "start_patrol/2 — separate registry from PRPatrol" do
    test "a ReviewPatrol registration does not appear in the PRPatrol registry" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-sep-#{System.unique_integer([:positive])}",
          prefix: "rx#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      assert {:ok, pid} = start(ws)

      # Present in ReviewPatrol's registry…
      assert ReviewPatrolSupervisor.whereis(ws.id) == pid
      # …absent from PRPatrol's registry (the two are disjoint namespaces).
      assert Registry.lookup(Arbiter.Workflows.PRPatrolRegistry, ws.id) == []
    end
  end

  describe "start_patrol/2 — multi-repo workspace (leotech shape)" do
    test "starts one patrol per rig, keyed by workspace_id:owner/repo" do
      rig_a = git_repo_with_origin("git@github.com:leo-technologies-llc/verus_server.git")
      rig_b = git_repo_with_origin("https://github.com/leo-technologies-llc/verus_web.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-multi-#{System.unique_integer([:positive])}",
          prefix: "rm#{System.unique_integer([:positive])}",
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

      [{pid_a, _}] = Registry.lookup(@registry, "#{ws.id}:leo-technologies-llc/verus_server")
      [{pid_b, _}] = Registry.lookup(@registry, "#{ws.id}:leo-technologies-llc/verus_web")
      assert ReviewPatrol.state(pid_a).repo == "leo-technologies-llc/verus_server"
      assert ReviewPatrol.state(pid_b).repo == "leo-technologies-llc/verus_web"
    end
  end

  describe "start_patrol/2 — skips" do
    test "skips a workspace with no github merge config (direct strategy)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-direct-#{System.unique_integer([:positive])}",
          prefix: "ri#{System.unique_integer([:positive])}"
        })

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end

    test "skips a github workspace from which no repo can be derived" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-norepo-#{System.unique_integer([:positive])}",
          prefix: "rn#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "octo"}}
          }
        })

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end
  end

  describe "whereis_all/1" do
    test "returns empty list for an unknown workspace" do
      assert ReviewPatrolSupervisor.whereis_all("ws-nope-#{System.unique_integer([:positive])}") ==
               []
    end

    test "returns the pid for a single-repo workspace" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-wa-#{System.unique_integer([:positive])}",
          prefix: "rw#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      assert {:ok, pid} = start(ws)
      assert ReviewPatrolSupervisor.whereis_all(ws.id) == [{ws.id, pid}]
    end
  end

  describe "start_patrol/2 — stale registration reconciliation" do
    test "N→1: stops the old composite-keyed patrols when repo count drops to one" do
      rig_a = git_repo_with_origin("git@github.com:acme/alpha.git")
      rig_b = git_repo_with_origin("https://github.com/acme/beta.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-recon-n1-#{System.unique_integer([:positive])}",
          prefix: "rp#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "acme"}},
            "repo_paths" => %{"alpha" => rig_a, "beta" => rig_b}
          }
        })

      assert {:ok, _} = start(ws)
      assert length(keys_for_workspace(ws.id)) == 2

      single_repo_ws = %{ws | config: Map.put(ws.config, "repo_paths", %{"alpha" => rig_a})}

      assert {:ok, _} = ReviewPatrolSupervisor.start_patrol(single_repo_ws, interval_ms: 600_000)
      assert keys_for_workspace(ws.id) == [ws.id]
    end

    test "1→N: stops the old bare-keyed patrol when repo count grows to more than one" do
      rig_a = git_repo_with_origin("git@github.com:acme/alpha.git")
      rig_b = git_repo_with_origin("https://github.com/acme/beta.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-recon-1n-#{System.unique_integer([:positive])}",
          prefix: "ro#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "acme"}},
            "repo_paths" => %{"alpha" => rig_a}
          }
        })

      assert {:ok, _} = start(ws)
      assert keys_for_workspace(ws.id) == [ws.id]

      two_repo_ws = %{
        ws
        | config: Map.put(ws.config, "repo_paths", %{"alpha" => rig_a, "beta" => rig_b})
      }

      assert {:ok, _} = ReviewPatrolSupervisor.start_patrol(two_repo_ws, interval_ms: 600_000)

      assert keys_for_workspace(ws.id) ==
               Enum.sort(["#{ws.id}:acme/alpha", "#{ws.id}:acme/beta"])
    end
  end
end
