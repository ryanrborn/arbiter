defmodule Mix.Tasks.Arbiter.ImportFromDolt do
  @shortdoc "Imports issues + dependencies from one or more gas-town Dolt DBs"
  @moduledoc """
  Reads issues and dependencies from the existing gas-town Dolt DBs and inserts
  them into the arbiter store via Ecto.

  Idempotent: re-running skips rows that already exist (`ON CONFLICT DO NOTHING`).

  ## Usage

      mix arbiter.import_from_dolt \\
          --hq-path /home/rborn/dev/gt/.dolt-data/hq \\
          --server-path /home/rborn/dev/gt/.dolt-data/server

  Additional `--path NAME=DIR` flags can be passed for other Dolt DBs:

      mix arbiter.import_from_dolt \\
          --hq-path /home/rborn/dev/gt/.dolt-data/hq \\
          --path access_control=/home/rborn/dev/gt/.dolt-data/access_control

  ## What gets imported

  Per Dolt DB, the task:

  1. Reads the issue prefix from the first row (e.g. `"hq"` from `hq-3o8`).
  2. Finds or creates a `Workspace` with that prefix and a human-readable name.
  3. Bulk-inserts all `issues` rows (Ecto, not Ash — bypasses GenerateId since
     we want to preserve the original IDs). Rows already present
     (by `id`) are skipped via `ON CONFLICT DO NOTHING`.
  4. Bulk-inserts all `dependencies` rows. Skips conflicts on
     `(from_issue_id, to_issue_id, type)`.

  Field mappings live in `Arbiter.Tasks.DoltImport.Mapper` (with unit tests).
  """

  use Mix.Task

  require Ash.Query
  require Logger

  alias Arbiter.Tasks.DoltImport.Mapper

  # Map well-known Dolt DB names to the prefix their dominant tasks use.
  # For unknown source names we fall back to deriving from the first row.
  @known_prefixes %{
    "hq" => "hq",
    "server" => "vs",
    "access_control" => "ac",
    "admin_server" => "ad",
    "auth_server" => "as",
    "verus_client" => "vc",
    "voice_biometrics" => "vb"
  }

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          hq_path: :string,
          server_path: :string,
          path: :keep,
          sync_status: :boolean
        ]
      )

    Mix.Task.run("app.start")

    sources =
      []
      |> maybe_add(opts[:hq_path], "hq")
      |> maybe_add(opts[:server_path], "server")
      |> add_paths(Keyword.get_values(opts, :path))

    if sources == [] do
      Mix.shell().error(
        "No Dolt source provided. Use --hq-path, --server-path, or --path NAME=DIR."
      )

      exit({:shutdown, 1})
    end

    sync_status? = Keyword.get(opts, :sync_status, false)

    if sync_status?, do: Mix.shell().info("(status-sync mode: will UPDATE existing rows)")

    Enum.each(sources, &import_source(&1, sync_status?))

    Mix.shell().info("\n=== Import complete ===")
  end

  defp maybe_add(list, nil, _name), do: list
  defp maybe_add(list, path, name), do: list ++ [{name, path}]

  defp add_paths(list, kvs) do
    kvs
    |> Enum.map(fn s ->
      case String.split(s, "=", parts: 2) do
        [name, path] -> {name, path}
        _ -> Mix.raise("Bad --path value (need NAME=DIR): #{s}")
      end
    end)
    |> then(&(list ++ &1))
  end

  defp import_source({name, path}, sync_status?) do
    Mix.shell().info("\n→ Importing from #{name} (#{path})")

    unless File.dir?(path) do
      Mix.shell().error("  ✗ #{path} does not exist; skipping")
      exit({:shutdown, 1})
    end

    issues = dolt_query(path, "SELECT * FROM issues")
    Mix.shell().info("  read #{length(issues)} issue rows")

    if issues == [] do
      Mix.shell().info("  nothing to import; skipping")
    else
      workspace_id = find_or_create_workspace(name, issues)
      n_inserted = bulk_insert_issues(workspace_id, issues)

      Mix.shell().info(
        "  ✓ inserted #{n_inserted} new issues (#{length(issues) - n_inserted} already present)"
      )

      if sync_status? do
        n_synced = sync_issue_statuses(issues)
        Mix.shell().info("  ✓ synced status for #{n_synced} existing issues")
      end

      deps = dolt_query(path, "SELECT * FROM dependencies")
      n_deps = bulk_insert_dependencies(deps)

      Mix.shell().info(
        "  ✓ inserted #{n_deps} new dependencies (#{length(deps) - n_deps} already present)"
      )
    end
  end

  # ---- Dolt I/O ----

  defp dolt_query(dolt_path, sql) do
    case System.cmd("dolt", ["sql", "-q", sql, "-r", "json"],
           cd: dolt_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"rows" => rows}} -> rows
          {:ok, _} -> []
          {:error, _} -> Mix.raise("Bad JSON from dolt: #{String.slice(output, 0, 200)}")
        end

      {output, code} ->
        Mix.raise("dolt sql failed (exit #{code}): #{String.slice(output, 0, 500)}")
    end
  end

  # ---- Workspace ----

  defp find_or_create_workspace(name, issues) do
    prefix = Map.get(@known_prefixes, name) || Mapper.derive_prefix(issues)

    existing =
      Arbiter.Tasks.Workspace
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one!()

    ws =
      case existing do
        nil ->
          {:ok, ws} =
            Ash.create(Arbiter.Tasks.Workspace, %{
              name: name,
              prefix: prefix,
              description: "Imported from Dolt by mix arbiter.import_from_dolt"
            })

          ws

        ws ->
          ws
      end

    Mix.shell().info("  workspace #{name} (prefix=#{ws.prefix}): #{ws.id}")
    ws.id
  end

  # ---- Issues ----

  defp bulk_insert_issues(workspace_id, rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    records = Enum.map(rows, &Mapper.issue_record(&1, workspace_id, now))

    {n, _} =
      Arbiter.Repo.insert_all(
        "issues",
        records,
        on_conflict: :nothing,
        conflict_target: [:id]
      )

    n
  end

  # Sync mutable fields (status, closed_at, updated_at) on existing rows.
  # Distinct from bulk_insert_issues which DO NOTHING on conflict — this is the
  # "refresh from canonical Dolt" pathway used for the Phase 1 dogfood
  # switchover. Untouched: title/description/etc. (we don't want to clobber
  # local edits made via arb after the initial import).
  defp sync_issue_statuses(rows) do
    Enum.reduce(rows, 0, fn row, acc ->
      status = row["status"] |> Mapper.map_status() |> Atom.to_string()
      closed_at = Mapper.parse_dt(row["closed_at"])

      updated_at =
        Mapper.parse_dt(row["updated_at"]) ||
          DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {n, _} =
        Arbiter.Repo.query!(
          "UPDATE issues SET status = $1, closed_at = $2, updated_at = $3 WHERE id = $4 AND (status != $1 OR (closed_at IS DISTINCT FROM $2))",
          [status, closed_at, updated_at, row["id"]]
        )
        |> then(&{&1.num_rows, &1})

      acc + n
    end)
  end

  # ---- Dependencies ----

  defp bulk_insert_dependencies(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Filter out edges that reference tasks not in our store.
    # Cross-repo deps in Dolt may point to tasks from repos we didn't import
    # (e.g. server has deps pointing to ac-*, ad-* tasks from other Dolt DBs).
    # The FK would block these; skip them rather than failing the whole batch.
    known_ids =
      Arbiter.Repo.query!("SELECT id FROM issues", [])
      |> Map.get(:rows)
      |> Enum.map(&hd/1)
      |> MapSet.new()

    records =
      rows
      |> Enum.map(fn row ->
        cond do
          not MapSet.member?(known_ids, row["issue_id"]) ->
            nil

          not MapSet.member?(known_ids, row["depends_on_id"]) ->
            nil

          true ->
            case Mapper.map_dep_type(row["type"]) do
              nil ->
                nil

              type ->
                Mapper.dependency_record(row, type, now)
            end
        end
      end)
      |> Enum.reject(&is_nil/1)

    {n, _} =
      Arbiter.Repo.insert_all(
        "dependencies",
        records,
        on_conflict: :nothing,
        conflict_target: [:from_issue_id, :to_issue_id, :type]
      )

    n
  end
end
