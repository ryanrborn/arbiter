defmodule Arbiter.Boot.ConfigMigrator do
  @moduledoc """
  Run workspace-config data migrations during application boot, right after the
  schema migrations land.

  ## Why this exists (bd-3pqzsa)

  Ecto migrations move the *schema*. Workspace config lives in a JSON column,
  so a config-key rename is invisible to them — it needs a data migration, and
  until this module there was no boot-time home for one. The `rig_paths` →
  `repo_paths` rename shipped a hand-run `mix arbiter.migrate_rig_paths` task
  and, in the same release (v0.1.56), deleted every fallback read. Any install
  that never ran the task by hand lost *all* repo discovery on upgrade:
  `repo_paths` was absent, `rig_paths` was intact but ignored, every dispatch
  failed with `repo "..." is not configured`, PRPatrol went silent, and
  `arb server doctor` stayed green because nothing validated repo config.

  A migration that only runs when an operator remembers to run it is not a
  migration. This child runs it on every boot of the primary instance, so the
  upgrade itself carries the fix.

  ## Shape

  Mirrors `Arbiter.Boot.Migrator`: a one-shot synchronous worker that returns
  `:ignore`, gated on `Arbiter.SingleInstance.primary?/0` so a duplicate or
  transient boot never races the canonical instance's writes. It is placed
  *after* `Arbiter.Boot.Migrator` in the tree so the schema is already at head.

  Every migration here must be idempotent — it runs on every boot, not once.
  """

  require Logger

  alias Arbiter.SingleInstance
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Tasks.Workspace.Changes.PatchConfig

  @legacy_key "rig_paths"
  @current_key "repo_paths"

  @typedoc """
  One workspace's migration outcome. `:repos` is the sorted list of repo names
  that ended up under `repo_paths`; `:repo_paths` is the resulting map.
  """
  @type result :: %{
          workspace: String.t(),
          workspace_id: String.t(),
          repos: [String.t()],
          repo_paths: map(),
          status: :migrated | :dry_run | {:error, String.t()}
        }

  @doc """
  Child spec for the supervision tree.

  A one-shot worker: `start_link/1` does the work inline and returns `:ignore`,
  so `restart: :temporary` — there is nothing to restart.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc """
  Run the config data migrations if this is the primary instance, otherwise
  skip. Always returns `:ignore` — there is no process to supervise.

  `:primary?` overrides the `Arbiter.SingleInstance.primary?/0` lookup (for
  tests); it is evaluated here at start time, not when the spec is built, so
  `Arbiter.Application.children/1` stays a pure spec builder.

  Unlike `Arbiter.Boot.Migrator`, a failure here does NOT abort the boot: a
  workspace whose config cannot be patched is logged loudly and the server
  still comes up, because a reachable server that reports the problem is more
  useful to an operator than a boot loop. `arb server doctor`'s `repos
  resolved` check is the backstop that keeps the failure visible.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    if Keyword.get_lazy(opts, :primary?, &SingleInstance.primary?/0) do
      migrate_rig_paths()
    else
      Logger.info("Boot.ConfigMigrator: not the primary instance — skipping config migrations")
    end

    :ignore
  end

  @doc """
  Migrate every workspace still keyed under the retired `rig_paths` config key.

  For each workspace carrying a `rig_paths` map:

    1. deep-merge `rig_paths` *under* `repo_paths` (existing `repo_paths`
       entries win on key collision — they are presumed more current), then
    2. drop `rig_paths`.

  Returns one `t:result/0` per affected workspace, in read order, and `[]` when
  nothing needs migrating — which is the steady state after the first boot, so
  this is safe to run on every boot.

  Options:

    * `:apply?` (default `true`) — when `false`, report what would move without
      writing anything. Backs `mix arbiter.migrate_rig_paths`'s dry-run.
  """
  @spec migrate_rig_paths(keyword()) :: [result()]
  def migrate_rig_paths(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, true)

    Workspace
    |> read_workspaces()
    |> Enum.filter(&is_map(get_in(&1.config, [@legacy_key])))
    |> Enum.map(&migrate_workspace(&1, apply?))
  end

  defp read_workspaces(resource) do
    Ash.read!(resource)
  rescue
    e ->
      Logger.error("Boot.ConfigMigrator: could not read workspaces — #{Exception.message(e)}")
      []
  end

  defp migrate_workspace(ws, apply?) do
    legacy = ws.config[@legacy_key]
    current = ws.config[@current_key] || %{}

    # `deep_merge(left, right)` lets `right` win, and the current key is the
    # more recent source of truth — so legacy is the LEFT operand here.
    merged = PatchConfig.deep_merge(legacy, current)

    base = %{
      workspace: ws.name,
      workspace_id: ws.id,
      repos: merged |> Map.keys() |> Enum.sort(),
      repo_paths: merged
    }

    if apply? do
      Map.put(base, :status, apply_migration(ws, merged, base.repos))
    else
      Logger.info(
        "Boot.ConfigMigrator: workspace #{ws.name} would migrate #{length(base.repos)} " <>
          "repo(s) from #{@legacy_key} to #{@current_key} (dry run): #{Enum.join(base.repos, ", ")}"
      )

      Map.put(base, :status, :dry_run)
    end
  end

  defp apply_migration(ws, merged, repos) do
    case Ash.update(ws, %{patch: %{@current_key => merged}, unset_paths: [@legacy_key]},
           action: :patch_config
         ) do
      {:ok, _updated} ->
        # Warning, not info: this is a silent-data-loss window closing. An
        # operator reading boot logs should see exactly what moved and for
        # which workspace, so an unexpected migration is noticed.
        Logger.warning(
          "Boot.ConfigMigrator: workspace #{ws.name} carried the retired #{@legacy_key} config " <>
            "key — migrated #{length(repos)} repo(s) to #{@current_key} and dropped " <>
            "#{@legacy_key}: #{Enum.join(repos, ", ")}"
        )

        :migrated

      {:error, err} ->
        message = Exception.message(err)

        Logger.error(
          "Boot.ConfigMigrator: workspace #{ws.name} still carries #{@legacy_key} — migration to " <>
            "#{@current_key} FAILED, its repos will not resolve: #{message}"
        )

        {:error, message}
    end
  end
end
