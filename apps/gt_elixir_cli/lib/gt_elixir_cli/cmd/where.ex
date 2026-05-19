defmodule GtElixirCli.Cmd.Where do
  @moduledoc """
  `bd2 where` — prints information about the current bd2 context: which
  Phoenix host it's talking to and which workspace it resolves to.
  """

  alias GtElixirCli.{Client, Output, Workspace}

  def run(argv) do
    mode = Output.mode(argv)
    base = Client.base_url()
    bd2_ws_env = System.get_env("BD2_WORKSPACE")

    resolved =
      case Workspace.resolve() do
        {:ok, ws} -> ws
        {:error, _} -> nil
      end

    case mode do
      :json ->
        IO.puts(
          Jason.encode!(%{
            base_url: base,
            bd2_workspace_env: bd2_ws_env,
            workspace: resolved
          })
        )

      :text ->
        IO.puts("api host:        #{base}")
        IO.puts("BD2_WORKSPACE:   #{bd2_ws_env || "(unset, defaulting to \"default\")"}")

        case resolved do
          nil ->
            IO.puts("workspace:       (not resolved — run `bd2 doctor`)")

          ws ->
            IO.puts("workspace:")
            Output.emit_workspace(ws, :text)
        end
    end
  end
end
