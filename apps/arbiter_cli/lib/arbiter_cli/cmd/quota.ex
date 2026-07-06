defmodule ArbiterCli.Cmd.Quota do
  @moduledoc """
  `arb quota` — show the current rate-limit / quota state per provider.

  * Claude: the local HTTP proxy captures Anthropic's
    `anthropic-ratelimit-unified-*` headers off every Claude request and stores
    the latest snapshot per workspace.
  * Codex: fetched live from OpenAI's rate-limit endpoint using the `codex`
    CLI's stored token — session + weekly windows. Shows a short message when
    Codex isn't authenticated (no call is made in that case).

  Usage:

      arb quota [--workspace <id|name>] [--json]

  Defaults to the installation's default workspace. With `--json` emits the
  machine-readable snapshot; otherwise a short human-readable summary of each
  provider's windows (utilization / used-percent and reset time).

  Reads from `GET /api/quota`.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      {opts, _rest, _bad} =
        OptionParser.parse(rest, switches: [workspace: :string], aliases: [w: :workspace])

      params =
        case Keyword.get(opts, :workspace) do
          ws when is_binary(ws) and ws != "" -> [workspace: ws]
          _ -> []
        end

      case Client.get("/api/quota", params) do
        {:ok, %{"data" => data}} -> emit(data, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  # ---- render ------------------------------------------------------------

  defp emit(data, :json), do: IO.puts(Jason.encode!(data))

  defp emit(data, :text) do
    emit_claude(data)
    IO.puts("")
    emit_codex(data)
  end

  # Anthropic (Claude): utilization headers stored as a 0..1 fraction.
  defp emit_claude(%{"claude" => nil} = data) do
    IO.puts("Anthropic quota (workspace #{data["workspace_id"]}):")
    IO.puts("  (no quota captured yet — dispatch a Claude worker to populate it)")
  end

  defp emit_claude(%{"claude" => q} = data) do
    IO.puts("Anthropic quota (workspace #{data["workspace_id"]}):")
    IO.puts("  representative window: #{q["representative_claim"] || "—"}")
    IO.puts("  overage status:        #{q["overage_status"] || "—"}")
    IO.puts("  captured at:           #{q["captured_at"] || "—"}")
    IO.puts("")

    IO.puts(
      "  5h:  #{format_frac(q["utilization_5h"])} used   status=#{q["status_5h"] || "—"}   resets #{q["reset_5h_at"] || "—"}"
    )

    IO.puts(
      "  7d:  #{format_frac(q["utilization_7d"])} used   status=#{q["status_7d"] || "—"}   resets #{q["reset_7d_at"] || "—"}"
    )
  end

  # Codex (OpenAI): windows already normalized to a 0..100 used-percent.
  defp emit_codex(%{"codex" => nil} = data) do
    IO.puts("Codex quota (workspace #{data["workspace_id"]}):")
    IO.puts("  #{data["codex_message"] || "(no Codex quota available)"}")
  end

  defp emit_codex(%{"codex" => c} = data) do
    IO.puts("Codex quota (workspace #{data["workspace_id"]}):")
    IO.puts("  plan:        #{c["plan"] || "—"}")
    IO.puts("  captured at: #{c["captured_at"] || "—"}")
    IO.puts("")
    IO.puts("  session:  #{format_window(c["session"])}")
    IO.puts("  weekly:   #{format_window(c["weekly"])}")
  end

  defp emit_codex(data) do
    IO.puts("Codex quota (workspace #{data["workspace_id"]}):")
    IO.puts("  (no Codex quota available)")
  end

  defp format_window(nil), do: "—"

  defp format_window(%{"used" => used} = w) do
    "#{format_pct(used)} used   resets #{w["reset_at"] || "—"}"
  end

  defp format_window(_), do: "—"

  # A 0..1 fraction (Anthropic headers) → percent.
  defp format_frac(nil), do: "—"
  defp format_frac(n) when is_number(n), do: format_pct(n * 100)
  defp format_frac(_), do: "—"

  # An already-0..100 value → percent string.
  defp format_pct(nil), do: "—"

  defp format_pct(n) when is_number(n) do
    :erlang.float_to_binary(n / 1, decimals: 1) <> "%"
  end

  defp format_pct(_), do: "—"
end
