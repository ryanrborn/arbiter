defmodule ArbiterCli.Cmd.Version do
  @moduledoc """
  `arb version` — report CLI escript and server versions side by side.

  Prints the CLI escript's embedded {version, sha, built-at} and queries the
  server's {version, sha, built-at, booted-at}. A SHA mismatch between CLI
  and server is flagged loudly. The CLI half always prints even when the
  server is unreachable.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    mode = Output.mode(argv)
    cli_info = cli_version()
    server_result = fetch_server_version()

    case mode do
      :json -> emit_json(cli_info, server_result)
      :text -> emit_text(cli_info, server_result)
    end
  end

  defp cli_version do
    %{
      version: ArbiterCli.Version.app_version(),
      sha: ArbiterCli.Version.git_sha(),
      built_at: ArbiterCli.Version.built_at()
    }
  end

  defp fetch_server_version do
    case Client.get("/api/version") do
      {:ok, body} -> {:ok, body}
      {:error, %Client.Error{kind: :connection_refused}} -> {:error, :unreachable}
      {:error, %Client.Error{} = err} -> {:error, err.message}
    end
  end

  defp emit_text(cli, server_result) do
    IO.puts("CLI escript")
    IO.puts("  version:   #{cli.version}")
    IO.puts("  sha:       #{cli.sha}")
    IO.puts("  built-at:  #{cli.built_at}")
    IO.puts("")

    case server_result do
      {:ok, server} ->
        IO.puts("Server")
        IO.puts("  version:   #{server["version"]}")
        IO.puts("  sha:       #{server["sha"]}")
        IO.puts("  built-at:  #{server["built_at"]}")
        IO.puts("  booted-at: #{server["booted_at"]}")

        if sha_mismatch?(cli.sha, server["sha"]) do
          IO.puts("")
          IO.puts("WARNING: CLI and server are on different builds — rebuild the escript and/or redeploy the server")
        end

      {:error, :unreachable} ->
        IO.puts("Server")
        IO.puts("  (unreachable — start the server to compare versions)")

      {:error, msg} ->
        IO.puts("Server")
        IO.puts("  (error: #{msg})")
    end
  end

  defp emit_json(cli, server_result) do
    {server_data, mismatch} =
      case server_result do
        {:ok, server} ->
          {server, sha_mismatch?(cli.sha, server["sha"])}

        {:error, :unreachable} ->
          {%{"status" => "unreachable"}, nil}

        {:error, msg} ->
          {%{"status" => "error", "message" => msg}, nil}
      end

    IO.puts(
      Jason.encode!(%{
        cli: cli,
        server: server_data,
        sha_mismatch: mismatch
      })
    )
  end

  # Strip dirty flag (`*`) before comparing short SHAs.
  defp sha_mismatch?(cli_sha, server_sha)
       when is_binary(cli_sha) and is_binary(server_sha) do
    String.trim_trailing(cli_sha, "*") != server_sha
  end

  defp sha_mismatch?(_, _), do: false
end
