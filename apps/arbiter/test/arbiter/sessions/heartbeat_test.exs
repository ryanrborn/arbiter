defmodule Arbiter.Sessions.HeartbeatTest do
  @moduledoc """
  The input side of the in-scope dead-man's switch (bd-3qkbch, RFC §4.6.3,
  phase 10): arbiter's own liveness file.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Sessions.Heartbeat
  alias Arbiter.Sessions.Naming

  setup do
    runtime = Path.join(System.tmp_dir!(), "bd-3qkbch-hb-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:arbiter, :sessions_runtime_dir)
    Application.put_env(:arbiter, :sessions_runtime_dir, runtime)

    on_exit(fn ->
      if previous do
        Application.put_env(:arbiter, :sessions_runtime_dir, previous)
      else
        Application.delete_env(:arbiter, :sessions_runtime_dir)
      end

      File.rm_rf(runtime)
    end)

    :ok
  end

  test "touch/0 writes the heartbeat file, creating its directory" do
    assert :ok = Heartbeat.touch()
    assert {:ok, path} = Naming.heartbeat_path()
    assert File.regular?(path)
  end

  test "touch/0 rewrites the file's content (a fresh timestamp) on a second call" do
    Heartbeat.touch()
    {:ok, path} = Naming.heartbeat_path()

    # Overwrite with an obviously-stale marker, then touch again — the
    # watchdog reads mtime, not content, but content changing is the
    # observable proof that the write actually happened again rather than
    # `File.write/2` short-circuiting on an unchanged value.
    File.write!(path, "not a real heartbeat")
    Heartbeat.touch()

    refute File.read!(path) == "not a real heartbeat"
    assert {:ok, _, _} = DateTime.from_iso8601(File.read!(path))
  end

  test "touch/0 is a no-op, not a crash, with no runtime dir" do
    Application.delete_env(:arbiter, :sessions_runtime_dir)
    previous_env = System.get_env("XDG_RUNTIME_DIR")
    System.delete_env("XDG_RUNTIME_DIR")

    on_exit(fn ->
      if previous_env, do: System.put_env("XDG_RUNTIME_DIR", previous_env)
    end)

    assert :ok = Heartbeat.touch()
  end
end
