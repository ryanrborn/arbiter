defmodule ArbiterCli.Cmd.Doctor do
  @moduledoc """
  `arb doctor` — health checks.

  Currently runs:

    1. Can we reach `GET /api/workspaces`? (Phoenix reachable)
    2. Does at least one workspace exist? (DB reachable + reasonable state)
    3. Can we resolve the configured workspace? (ARB_WORKSPACE, else the
       workspace named "default", else the sole workspace if there's only one)

  Exit code 0 on all green, 1 on any failure.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      results = checks()

      case mode do
        :json -> emit_json(results)
        :text -> emit_text(results)
      end

      if Enum.any?(results, fn r -> r.status == :fail and r.fatal end) do
        Output.halt(1)
      end
    end
  end

  @doc """
  Run every health check and return the result structs, in display order.
  Shared by `arb doctor` and `arb start` so "green" has one definition.
  """
  @spec checks() :: [Result.t()]
  def checks do
    [
      check_phoenix(),
      check_workspaces_exist(),
      check_active_workspace(),
      check_versions(),
      check_migrations()
    ]
  end

  @doc """
  True when Phoenix's HTTP API is reachable — the first health check on its
  own. This is the "is the stack already running?" signal `arb start` uses to
  stay a no-op.
  """
  @spec reachable?() :: boolean()
  def reachable?, do: check_phoenix().status == :ok

  @doc """
  True when every readiness-blocking health check passes. `fatal` alone can't
  gate this: it also drives `arb doctor`'s exit code, and some checks (like
  workspace resolution) are operator-actionable failures worth a non-zero
  exit without saying anything about whether the deployed server is healthy.
  `blocks_readiness` is the narrower signal `arb server deploy`'s
  auto-rollback wait actually needs.
  """
  @spec green?() :: boolean()
  def green? do
    Enum.all?(checks(), fn r ->
      r.status == :ok or (r.status == :fail and not r.blocks_readiness)
    end)
  end

  @doc """
  Print the human-readable health report to stdout and return whether all
  checks passed. Lets `arb start` show the same status block `arb doctor`
  does without duplicating the formatting.
  """
  @spec report() :: boolean()
  def report do
    results = checks()
    emit_text(results)
    Enum.all?(results, fn r -> r.status == :ok end)
  end

  defp emit_text(results) do
    IO.puts("arb doctor — checks against #{Client.base_url()}")
    IO.puts("")

    Enum.each(results, fn r ->
      marker = if r.status == :ok, do: "[ ok ]", else: "[fail]"
      IO.puts("#{marker} #{r.name}")
      if r.detail, do: IO.puts("        #{r.detail}")
      if r.status == :fail and r.hint, do: IO.puts("        hint: #{r.hint}")
    end)
  end

  defp emit_json(results) do
    payload = %{
      base_url: Client.base_url(),
      checks: Enum.map(results, &Map.from_struct/1),
      ok: Enum.all?(results, fn r -> r.status == :ok end)
    }

    IO.puts(Jason.encode!(payload))
  end

  # ---- individual checks ----

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

  defp check_migrations do
    case Client.get("/api/server/migrations") do
      {:ok, %{"pending_count" => 0}} ->
        %Result{
          name: "migrations up to date",
          status: :ok,
          detail: "all migrations applied",
          fatal: false,
          blocks_readiness: false
        }

      {:ok, %{"pending_count" => count}} when is_integer(count) and count > 0 ->
        %Result{
          name: "migrations up to date",
          status: :fail,
          detail: "#{count} pending",
          hint: "The server has unapplied migrations. Wait for the deployment to complete.",
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
