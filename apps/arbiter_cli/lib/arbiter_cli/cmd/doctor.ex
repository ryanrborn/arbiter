defmodule ArbiterCli.Cmd.Doctor do
  @moduledoc """
  `arb doctor` — health checks.

  Currently runs:

    1. Can we reach `GET /api/workspaces`? (Phoenix reachable)
    2. Does at least one workspace exist? (DB reachable + reasonable state)
    3. Can we resolve the configured workspace? (ARB_WORKSPACE / "default")

  Exit code 0 on all green, 1 on any failure.
  """

  alias ArbiterCli.{Client, Output, Workspace}

  def run(argv) do
    mode = Output.mode(argv)

    results = [
      check_phoenix(),
      check_workspaces_exist(),
      check_active_workspace()
    ]

    case mode do
      :json -> emit_json(results)
      :text -> emit_text(results)
    end

    if Enum.any?(results, fn r -> r.status == :fail end) do
      Output.halt(1)
    end
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
    defstruct [:name, :status, :detail, :hint]
  end

  defp check_phoenix do
    case Client.get("/api/workspaces") do
      {:ok, _} ->
        %Result{name: "phoenix reachable", status: :ok, detail: Client.base_url()}

      {:error, %Client.Error{kind: :connection_refused} = err} ->
        %Result{
          name: "phoenix reachable",
          status: :fail,
          detail: err.message,
          hint: err.hint
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "phoenix reachable",
          status: :fail,
          detail: err.message,
          hint: err.hint
        }
    end
  end

  defp check_workspaces_exist do
    case Client.get("/api/workspaces") do
      {:ok, %{"data" => list}} when list != [] ->
        %Result{
          name: "at least one workspace exists",
          status: :ok,
          detail: "#{length(list)} workspace(s)"
        }

      {:ok, _} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: "no workspaces found",
          hint: "Run `mix run priv/repo/seeds.exs` or create one via the API."
        }

      {:error, %Client.Error{} = err} ->
        %Result{
          name: "at least one workspace exists",
          status: :fail,
          detail: err.message,
          hint: err.hint
        }
    end
  end

  defp check_active_workspace do
    case Workspace.resolve() do
      {:ok, ws} ->
        %Result{
          name: "active workspace resolves",
          status: :ok,
          detail: "#{ws["name"]} (#{ws["id"]})"
        }

      {:error, msg} ->
        %Result{
          name: "active workspace resolves",
          status: :fail,
          detail: msg,
          hint: "Set ARB_WORKSPACE or create a workspace named \"default\"."
        }
    end
  end
end
