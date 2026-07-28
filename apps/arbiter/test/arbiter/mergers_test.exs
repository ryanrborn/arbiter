defmodule Arbiter.MergersTest do
  use ExUnit.Case, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Mergers

  @github_env "GTE_MERGERS_PREPARE_GITHUB_TOKEN"
  @gitlab_env "GTE_MERGERS_PREPARE_GITLAB_TOKEN"

  setup do
    System.put_env(@github_env, "test-gh-prepare-token")
    System.put_env(@gitlab_env, "test-gl-prepare-token")

    on_exit(fn ->
      Mergers.Github.Config.clear()
      Mergers.Gitlab.Config.clear()
      System.delete_env(@github_env)
      System.delete_env(@gitlab_env)
    end)

    :ok
  end

  describe "for_workspace/1" do
    test "resolves :github strategy to Github adapter" do
      ws = %Workspace{config: %{"merge" => %{"strategy" => "github"}}}
      assert Mergers.for_workspace(ws) == Mergers.Github
    end

    test "resolves :gitlab strategy to Gitlab adapter" do
      ws = %Workspace{config: %{"merge" => %{"strategy" => "gitlab"}}}
      assert Mergers.for_workspace(ws) == Mergers.Gitlab
    end

    test "falls back to Direct when strategy is unset" do
      ws = %Workspace{config: %{}}
      assert Mergers.for_workspace(ws) == Mergers.Direct
    end
  end

  describe "prepare/1" do
    test "is a no-op for a nil workspace" do
      assert Mergers.prepare(nil) == :ok
    end

    test "seeds Github.Config without owner/repo — per-repo derivation shape (bd-a53kv2)" do
      ws = %Workspace{
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "credentials_ref" => "env:#{@github_env}"
            }
          }
        }
      }

      assert Mergers.prepare(ws) == :ok

      assert {:ok, cfg} = Mergers.Github.Config.resolve()
      assert cfg.owner == nil
      assert cfg.repo == nil
      assert cfg.token == "test-gh-prepare-token"
    end

    test "seeds Github.Config from a :github-strategy workspace (bd-a1qqne regression)" do
      ws = %Workspace{
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "ryanrborn",
              "repo" => "arbiter",
              "credentials_ref" => "env:#{@github_env}",
              "default_target_branch" => "main"
            }
          }
        }
      }

      assert Mergers.prepare(ws) == :ok

      assert {:ok, cfg} = Mergers.Github.Config.resolve()
      assert cfg.owner == "ryanrborn"
      assert cfg.repo == "arbiter"
      assert cfg.token == "test-gh-prepare-token"
      assert cfg.default_target_branch == "main"
    end

    test "seeds Gitlab.Config from a :gitlab-strategy workspace" do
      ws = %Workspace{
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "config" => %{
              "host" => "gitlab.example.com",
              "project_id" => "42",
              "credentials_ref" => "env:#{@gitlab_env}"
            }
          }
        }
      }

      assert Mergers.prepare(ws) == :ok

      assert {:ok, cfg} = Mergers.Gitlab.Config.resolve()
      assert cfg.token == "test-gl-prepare-token"
    end

    test "is a no-op for a :direct-strategy workspace (no per-process config)" do
      ws = %Workspace{config: %{"merge" => %{"strategy" => "direct"}}}
      assert Mergers.prepare(ws) == :ok

      # No github/gitlab config seeded.
      assert Mergers.Github.Config.active_repo_slug() == nil
    end
  end

  describe "prepare_with_repo/2" do
    test "is a no-op for a nil workspace" do
      assert Mergers.prepare_with_repo(nil, "tonic_device") == :ok
    end

    test "falls back to prepare/1 when repo is nil" do
      ws = %Workspace{
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "config" => %{
              "host" => "gitlab.example.com",
              "project_id" => "42",
              "credentials_ref" => "env:#{@gitlab_env}"
            }
          }
        }
      }

      assert Mergers.prepare_with_repo(ws, nil) == :ok
      assert {:ok, cfg} = Mergers.Gitlab.Config.resolve()
      assert cfg.project_id == "42"
    end

    test "seeds Gitlab.Config and applies the repo's project_id override (bd-c9vb0r)" do
      ws = %Workspace{
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "config" => %{
              "host" => "gitlab.example.com",
              "project_id" => "emricare/tonic",
              "credentials_ref" => "env:#{@gitlab_env}",
              "repos" => %{
                "tonic_device" => %{"project_id" => "emricare/tonic_device"}
              }
            }
          }
        }
      }

      assert Mergers.prepare_with_repo(ws, "tonic_device") == :ok
      assert {:ok, cfg} = Mergers.Gitlab.Config.resolve()
      assert cfg.project_id == "emricare/tonic_device"

      # A repo with no override keeps the workspace default.
      assert Mergers.prepare_with_repo(ws, "tonic") == :ok
      assert {:ok, cfg} = Mergers.Gitlab.Config.resolve()
      assert cfg.project_id == "emricare/tonic"
    end

    test "seeds Github.Config and applies the repo override" do
      ws = %Workspace{
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "credentials_ref" => "env:#{@github_env}"
            }
          }
        }
      }

      assert Mergers.prepare_with_repo(ws, "acme/widgets") == :ok
      assert {:ok, cfg} = Mergers.Github.Config.resolve()
      assert cfg.owner == "acme"
      assert cfg.repo == "widgets"
    end

    test "is a no-op for a :direct-strategy workspace" do
      ws = %Workspace{config: %{"merge" => %{"strategy" => "direct"}}}
      assert Mergers.prepare_with_repo(ws, "tonic_device") == :ok
    end
  end

  # bd-28l6im: three finalize-422 false-failures (bd-8cn795, bd-7opdaf,
  # bd-2wilou) landed in one afternoon despite bd-636thc's retry — the
  # transient GitHub-listing miss window this retries around can outlast the
  # original 3-attempt/200ms budget. These prove the widened budget actually
  # waits long enough for a slow-to-clear miss, while still failing fast (no
  # retry at all) on an unrelated error.
  describe "open_with_retry/6" do
    defmodule StubAdapter do
      @moduledoc false
      def responses(responses), do: Process.put(__MODULE__, responses)

      def open(_branch, _title, _description, _opts) do
        [head | rest] = Process.get(__MODULE__)
        Process.put(__MODULE__, rest)
        head
      end
    end

    @already_exists_error %{
      status: 422,
      raw: %{
        "errors" => [%{"code" => "custom", "message" => "A pull request already exists for o:b."}]
      }
    }

    @fast_retry_opts [delay_ms: 1, max_delay_ms: 2]

    test "retries an already-exists error past the old 3-attempt budget" do
      StubAdapter.responses([
        {:error, @already_exists_error},
        {:error, @already_exists_error},
        {:error, @already_exists_error},
        {:error, @already_exists_error},
        {:ok, "#700"}
      ])

      assert Mergers.open_with_retry(StubAdapter, "b", "t", "d", %{}, @fast_retry_opts) ==
               {:ok, "#700"}
    end

    test "does not retry an unrelated error" do
      StubAdapter.responses([
        {:error, %{status: 422, raw: %{"message" => "Validation Failed"}}},
        {:ok, "#701"}
      ])

      assert Mergers.open_with_retry(StubAdapter, "b", "t", "d", %{}, @fast_retry_opts) ==
               {:error, %{status: 422, raw: %{"message" => "Validation Failed"}}}
    end

    test "gives up and returns the error once the retry budget is exhausted" do
      StubAdapter.responses(List.duplicate({:error, @already_exists_error}, 20))

      assert {:error, @already_exists_error} =
               Mergers.open_with_retry(StubAdapter, "b", "t", "d", %{}, @fast_retry_opts)
    end

    test "defaults to a 6-attempt exponential backoff budget" do
      StubAdapter.responses(List.duplicate({:error, @already_exists_error}, 20))

      {micros, {:error, @already_exists_error}} =
        :timer.tc(fn -> Mergers.open_with_retry(StubAdapter, "b", "t", "d", %{}, delay_ms: 1) end)

      # 5 sleeps (attempts 6 -> 1), each min(1 * 2^n, 4_000) — dominated by the
      # default max_delay_ms cap once attempt >= 12, so with delay_ms: 1 this
      # is ~ (1+2+4+8+16)ms: fast, but proves 5 retries actually happened
      # rather than bailing after the old budget's 2.
      assert micros >= 30 * 1000
    end
  end
end
