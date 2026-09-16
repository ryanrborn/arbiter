defmodule Arbiter.Sessions.Memory do
  @moduledoc """
  Mounts the RFC §9.4 shared memory layers into a session's `memory/shared/`
  (bd-6dkpf1, phase 12 — depends on phase 3's scaffold).

  Per the operator's decision (Amendment 3, "a stale memory is worse", bd-cyxzvq),
  a session mounts memory **scoped by `metadata.type`**:

    * `user`, `feedback`, `reference` — mounted read-only for **every**
      session, regardless of workspace binding. Behavioural/operator context
      that doesn't rot and isn't specific to one repo.
    * `project` — mounted **only** for the session's bound workspace. A
      session bound to one workspace must not see another workspace's
      `project` memories (a vstim session must not load arbiter internals) —
      and a cross-workspace session (`workspace_id: nil`) gets none at all,
      since there is no single workspace to scope them to.

  ## Source layout

  `memory_root` (`Arbiter.Config.Paths.memory_root/0` by default) holds flat
  `*.md` files, each with a frontmatter block:

      ---
      name: some-slug
      description: ...
      metadata:
        type: user | feedback | reference | project
        workspace_id: <id>   # project only; which workspace this belongs to
      ---

  This mirrors the memory convention already in use for operator/worker
  memory elsewhere in this install — `type` and (for `project`)
  `workspace_id` are the only two fields this module reads; everything else
  in the file is opaque to it.

  ## Mount mechanism

  A symlink per file is sufficient — the RFC's read-only guarantee is a
  convention enforced by the generated `CLAUDE.md`
  (`Arbiter.Sessions.Instructions`), not a filesystem permission, since a
  session's own user can write through a symlink same as any other file it
  owns. Mounted under `memory/shared/<type>/<basename>`, so "type-scoped"
  is visible in the tree, not just in the filter that built it.

  `mount/2` fully re-renders `memory/shared/` on every call, the same way
  `Arbiter.Sessions.Provisioning` re-renders `CLAUDE.md` and `settings.json`
  on every provision — so a re-provision picks up memory that changed (or
  was removed) since the session first launched, and a source file deleted
  since the last mount does not leave a dangling symlink behind. Never
  touches `memory/candidates/` — that is the session's own write space and
  outlives re-provisioning.
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Session

  @shared_types ~w(user feedback reference)

  @doc """
  Mount `session`'s shared memory layers. Always returns `:ok` — a missing or
  unreadable `memory_root` mounts nothing rather than failing provisioning
  (memory is additive context, not a launch requirement).

  ## Options

    * `:memory_root` — override for `Arbiter.Config.Paths.memory_root/0`
      (how the test suite points this at a fixture directory without
      touching the operator's real memory).
  """
  @spec mount(Session.t(), keyword()) :: :ok
  def mount(%Session{} = session, opts \\ []) do
    root = Keyword.get(opts, :memory_root, Paths.memory_root())
    shared_dir = Layout.memory_shared_dir(session.id)

    _ = File.rm_rf(shared_dir)
    File.mkdir_p!(shared_dir)

    files = memory_files(root)

    Enum.each(@shared_types, fn type ->
      mount_type(shared_dir, type, matching(files, type))
    end)

    mount_type(shared_dir, "project", matching_project(files, session.workspace_id))

    :ok
  end

  defp mount_type(shared_dir, type, files) do
    dest_dir = Path.join(shared_dir, type)
    File.mkdir_p!(dest_dir)

    Enum.each(files, fn path ->
      File.ln_s(path, Path.join(dest_dir, Path.basename(path)))
    end)
  end

  defp matching(files, type) do
    Enum.filter(files, fn path -> frontmatter(path)[:type] == type end)
  end

  defp matching_project(_files, nil), do: []

  defp matching_project(files, workspace_id) do
    Enum.filter(files, fn path ->
      fm = frontmatter(path)
      fm[:type] == "project" and fm[:workspace_id] == workspace_id
    end)
  end

  defp memory_files(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.regular?/1)

      {:error, _reason} ->
        []
    end
  end

  # Line-based, not a real YAML parser: the frontmatter block here only ever
  # carries a handful of flat/one-level-nested scalar keys, and pulling in a
  # YAML dependency for two keys is more than this scaffold needs.
  @frontmatter_delim "---"

  defp frontmatter(path) do
    case File.read(path) do
      {:ok, contents} -> parse_frontmatter(contents)
      {:error, _reason} -> %{}
    end
  end

  defp parse_frontmatter(contents) do
    with [@frontmatter_delim | rest] <- String.split(contents, "\n"),
         {:ok, block, _body} <- split_on_closing_delim(rest) do
      block
      |> Enum.map(&extract_key(&1, "type"))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> %{}
        [type | _] -> %{type: type}
      end
      |> Map.merge(extract_workspace_id(block))
    else
      _ -> %{}
    end
  end

  defp split_on_closing_delim(lines) do
    case Enum.split_while(lines, &(&1 != @frontmatter_delim)) do
      {block, [@frontmatter_delim | body]} -> {:ok, block, body}
      _ -> :error
    end
  end

  defp extract_key(line, key) do
    case Regex.run(~r/^\s*#{key}:\s*(\S+)\s*$/, line) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp extract_workspace_id(block) do
    block
    |> Enum.map(&extract_key(&1, "workspace_id"))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> %{}
      [id | _] -> %{workspace_id: id}
    end
  end
end
