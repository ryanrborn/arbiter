defmodule ArbiterCli.Cmd.Where do
  @moduledoc """
  `arb where` — prints information about the current arb context: which
  Phoenix host it's talking to and which workspace it resolves to.
  """

  alias ArbiterCli.{Client, Output, Vernacular, Workspace}

  def run(argv) do
    mode = Output.mode(argv)
    base = Client.base_url()
    bd2_ws_env = System.get_env("ARB_WORKSPACE")

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
        v = Vernacular.fetch()
        ws_label = Vernacular.label(v, "workspace")
        IO.puts("api host:        #{base}")
        IO.puts("ARB_WORKSPACE:   #{bd2_ws_env || "(unset, defaulting to \"default\")"}")

        case resolved do
          nil ->
            IO.puts("#{ws_label}:       (not resolved — run `arb doctor`)")

          ws ->
            IO.puts("#{ws_label}:")
            Output.emit_workspace(ws, :text)
        end
    end
  end
end
