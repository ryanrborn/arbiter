defmodule GtElixirCli.Workspace do
  @moduledoc """
  Resolves the active workspace.

  Lookup order:
    1. `BD2_WORKSPACE` env var (workspace name string)
    2. Workspace literally named `"default"`

  Returns `{:ok, workspace_map}` or `{:error, reason_string}`.
  """

  alias GtElixirCli.Client

  @spec resolve() :: {:ok, map()} | {:error, String.t()}
  def resolve do
    target = System.get_env("BD2_WORKSPACE", "default")

    with {:ok, %{"data" => list}} <- Client.get("/api/workspaces") do
      case Enum.find(list, &(&1["name"] == target)) do
        nil ->
          {:error,
           "no workspace named #{inspect(target)}. " <>
             "Set BD2_WORKSPACE or create one with `bd2` (workspace creation is not yet a bd2 command — use the API)."}

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
      {:error, msg} -> GtElixirCli.Output.die(msg)
    end
  end
end
