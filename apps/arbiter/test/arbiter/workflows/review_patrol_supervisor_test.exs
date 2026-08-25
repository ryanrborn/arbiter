defmodule Arbiter.Workflows.ReviewPatrolSupervisorTest do
  # async: false — the ReviewPatrolSupervisor and its Registry are singletons.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.{ReviewPatrol, ReviewPatrolSupervisor}

  @registry Arbiter.Workflows.ReviewPatrolRegistry

  # Seed an open review engagement (the lazy-start watched item, bd-7tr11p) for a
  # repo: a review_only task with a source_pr. `source_pr` encodes the repo —
  # qualified "owner/repo#N" for multi-repo, bare "#N" in a single-repo workspace.
  defp open_engagement!(ws, source_pr) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "eng-#{System.unique_integer([:positive])}",
        tracker_type: :none,
        source_pr: to_string(source_pr),
        review_only: true,
        workspace_id: ws.id
      })

    task
  end

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
    dir = Path.join(System.tmp_dir!(), "reviewpatrol-repo-#{System.unique_integer([:positive])}")
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

      open_engagement!(ws, "#1")

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

      open_engagement!(ws, "#1")

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

      open_engagement!(ws, "#1")

      assert {:ok, pid} = start(ws)

      # Present in ReviewPatrol's registry…
      assert ReviewPatrolSupervisor.whereis(ws.id) == pid
      # …absent from PRPatrol's registry (the two are disjoint namespaces).
      assert Registry.lookup(Arbiter.Workflows.PRPatrolRegistry, ws.id) == []
    end
  end

  describe "start_patrol/2 — multi-repo workspace (leotech shape)" do
    test "starts one patrol per repo, keyed by workspace_id:owner/repo" do
      repo_a = git_repo_with_origin("git@github.com:leo-technologies-llc/verus_server.git")
      repo_b = git_repo_with_origin("https://github.com/leo-technologies-llc/verus_web.git")

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
            "repo_paths" => %{"verus_server" => repo_a, "verus_web" => repo_b}
          }
        })

      open_engagement!(ws, "leo-technologies-llc/verus_server#1")
      open_engagement!(ws, "leo-technologies-llc/verus_web#1")

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

  describe "start_patrol/2 — gitlab single-project workspace" do
    test "starts exactly one patrol registered under the workspace id" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-gl-single-#{System.unique_integer([:positive])}",
          prefix: "rgs#{System.unique_integer([:positive])}",
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

      open_engagement!(ws, "!1")

      assert {:ok, pid} = start(ws)
      assert is_pid(pid) and Process.alive?(pid)

      assert ReviewPatrolSupervisor.whereis(ws.id) == pid
      assert keys_for_workspace(ws.id) == [ws.id]
      assert ReviewPatrol.state(pid).repo == "12345"
    end
  end

  describe "start_patrol/2 — gitlab multi-repo workspace (emricare/vstim shape)" do
    test "starts one patrol per repo, derived from repo_paths origin remotes" do
      repo_a = git_repo_with_origin("git@gitlab.com:emricare/tonic.git")
      repo_b = git_repo_with_origin("git@gitlab.com:emricare/tonic_device.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-gl-multi-#{System.unique_integer([:positive])}",
          prefix: "rgm#{System.unique_integer([:positive])}",
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

      open_engagement!(ws, "emricare/tonic#1")
      open_engagement!(ws, "emricare/tonic_device#1")

      assert {:ok, _pid} = start(ws)

      assert keys_for_workspace(ws.id) ==
               Enum.sort([
                 "#{ws.id}:emricare/tonic",
                 "#{ws.id}:emricare/tonic_device"
               ])
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

    # bd-4brb2j: a repo whose review_automation resolves to :off has no
    # reviewer we would ever dispatch — no engagement on it can ever do
    # anything but sit there, so the patrol process itself should never start.
    test "skips a single-repo workspace whose review_automation default is :off" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-off-#{System.unique_integer([:positive])}",
          prefix: "ro#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            },
            "review_automation" => %{"default" => "off"}
          }
        })

      # Seed an engagement so the ONLY reason to skip is the :off mode, not the
      # lazy-start gate (bd-7tr11p).
      open_engagement!(ws, "#1")

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end

    # Same, but the :off comes from a repo_overrides entry keyed by the bare
    # repo name (merge.config.repo IS the repo name for a single-repo workspace)
    # rather than the workspace-wide default.
    test "skips a single-repo workspace whose repo_overrides entry is :off" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-offover-#{System.unique_integer([:positive])}",
          prefix: "rv#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            },
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{"widget" => "off"}
            }
          }
        })

      open_engagement!(ws, "#1")

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end

    # A repo_overrides entry takes precedence over the workspace-wide default
    # even when the override is a non-off mode and the default is :off — the
    # operator explicitly opted this repo in, and default-off must not veto it.
    test "starts a patrol when the default is :off but the repo_overrides entry is :auto" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-offdefault-override-#{System.unique_integer([:positive])}",
          prefix: "rd#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            },
            "review_automation" => %{
              "default" => "off",
              "repo_overrides" => %{"widget" => "auto"}
            }
          }
        })

      open_engagement!(ws, "#1")

      assert {:ok, pid} = start(ws)
      assert Process.alive?(pid)
    end

    # A running patrol for a repo that gets flipped to :off must be stopped on
    # the next start_patrol/2 call (mirrors the stale-registration reconciler),
    # not left running until the next full app restart.
    test "stops an already-running patrol once its repo is flipped to :off" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-offlive-#{System.unique_integer([:positive])}",
          prefix: "rl#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      open_engagement!(ws, "#1")

      assert {:ok, pid} = start(ws)
      assert Process.alive?(pid)

      {:ok, flipped} =
        Ash.update(ws, %{patch: %{"review_automation" => %{"default" => "off"}}},
          action: :patch_config
        )

      assert :skip = start(flipped)
      refute Process.alive?(pid)

      # DynamicSupervisor.terminate_child/2 waits for the child process itself
      # to exit before returning, but Registry's own removal of the :via entry
      # runs via a separate monitor reacting to that exit — under heavy
      # concurrent test load it can lag the terminate_child call by a beat, so
      # poll briefly rather than asserting immediately.
      assert Enum.any?(1..20, fn _ ->
               keys_for_workspace(ws.id) == [] or (Process.sleep(10) && false)
             end),
             "expected patrol #{ws.id} to be unregistered, got #{inspect(keys_for_workspace(ws.id))}"
    end

    # Only the OFF-configured repo is skipped in a multi-repo workspace — the
    # others still get their patrol.
    test "in a multi-repo workspace, only the :off repo is skipped" do
      alpha = git_repo_with_origin("git@github.com:octo/alpha.git")
      beta = git_repo_with_origin("git@github.com:octo/beta.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-offmulti-#{System.unique_integer([:positive])}",
          prefix: "rm#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "octo"}},
            "repo_paths" => %{"alpha" => alpha, "beta" => beta},
            "review_automation" => %{
              "default" => "auto",
              "repo_overrides" => %{"alpha" => "off"}
            }
          }
        })

      # Both repos have an engagement; alpha is skipped only because it is :off.
      open_engagement!(ws, "octo/alpha#1")
      open_engagement!(ws, "octo/beta#1")

      # start_patrol/2 returns the first per-repo result (alpha's, which is
      # :skip since it sorts before beta) — beta still gets its own patrol.
      start(ws)

      keys = keys_for_workspace(ws.id)
      assert keys == ["#{ws.id}:octo/beta"]
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

      open_engagement!(ws, "#1")

      assert {:ok, pid} = start(ws)
      assert ReviewPatrolSupervisor.whereis_all(ws.id) == [{ws.id, pid}]
    end
  end

  describe "start_patrol/2 — stale registration reconciliation" do
    test "N→1: stops the old composite-keyed patrols when repo count drops to one" do
      repo_a = git_repo_with_origin("git@github.com:acme/alpha.git")
      repo_b = git_repo_with_origin("https://github.com/acme/beta.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-recon-n1-#{System.unique_integer([:positive])}",
          prefix: "rp#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "acme"}},
            "repo_paths" => %{"alpha" => repo_a, "beta" => repo_b}
          }
        })

      open_engagement!(ws, "acme/alpha#1")
      open_engagement!(ws, "acme/beta#1")

      assert {:ok, _} = start(ws)
      assert length(keys_for_workspace(ws.id)) == 2

      single_repo_ws = %{ws | config: Map.put(ws.config, "repo_paths", %{"alpha" => repo_a})}

      assert {:ok, _} = ReviewPatrolSupervisor.start_patrol(single_repo_ws, interval_ms: 600_000)
      assert keys_for_workspace(ws.id) == [ws.id]
    end

    test "1→N: stops the old bare-keyed patrol when repo count grows to more than one" do
      repo_a = git_repo_with_origin("git@github.com:acme/alpha.git")
      repo_b = git_repo_with_origin("https://github.com/acme/beta.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-recon-1n-#{System.unique_integer([:positive])}",
          prefix: "ro#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "acme"}},
            "repo_paths" => %{"alpha" => repo_a}
          }
        })

      open_engagement!(ws, "acme/alpha#1")
      open_engagement!(ws, "acme/beta#1")

      assert {:ok, _} = start(ws)
      assert keys_for_workspace(ws.id) == [ws.id]

      two_repo_ws = %{
        ws
        | config: Map.put(ws.config, "repo_paths", %{"alpha" => repo_a, "beta" => repo_b})
      }

      assert {:ok, _} = ReviewPatrolSupervisor.start_patrol(two_repo_ws, interval_ms: 600_000)

      assert keys_for_workspace(ws.id) ==
               Enum.sort(["#{ws.id}:acme/alpha", "#{ws.id}:acme/beta"])
    end
  end

  describe "start_patrol/2 — lazy-start gate (bd-7tr11p)" do
    test "skips a single-repo workspace with no open engagement" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-lazy-none-#{System.unique_integer([:positive])}",
          prefix: "ln#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      assert :skip = start(ws)
      assert keys_for_workspace(ws.id) == []
    end

    test "starts a single-repo workspace once an engagement is open" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-lazy-one-#{System.unique_integer([:positive])}",
          prefix: "lo#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      open_engagement!(ws, "#1")

      assert {:ok, pid} = start(ws)
      assert ReviewPatrolSupervisor.whereis(ws.id) == pid
    end

    test "in a multi-repo workspace starts only the repo(s) with an open engagement" do
      repo_a = git_repo_with_origin("git@github.com:leo-technologies-llc/verus_server.git")
      repo_b = git_repo_with_origin("https://github.com/leo-technologies-llc/verus_web.git")

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-lazy-multi-#{System.unique_integer([:positive])}",
          prefix: "lm#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{"strategy" => "github", "config" => %{"owner" => "leo-technologies-llc"}},
            "repo_paths" => %{"verus_server" => repo_a, "verus_web" => repo_b}
          }
        })

      # Only verus_server has an engagement (qualified source_pr names its repo).
      open_engagement!(ws, "leo-technologies-llc/verus_server#1")

      assert {:ok, _} = start(ws)
      assert keys_for_workspace(ws.id) == ["#{ws.id}:leo-technologies-llc/verus_server"]
    end
  end

  describe "start_for_existing_workspaces/0 — boot path (bd-7tr11p)" do
    test "a work-free workspace produces no patrol sweep at boot" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-boot-none-#{System.unique_integer([:positive])}",
          prefix: "bn#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      assert :ok = ReviewPatrolSupervisor.start_for_existing_workspaces()
      assert keys_for_workspace(ws.id) == []
    end

    test "a workspace with an open engagement starts its patrol at boot" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-boot-work-#{System.unique_integer([:positive])}",
          prefix: "bw#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      open_engagement!(ws, "#1")

      assert :ok = ReviewPatrolSupervisor.start_for_existing_workspaces()

      on_exit(fn ->
        for {_k, pid} <- ReviewPatrolSupervisor.whereis_all(ws.id),
            is_pid(pid),
            Process.alive?(pid),
            do: DynamicSupervisor.terminate_child(ReviewPatrolSupervisor, pid)
      end)

      assert [ws.id] == keys_for_workspace(ws.id)
    end
  end

  describe "recheck_all/1 (bd-7tr11p)" do
    test "reaps a patrol whose last engagement has closed" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rp-recheck-#{System.unique_integer([:positive])}",
          prefix: "rc#{System.unique_integer([:positive])}",
          config: %{
            "merge" => %{
              "strategy" => "github",
              "config" => %{"owner" => "octo", "repo" => "widget"}
            }
          }
        })

      eng = open_engagement!(ws, "#1")
      assert {:ok, pid} = start(ws)
      mref = Process.monitor(pid)

      {:ok, _} = Ash.update(eng, %{}, action: :close)
      ReviewPatrolSupervisor.recheck_all(ws.id)

      assert_receive {:DOWN, ^mref, :process, ^pid, :normal}, 2_000

      # Registry removes the :via entry via a monitor reacting to the exit, which
      # can lag the DOWN by a beat — poll briefly (mirrors the :off-flip test).
      assert Enum.any?(1..20, fn _ ->
               keys_for_workspace(ws.id) == [] or (Process.sleep(10) && false)
             end)
    end
  end
end
