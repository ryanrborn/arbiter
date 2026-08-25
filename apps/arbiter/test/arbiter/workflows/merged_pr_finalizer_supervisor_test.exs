defmodule Arbiter.Workflows.MergedPRFinalizerSupervisorTest do
  # async: false — the MergedPRFinalizerSupervisor and its Registry are singletons.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.{MergedPRFinalizer, MergedPRFinalizerSupervisor}

  @registry Arbiter.Workflows.MergedPRFinalizerRegistry

  defp start(workspace, opts \\ []) do
    opts = Keyword.put_new(opts, :interval_ms, 600_000)
    result = MergedPRFinalizerSupervisor.start_finalizer(workspace, opts)

    on_exit(fn ->
      for {pid, _} <- Registry.select(@registry, [{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}]),
          is_pid(pid),
          Process.alive?(pid) do
        DynamicSupervisor.terminate_child(MergedPRFinalizerSupervisor, pid)
      end
    end)

    result
  end

  defp git_repo_with_origin(remote_url) do
    dir = Path.join(System.tmp_dir!(), "finalizer-repo-#{System.unique_integer([:positive])}")
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

  describe "start_finalizer/2 — github (regression)" do
    test "starts exactly one finalizer registered under the workspace id" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-gh-#{System.unique_integer([:positive])}",
          prefix: "mfg#{System.unique_integer([:positive])}",
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
      assert MergedPRFinalizerSupervisor.whereis(ws.id) == pid
      assert MergedPRFinalizer.state(pid).repo == "octo/widget"
    end
  end

  describe "start_finalizer/2 — gitlab single-project workspace" do
    test "starts exactly one finalizer registered under the workspace id" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-gl-single-#{System.unique_integer([:positive])}",
          prefix: "mfgs#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "gitlab",
              "config" => %{
                "host" => "gitlab.com",
                "project_id" => 12345,
                "credentials_ref" => "env:GITLAB_TOKEN"
              }
            }
          }
        })

      assert {:ok, pid} = start(ws)
      assert is_pid(pid) and Process.alive?(pid)

      assert MergedPRFinalizerSupervisor.whereis(ws.id) == pid
      assert keys_for_workspace(ws.id) == [ws.id]
      assert MergedPRFinalizer.state(pid).repo == "12345"
    end
  end

  describe "start_finalizer/2 — gitlab multi-repo workspace (emricare/vstim shape)" do
    test "starts one finalizer per repo, derived from repo_paths origin remotes" do
      repo_a = git_repo_with_origin("git@gitlab.com:emricare/tonic.git")
      repo_b = git_repo_with_origin("git@gitlab.com:emricare/tonic_device.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-gl-multi-#{System.unique_integer([:positive])}",
          prefix: "mfgm#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "gitlab",
              "config" => %{
                "host" => "gitlab.com",
                "credentials_ref" => "env:GITLAB_TOKEN"
              }
            },
            "repo_paths" => %{"tonic" => repo_a, "tonic_device" => repo_b}
          }
        })

      assert {:ok, _pid} = start(ws)

      assert keys_for_workspace(ws.id) ==
               Enum.sort([
                 "#{ws.id}:emricare/tonic",
                 "#{ws.id}:emricare/tonic_device"
               ])
    end
  end

  describe "start_finalizer/2 — skips" do
    test "skips a workspace with no merge config (direct strategy)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-direct-#{System.unique_integer([:positive])}",
          prefix: "mfd#{System.unique_integer([:positive])}"
        })

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end

    test "skips a gitlab workspace from which no repo can be derived" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "mf-gl-norepo-#{System.unique_integer([:positive])}",
          prefix: "mfgn#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "gitlab",
              "config" => %{"host" => "gitlab.com", "credentials_ref" => "env:GITLAB_TOKEN"}
            }
          }
        })

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end
  end
end
