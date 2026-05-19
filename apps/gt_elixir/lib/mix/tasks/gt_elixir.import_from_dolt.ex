defmodule Mix.Tasks.GtElixir.ImportFromDolt do
  @shortdoc "Imports issues + dependencies from one or more gas-town Dolt DBs"
  @moduledoc """
  Reads issues and dependencies from the existing gas-town Dolt DBs and inserts
  them into the gt-elixir Postgres store via Ecto.

  Idempotent: re-running skips rows that already exist (`ON CONFLICT DO NOTHING`).

  ## Usage

      mix gt_elixir.import_from_dolt \\
          --hq-path /home/rborn/dev/gt/.dolt-data/hq \\
          --server-path /home/rborn/dev/gt/.dolt-data/server

  Additional `--path NAME=DIR` flags can be passed for other Dolt DBs:

      mix gt_elixir.import_from_dolt \\
          --hq-path /home/rborn/dev/gt/.dolt-data/hq \\
          --path access_control=/home/rborn/dev/gt/.dolt-data/access_control

  ## What gets imported

  Per Dolt DB, the task:

  1. Reads the issue prefix from the first row (e.g. `"hq"` from `hq-3o8`).
  2. Finds or creates a `Workspace` with that prefix and a human-readable name.
  3. Bulk-inserts all `issues` rows (Ecto, not Ash — bypasses GenerateId since
     we want to preserve the original IDs). Rows already present in Postgres
     (by `id`) are skipped via `ON CONFLICT DO NOTHING`.
  4. Bulk-inserts all `dependencies` rows. Skips conflicts on
     `(from_issue_id, to_issue_id, type)`.

  Field mappings live in `GtElixir.Beads.DoltImport.Mapper` (with unit tests).
  """

  use Mix.Task

  require Ash.Query
  require Logger

  alias GtElixir.Beads.DoltImport.Mapper

  # Map well-known Dolt DB names to the prefix their dominant beads use.
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
        strict: [hq_path: :string, server_path: :string, path: :keep]
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

    Enum.each(sources, &import_source/1)

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

  defp import_source({name, path}) do
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
      GtElixir.Beads.Workspace
      |> Ash.Query.filter(name == ^name)
      |> Ash.read_one!()

    ws =
      case existing do
        nil ->
          {:ok, ws} =
            Ash.create(GtElixir.Beads.Workspace, %{
              name: name,
              prefix: prefix,
              description: "Imported from Dolt by mix gt_elixir.import_from_dolt"
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
    workspace_uuid_bin = Ecto.UUID.dump!(workspace_id)

    records =
      Enum.map(rows, fn row ->
        {tracker_type, tracker_ref} = Mapper.parse_external_ref(row["external_ref"])

        %{
          id: row["id"],
          workspace_id: workspace_uuid_bin,
          title: Mapper.nonempty(row["title"]) || "(untitled)",
          description: Mapper.compose_description(row),
          acceptance: row["acceptance_criteria"] || "",
          notes: row["notes"] || "",
          qa_notes: "",
          deployment_notes: "",
          # Ecto.insert_all needs the raw DB type (varchar) — convert atoms to strings.
          status: Atom.to_string(Mapper.map_status(row["status"])),
          priority: Mapper.parse_priority(row["priority"]),
          issue_type: Atom.to_string(Mapper.map_issue_type(row["issue_type"])),
          assignee: Mapper.nonempty(row["assignee"]),
          tracker_type: Atom.to_string(tracker_type),
          tracker_ref: tracker_ref,
          created_at: Mapper.parse_dt(row["created_at"]) || now,
          updated_at: Mapper.parse_dt(row["updated_at"]) || now,
          closed_at: Mapper.parse_dt(row["closed_at"])
        }
      end)

    {n, _} =
      GtElixir.Repo.insert_all(
        "issues",
        records,
        on_conflict: :nothing,
        conflict_target: [:id]
      )

    n
  end

  # ---- Dependencies ----

  defp bulk_insert_dependencies(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    # Filter out edges that reference beads not in our Postgres store.
    # Cross-rig deps in Dolt may point to beads from rigs we didn't import
    # (e.g. server has deps pointing to ac-*, ad-* beads from other Dolt DBs).
    # Postgres FK would block these; skip them rather than failing the whole batch.
    known_ids =
      GtElixir.Repo.query!("SELECT id FROM issues", [])
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
                %{
                  # Dependency.id is Ash.Type.UUIDv7 — must be v7, not v4.
                  id: Ash.UUIDv7.bingenerate(),
                  from_issue_id: row["issue_id"],
                  to_issue_id: row["depends_on_id"],
                  type: Atom.to_string(type),
                  created_by: Mapper.nonempty(row["created_by"]),
                  notes: "",
                  created_at: Mapper.parse_dt(row["created_at"]) || now,
                  updated_at: Mapper.parse_dt(row["created_at"]) || now
                }
            end
        end
      end)
      |> Enum.reject(&is_nil/1)

    {n, _} =
      GtElixir.Repo.insert_all(
        "dependencies",
        records,
        on_conflict: :nothing,
        conflict_target: [:from_issue_id, :to_issue_id, :type]
      )

    n
  end
end
