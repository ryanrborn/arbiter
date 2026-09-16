defmodule Arbiter.Sessions.MemoryTest do
  @moduledoc """
  Phase 12 (bd-6dkpf1, RFC §9.4): type-scoped read-only shared memory mounts.

  Acceptance criteria 1 and 3 — provisioning mounts memory by
  `metadata.type`, `project` memories are filtered to the session's bound
  workspace, and a cross-workspace session receives none of them.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Memory
  alias Arbiter.Sessions.Session

  @moduletag :tmp_dir

  defp write_memory!(root, filename, type, extra \\ "") do
    File.mkdir_p!(root)

    File.write!(Path.join(root, filename), """
    ---
    name: #{Path.rootname(filename)}
    description: fixture
    metadata:
      type: #{type}
    #{extra}---

    Fixture body for #{filename}.
    """)
  end

  defp session(id, workspace_id \\ nil) do
    %Session{id: id, workspace_id: workspace_id}
  end

  setup %{tmp_dir: tmp_dir} do
    memory_root = Path.join(tmp_dir, "memory_root")
    sessions_root = Path.join(tmp_dir, "sessions")
    File.mkdir_p!(memory_root)

    prior = Application.get_env(:arbiter, :sessions_root)
    Application.put_env(:arbiter, :sessions_root, sessions_root)
    on_exit(fn -> restore(:sessions_root, prior) end)

    {:ok, memory_root: memory_root}
  end

  defp restore(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore(key, val), do: Application.put_env(:arbiter, key, val)

  describe "mount/2" do
    test "mounts user, feedback and reference read-only for every session", %{
      memory_root: root
    } do
      write_memory!(root, "user-fact.md", "user")
      write_memory!(root, "feedback-fact.md", "feedback")
      write_memory!(root, "reference-fact.md", "reference")

      s = session("sess-shared")
      :ok = Memory.mount(s, memory_root: root)

      shared = Layout.memory_shared_dir(s.id)
      assert File.read_link(Path.join([shared, "user", "user-fact.md"])) |> elem(0) == :ok
      assert File.read_link(Path.join([shared, "feedback", "feedback-fact.md"])) |> elem(0) == :ok

      assert File.read_link(Path.join([shared, "reference", "reference-fact.md"])) |> elem(0) ==
               :ok
    end

    test "cross-workspace session receives no project memories", %{memory_root: root} do
      write_memory!(root, "arbiter-internals.md", "project", "  workspace_id: ws-arbiter\n")

      s = session("sess-cross", nil)
      :ok = Memory.mount(s, memory_root: root)

      project_dir = Path.join(Layout.memory_shared_dir(s.id), "project")
      assert File.ls!(project_dir) == []
    end

    test "a bound session receives only its own workspace's project memories", %{
      memory_root: root
    } do
      write_memory!(root, "arbiter-internals.md", "project", "  workspace_id: ws-arbiter\n")
      write_memory!(root, "vstim-fact.md", "project", "  workspace_id: ws-vstim\n")

      s = session("sess-vstim", "ws-vstim")
      :ok = Memory.mount(s, memory_root: root)

      project_dir = Path.join(Layout.memory_shared_dir(s.id), "project")
      assert File.ls!(project_dir) == ["vstim-fact.md"]
    end

    test "shared types are still mounted for a workspace-bound session", %{memory_root: root} do
      write_memory!(root, "user-fact.md", "user")
      write_memory!(root, "arbiter-internals.md", "project", "  workspace_id: ws-arbiter\n")

      s = session("sess-bound-shared", "ws-vstim")
      :ok = Memory.mount(s, memory_root: root)

      shared = Layout.memory_shared_dir(s.id)
      assert File.ls!(Path.join(shared, "user")) == ["user-fact.md"]
      assert File.ls!(Path.join(shared, "project")) == []
    end

    test "re-mounting clears a stale symlink (idempotent re-provision)", %{memory_root: root} do
      write_memory!(root, "user-fact.md", "user")
      s = session("sess-idempotent")

      :ok = Memory.mount(s, memory_root: root)
      File.rm!(Path.join(root, "user-fact.md"))
      :ok = Memory.mount(s, memory_root: root)

      assert File.ls!(Path.join(Layout.memory_shared_dir(s.id), "user")) == []
    end

    test "a missing memory root is a no-op, not an error", %{memory_root: root} do
      missing = Path.join(root, "does-not-exist")
      s = session("sess-missing-root")

      assert :ok = Memory.mount(s, memory_root: missing)
      assert File.dir?(Layout.memory_shared_dir(s.id))
    end
  end
end
