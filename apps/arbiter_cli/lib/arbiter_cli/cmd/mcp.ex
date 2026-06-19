defmodule ArbiterCli.Cmd.Mcp do
  @moduledoc """
  `arb mcp <verb>` — manage MCP scope tokens.

      arb mcp token mint --tier coordinator [--ttl <seconds>] [--json]
          Mint a coordinator-tier scope token. Coordinator tokens are
          workspace-agnostic: one token operates across every workspace on the
          installation (pass `--workspace` / a `workspace` param per call to
          target a specific one). Default TTL: 2592000 seconds (30 days).

      arb mcp token verify <token> [--json]
          Decode and display the claims from a scope token (expiry, tier, workspace).
  """

  alias ArbiterCli.{Client, Output}

  @default_ttl 2_592_000

  def run(argv) do
    case argv do
      ["token" | rest] -> token(rest)
      ["--help" | _] -> IO.puts(@moduledoc)
      ["-h" | _] -> IO.puts(@moduledoc)
      [] -> Output.die("mcp requires a subcommand", "verbs: token")
      [unknown | _] -> Output.die("unknown mcp subcommand: #{unknown}", "verbs: token")
    end
  end

  defp token(argv) do
    case argv do
      ["mint" | rest] ->
        mint(rest)

      ["verify" | rest] ->
        verify(rest)

      ["--help" | _] ->
        IO.puts("token subcommands: mint, verify")

      ["-h" | _] ->
        IO.puts("token subcommands: mint, verify")

      [] ->
        Output.die("mcp token requires a subcommand", "verbs: mint, verify")

      [unknown | _] ->
        Output.die("unknown mcp token subcommand: #{unknown}", "verbs: mint, verify")
    end
  end

  defp mint(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _invalid} =
        OptionParser.parse(argv,
          switches: [tier: :string, ttl: :integer, json: :boolean]
        )

      tier = opts[:tier] || "coordinator"

      unless tier == "coordinator" do
        Output.die("unsupported tier: #{tier}", "only --tier coordinator is supported")
      end

      mode = if opts[:json], do: :json, else: :text
      ttl = opts[:ttl] || @default_ttl

      # Coordinator tokens are workspace-agnostic — no workspace is bound at mint.
      case Client.post("/api/mcp/tokens", %{"ttl" => ttl}) do
        {:ok, resp} -> emit_mint(resp, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp verify(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      token =
        case Enum.reject(rest, &String.starts_with?(&1, "-")) do
          [t | _] -> t
          [] -> Output.die("mcp token verify requires a token argument")
        end

      case Client.post("/api/mcp/tokens/verify", %{"token" => token}) do
        {:ok, resp} -> emit_verify(resp, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp emit_mint(resp, :json) do
    IO.puts(Jason.encode!(resp))
  end

  defp emit_mint(resp, :text) do
    IO.puts(resp["token"])
    IO.puts(:stderr, "tier:         #{resp["tier"]}")
    IO.puts(:stderr, "workspace:    #{workspace_label(resp["workspace_id"])}")
    IO.puts(:stderr, "expires_in:   #{resp["expires_in"]}s (#{ttl_human(resp["expires_in"])})")
    IO.puts(:stderr, "server_url:   #{resp["server_url"]}")
  end

  defp workspace_label(nil), do: "any (workspace-agnostic)"
  defp workspace_label(""), do: "any (workspace-agnostic)"
  defp workspace_label(id), do: id

  defp emit_verify(%{"valid" => false, "reason" => reason}, :json) do
    IO.puts(Jason.encode!(%{"valid" => false, "reason" => reason}))
  end

  defp emit_verify(%{"valid" => false, "reason" => reason}, :text) do
    IO.puts(:stderr, "arb: token is #{reason}")
    Output.halt(1)
  end

  defp emit_verify(resp, :json) do
    IO.puts(Jason.encode!(resp))
  end

  defp emit_verify(resp, :text) do
    IO.puts("valid:        true")
    IO.puts("tier:         #{resp["tier"]}")
    IO.puts("workspace:    #{workspace_label(resp["workspace_id"])}")

    if resp["bead_id"] do
      IO.puts("bead_id:      #{resp["bead_id"]}")
    end

    if resp["rig"] do
      IO.puts("rig:          #{resp["rig"]}")
    end

    IO.puts("can_dispatch:    #{resp["can_dispatch"]}")
  end

  defp ttl_human(nil), do: "?"

  defp ttl_human(seconds) when is_integer(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)

    cond do
      days > 0 and hours > 0 -> "#{days}d #{hours}h"
      days > 0 -> "#{days}d"
      hours > 0 -> "#{hours}h"
      true -> "#{seconds}s"
    end
  end

  defp ttl_human(_), do: "?"
end
