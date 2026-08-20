defmodule ArbiterCli.Cmd.Doctor.Checks do
  @moduledoc """
  The individual `arb doctor` health checks. Shared by `ArbiterCli.Cmd.Doctor`
  and `arb start`/`arb server deploy`/`arb server restart`/`arb update` so
  "green" has one definition everywhere.
  """

  alias ArbiterCli.{Client, Workspace}

  defmodule Result do
    @moduledoc false
    defstruct [:name, :status, :detail, :hint, :fatal, :blocks_readiness]

    @type t :: %__MODULE__{
            name: String.t(),
            status: :ok | :fail,
            detail: nil | String.t(),
            hint: nil | String.t(),
            fatal: boolean(),
            blocks_readiness: boolean()
          }
  end

  @doc """
  Run every health check and return the result structs, in display order.
  """
  @spec run() :: [Result.t()]
  def run do
    [
      phoenix(),
      check_workspaces_exist(),
      check_active_workspace(),
      check_repos(),
      check_versions(),
      check_migrations()
    ]
  end

  @doc """
  Just the "is Phoenix reachable" check on its own — the cheap single-request
  signal `arb start` uses to decide whether the stack is already up.
  """
  @spec phoenix() :: Result.t()
  def phoenix do
    check_phoenix()
  end

  defp check_phoenix do
    case Client.get("/api/workspaces") do
      {:ok, _} ->
        %Result{
          name: "phoenix reachable",
          status: :ok,
          detail: Client.base_url(),
          fatal: true,
          blocks_readiness: true
        }

      {:error, %Client.Error{kind: :connection_refused} = err} ->
        %Result{
          name: "phoenix reachable",
          status: :fail,
          detail: err.message,
          hint: err.hint,
          fatal: true,
          blocks_readiness: true
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "phoenix reachable",
          status: :fail,
          detail: err.message,
          hint: err.hint,
          fatal: true,
          blocks_readiness: true
        }
    end
  end

  defp check_workspaces_exist do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} when list != [] ->
        %Result{
          name: "at least one workspace exists",
          status: :ok,
          detail: "#{length(list)} workspace(s)",
          fatal: true,
          blocks_readiness: true
        }

      {:ok, _} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: "no workspaces found",
          hint: "Run `mix run priv/repo/seeds.exs` or create one via the API.",
          fatal: true,
          blocks_readiness: true
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: err.message,
          hint: err.hint,
          fatal: true,
          blocks_readiness: true
        }
    end
  end

  defp check_versions do
    cli_sha = ArbiterCli.Version.git_sha_clean()
    cli_vsn = ArbiterCli.Version.app_version()

    case Client.get("/api/version") do
      {:ok, %{"version" => server_vsn} = body} ->
        server_sha = Map.get(body, "sha", "unknown")
        version_result(cli_vsn, cli_sha, server_vsn, server_sha)

      {:error, %Client.Error{kind: :connection_refused}} ->
        %Result{
          name: "version",
          status: :ok,
          detail: "CLI #{cli_vsn} @ #{cli_sha} (server unreachable)",
          fatal: true,
          blocks_readiness: true
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "version",
          status: :ok,
          detail: "CLI #{cli_vsn} @ #{cli_sha} (server error: #{err.message})",
          fatal: true,
          blocks_readiness: true
        }
    end
  end

  # Always report both versions explicitly, and only claim a match when the
  # version numbers themselves are equal. SHAs are informational only — in
  # particular, both CLI and server routinely report sha "unknown" (no git at
  # runtime in a release build), so `cli_sha == server_sha` is NOT evidence of
  # a real match and must never be used as one.
  #
  # `arb server deploy` doesn't refresh the local CLI binary, so a CLI that's
  # a release behind the server is the normal post-deploy state — reported as
  # a warning (`fatal: false`), never as a reason to auto-roll-back a deploy.
  defp version_result(cli_vsn, cli_sha, server_vsn, server_sha) do
    cond do
      cli_vsn == server_vsn ->
        %Result{
          name: "version",
          status: :ok,
          detail: "server #{server_vsn}, CLI #{cli_vsn} (CLI and server match)",
          fatal: false,
          blocks_readiness: false
        }

      major_version(cli_vsn) != major_version(server_vsn) ->
        %Result{
          name: "version",
          status: :fail,
          detail: "server #{server_vsn} @ #{server_sha}, CLI #{cli_vsn} @ #{cli_sha}",
          hint: "Major version mismatch — upgrade both CLI and server to the same major.",
          fatal: false,
          blocks_readiness: false
        }

      true ->
        %Result{
          name: "version",
          status: :fail,
          detail: "server #{server_vsn} @ #{server_sha}, CLI #{cli_vsn} @ #{cli_sha}",
          hint:
            "`arb server deploy` does not refresh the local CLI — reinstall the CLI from " <>
              "the #{server_vsn} release asset to match the server.",
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  defp major_version(vsn) do
    case Version.parse(vsn) do
      {:ok, %Version{major: major}} -> major
      :error -> nil
    end
  end

  # `fatal: true` — this is still an operator-actionable misconfiguration
  # (ambiguous or unresolvable workspace selector) and `arb doctor` should
  # exit non-zero on it, same as any other broken CLI command depending on
  # `Workspace.resolve/0` (`arb issue`, `arb ready`, `arb where`, `arb
  # config`). But `blocks_readiness: false` — it says which workspace CLI
  # commands will operate against, not whether the deployed server is
  # healthy, so `green?/0` (which backs `arb server deploy`'s auto-rollback
  # wait) must not treat it as a reason to roll back an otherwise-healthy
  # deploy (see bd-8ix2tw: every deploy auto-rolled-back on an install whose
  # only workspace wasn't named "default").
  defp check_active_workspace do
    case Workspace.resolve() do
      {:ok, ws} ->
        %Result{
          name: "active workspace resolves",
          status: :ok,
          detail: "#{ws["name"]} (#{ws["id"]})",
          fatal: true,
          blocks_readiness: false
        }

      {:error, msg} ->
        %Result{
          name: "active workspace resolves",
          status: :fail,
          detail: msg,
          hint: "Set ARB_WORKSPACE to pick one of the existing workspaces.",
          fatal: true,
          blocks_readiness: false
        }
    end
  end

  # Repo config is the one piece of workspace state every dispatch depends on
  # and nothing else here validates. bd-3pqzsa: v0.1.56 removed the `rig_paths`
  # fallback, so an un-migrated install resolved ZERO repos — every dispatch
  # failed, PRPatrol went silent — while doctor reported 5/5 green for three
  # days, because "config intact" and "config read" are indistinguishable from
  # the config alone. Two signals make that state loud: any workspace still on
  # a retired config key (exact, names the workspace, count-independent — see
  # legacy_workspaces/1), and otherwise an explicit repo count, which is the
  # generic backstop the next config-key rename lands on.
  #
  # `fatal: true` — an install that resolves no repos is operator-actionable
  # and `arb doctor` should exit non-zero. `blocks_readiness: false` — it says
  # nothing about whether the *deployed server* is healthy, so it must never
  # auto-roll-back a deploy (same reasoning as check_active_workspace, bd-8ix2tw).
  defp check_repos do
    workspaces = workspace_entries()

    case legacy_workspaces(workspaces) do
      [] -> check_repo_count(workspaces)
      names -> legacy_key_result(names)
    end
  end

  # The repo count alone is not enough: `GET /api/repos` aggregates across
  # *every* workspace plus the `:arbiter, :repo_paths` app-env fallback, so on
  # a two-workspace install a migrated workspace A supplies repos while an
  # un-migrated workspace B dispatches nothing — a non-zero total, and the same
  # silence all over again. So flag a lingering `rig_paths` on its own,
  # independent of the count, and name the workspace.
  #
  # Only a *map* under `rig_paths` counts, matching
  # `Arbiter.Boot.ConfigMigrator`'s own candidate filter exactly: anything else
  # is junk the migration will never clear, and flagging it would pin doctor
  # red with no remediation that works.
  defp legacy_workspaces(entries) do
    entries
    |> Enum.filter(&is_map(Map.get(&1.config, "rig_paths")))
    |> Enum.map(& &1.name)
  end

  defp legacy_key_result(names) do
    %Result{
      name: "repos resolved",
      status: :fail,
      detail:
        "#{workspace_phrase(names)} still on the retired `rig_paths` key: #{Enum.join(names, ", ")}",
      hint: legacy_key_hint(),
      fatal: true,
      blocks_readiness: false
    }
  end

  defp workspace_phrase([_]), do: "1 workspace"
  defp workspace_phrase(names), do: "#{length(names)} workspaces"

  # Lead with the remediation that works on every install shape. Production
  # installs are Mix-less releases (`arb server deploy` ships a tarball), so
  # `mix arbiter.migrate_rig_paths` is unrunnable there and belongs last.
  defp legacy_key_hint do
    "Its repo map is intact but nothing reads it. Restart the server " <>
      "(`arb server restart`) — the boot config migrator moves it to `repo_paths` " <>
      "automatically. To migrate without a restart: `bin/arbiter eval " <>
      "Arbiter.Release.migrate_config` on a release install, or " <>
      "`mix arbiter.migrate_rig_paths --apply` from a source checkout."
  end

  defp check_repo_count(workspaces) do
    case Client.get("/api/repos") do
      {:ok, %{"data" => [_ | _] = repos}} ->
        %Result{
          name: "repos resolved",
          status: :ok,
          detail: "#{length(repos)} repo(s)",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"data" => []}} ->
        no_repos_result(workspaces)

      {:ok, _other} ->
        %Result{
          name: "repos resolved",
          status: :ok,
          detail: "unexpected response — skipping",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :connection_refused}} ->
        %Result{
          name: "repos resolved",
          status: :ok,
          detail: "server unreachable",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: 404}} ->
        %Result{
          name: "repos resolved",
          status: :ok,
          detail: "server does not expose repos",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "repos resolved",
          status: :fail,
          detail: err.message,
          hint: err.hint,
          fatal: false,
          blocks_readiness: false
        }
    end
  end

  # Zero repos on a fresh install with no workspace yet is expected, not a
  # fault — the workspace check already owns that failure and we must not
  # double-report it. Once a workspace exists, zero repos means no work can be
  # dispatched, and the hint names the exact remediation. (The `rig_paths` case
  # never reaches here — `check_repos` catches it ahead of the count.)
  defp no_repos_result([]) do
    %Result{
      name: "repos resolved",
      status: :ok,
      detail: "no workspaces — nothing to resolve",
      fatal: false,
      blocks_readiness: false
    }
  end

  defp no_repos_result(_workspaces) do
    %Result{
      name: "repos resolved",
      status: :fail,
      detail: "no repos registered",
      hint: "Register a repo with `arb config set repo_paths.<repo>.path <path>`.",
      fatal: true,
      blocks_readiness: false
    }
  end

  # `%{name: , config: }` per workspace — the name so a failure can point at
  # the workspace that needs fixing, the config so key-level checks (the
  # retired `rig_paths`, and whatever the next rename is) can run client-side.
  defp workspace_entries do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} when is_list(list) ->
        Enum.map(list, fn ws ->
          %{name: Map.get(ws, "name") || Map.get(ws, "id") || "(unnamed)", config: config_of(ws)}
        end)

      _ ->
        []
    end
  end

  defp config_of(ws) do
    case Map.get(ws, "config") do
      config when is_map(config) -> config
      _ -> %{}
    end
  end

  defp check_migrations do
    case Client.get("/api/server/migrations") do
      {:ok, %{"status" => "ok", "pending_count" => 0}} ->
        %Result{
          name: "migrations up to date",
          status: :ok,
          detail: "all migrations applied",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"status" => "warning", "pending_count" => count}}
      when is_integer(count) and count > 0 ->
        %Result{
          name: "migrations up to date",
          status: :fail,
          detail: "#{count} pending",
          hint: "The server has unapplied migrations. Wait for the deployment to complete.",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"status" => "unknown"}} ->
        %Result{
          name: "migrations up to date",
          status: :fail,
          detail: "could not check",
          hint: "The server could not verify migration status. Check server logs for errors.",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, _other} ->
        %Result{
          name: "migrations up to date",
          status: :ok,
          detail: "unexpected response — skipping",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :connection_refused}} ->
        %Result{
          name: "migrations up to date",
          status: :ok,
          detail: "server unreachable",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{kind: :http, status: 404}} ->
        %Result{
          name: "migrations up to date",
          status: :ok,
          detail: "server does not expose migration status",
          fatal: false,
          blocks_readiness: false
        }

      {:error, %Client.Error{}} ->
        %Result{
          name: "migrations up to date",
          status: :fail,
          detail: "could not check migration status",
          fatal: false,
          blocks_readiness: false
        }
    end
  end
end
