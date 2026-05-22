defmodule ArbiterCli.Workspace do
  @moduledoc """
  Resolves the active workspace.

  Lookup order:
    1. `ARB_WORKSPACE` env var (workspace name string)
    2. Workspace literally named `"default"`

  Returns `{:ok, workspace_map}` or `{:error, reason_string}`.
  """

  alias ArbiterCli.Client

  @spec resolve() :: {:ok, map()} | {:error, String.t()}
  def resolve do
    target = System.get_env("ARB_WORKSPACE", "default")

    with {:ok, %{"data" => list}} <- Client.get("/api/workspaces") do
      case Enum.find(list, &(&1["name"] == target)) do
        nil ->
          {:error,
           "no workspace named #{inspect(target)}. " <>
             "Set ARB_WORKSPACE or create one with `arb` (workspace creation is not yet a arb command — use the API)."}

        ws ->
          {:ok, ws}
      end
    else
      {:error, %Client.Error{} = err} ->
        {:error, "could not load workspaces: #{err.message}"}
    end
  end

  @doc "Convenience: resolve and return just the id, or halt with a friendly error."
  @spec id_or_halt() :: String.t()
  def id_or_halt do
    case resolve() do
      {:ok, ws} -> ws["id"]
      {:error, msg} -> ArbiterCli.Output.die(msg)
    end
  end
end
