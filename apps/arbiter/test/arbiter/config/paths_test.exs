defmodule Arbiter.Config.PathsTest do
  use ExUnit.Case, async: false

  alias Arbiter.Config.Paths

  # async: false — we mutate both process env and the :arbiter application
  # env for :worktree_root / :output_log_root.

  setup do
    prior_env_wt = System.get_env("ARBITER_WORKTREE_ROOT")
    prior_env_log = System.get_env("ARBITER_OUTPUT_LOG_ROOT")
    prior_cfg_wt = Application.get_env(:arbiter, :worktree_root)
    prior_cfg_log = Application.get_env(:arbiter, :output_log_root)
    prior_env_sess = System.get_env("ARBITER_COORDINATOR_SESSION_DIRS")
    prior_cfg_sess = Application.get_env(:arbiter, :coordinator_session_dirs)

    on_exit(fn ->
      restore_env("ARBITER_WORKTREE_ROOT", prior_env_wt)
      restore_env("ARBITER_OUTPUT_LOG_ROOT", prior_env_log)
      restore_env("ARBITER_COORDINATOR_SESSION_DIRS", prior_env_sess)
      restore_cfg(:worktree_root, prior_cfg_wt)
      restore_cfg(:output_log_root, prior_cfg_log)
      restore_cfg(:coordinator_session_dirs, prior_cfg_sess)
    end)

    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  defp restore_cfg(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_cfg(key, val), do: Application.put_env(:arbiter, key, val)

  describe "worktree_root/0" do
    test "env var wins over app config and default" do
      System.put_env("ARBITER_WORKTREE_ROOT", "/tmp/from-env-wt")
      Application.put_env(:arbiter, :worktree_root, "/tmp/from-config-wt")

      assert Paths.worktree_root() == "/tmp/from-env-wt"
    end

    test "app config wins over default when env var is unset" do
      System.delete_env("ARBITER_WORKTREE_ROOT")
      Application.put_env(:arbiter, :worktree_root, "/tmp/from-config-wt")

      assert Paths.worktree_root() == "/tmp/from-config-wt"
    end

    test "falls back to a $HOME-relative default when nothing is set" do
      System.delete_env("ARBITER_WORKTREE_ROOT")
      Application.delete_env(:arbiter, :worktree_root)

      assert Paths.worktree_root() == Path.expand("~/dev/arbiter-worktrees")
    end

    test "raises a named-env-var error instead of crashing on a missing HOME" do
      System.delete_env("ARBITER_WORKTREE_ROOT")
      Application.delete_env(:arbiter, :worktree_root)
      prior_home = System.get_env("HOME")
      System.delete_env("HOME")

      try do
        assert_raise RuntimeError, ~r/ARBITER_WORKTREE_ROOT/, fn ->
          Paths.worktree_root()
        end
      after
        restore_env("HOME", prior_home)
      end
    end
  end

  describe "output_log_root/0" do
    test "env var wins over app config and default" do
      System.put_env("ARBITER_OUTPUT_LOG_ROOT", "/tmp/from-env-log")
      Application.put_env(:arbiter, :output_log_root, "/tmp/from-config-log")

      assert Paths.output_log_root() == "/tmp/from-env-log"
    end

    test "app config wins over default when env var is unset" do
      System.delete_env("ARBITER_OUTPUT_LOG_ROOT")
      Application.put_env(:arbiter, :output_log_root, "/tmp/from-config-log")

      assert Paths.output_log_root() == "/tmp/from-config-log"
    end

    test "falls back to a $HOME-relative default when nothing is set" do
      System.delete_env("ARBITER_OUTPUT_LOG_ROOT")
      Application.delete_env(:arbiter, :output_log_root)

      assert Paths.output_log_root() == Path.expand("~/dev/arbiter-worker-logs")
    end
  end

  describe "coordinator_session_dirs/0" do
    test "defaults to none — metering is opt-in, never a guessed home directory" do
      System.delete_env("ARBITER_COORDINATOR_SESSION_DIRS")
      Application.delete_env(:arbiter, :coordinator_session_dirs)
      assert Paths.coordinator_session_dirs() == []
    end

    test "the env var takes a colon- or comma-separated list, ~ expanded" do
      System.put_env("ARBITER_COORDINATOR_SESSION_DIRS", "/tmp/a:/tmp/b,/tmp/c")
      assert Paths.coordinator_session_dirs() == ["/tmp/a", "/tmp/b", "/tmp/c"]
    end

    test "application config accepts a list or a single string" do
      System.delete_env("ARBITER_COORDINATOR_SESSION_DIRS")
      Application.put_env(:arbiter, :coordinator_session_dirs, ["/tmp/x", "/tmp/y"])
      assert Paths.coordinator_session_dirs() == ["/tmp/x", "/tmp/y"]

      Application.put_env(:arbiter, :coordinator_session_dirs, "/tmp/z")
      assert Paths.coordinator_session_dirs() == ["/tmp/z"]
    end

    test "blank entries are dropped rather than becoming the cwd" do
      System.put_env("ARBITER_COORDINATOR_SESSION_DIRS", "/tmp/a::,  ,/tmp/b")
      assert Paths.coordinator_session_dirs() == ["/tmp/a", "/tmp/b"]
    end
  end
end
