defmodule ArbiterCli.Cmd.Quota do
  @moduledoc """
  `arb quota` — show the current Anthropic rate-limit / quota state.

  The local HTTP proxy captures Anthropic's `anthropic-ratelimit-unified-*`
  headers off every Claude request and stores the latest snapshot per
  workspace. This surfaces it.

  Usage:

      arb quota [--workspace <id|name>] [--json]

  Defaults to the installation's default workspace. With `--json` emits the
  machine-readable snapshot; otherwise a short human-readable summary of the
  5h and 7d windows (utilization, status, reset time).

  When the Gemini CLI / Antigravity are authenticated on this host, their live
  per-model Cloud Code Assist quota (remaining %, reset time) is shown too.

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
    emit_google(data["gemini"], "Gemini CLI")
    emit_google(data["antigravity"], "Antigravity")
  end

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
      "  5h:  #{format_pct(q["utilization_5h"])} used   status=#{q["status_5h"] || "—"}   resets #{q["reset_5h_at"] || "—"}"
    )

    IO.puts(
      "  7d:  #{format_pct(q["utilization_7d"])} used   status=#{q["status_7d"] || "—"}   resets #{q["reset_7d_at"] || "—"}"
    )
  end

  # Live Cloud Code Assist snapshots (Gemini CLI / Antigravity). `nil` means
  # that CLI isn't authenticated on this host — stay quiet rather than noisy.
  defp emit_google(nil, _label), do: :ok

  defp emit_google(snap, label) do
    IO.puts("")
    IO.puts("#{label} quota (plan: #{snap["plan"] || "—"}):")

    case snap["message"] do
      msg when is_binary(msg) and msg != "" -> IO.puts("  #{msg}")
      _ -> :ok
    end

    case snap["models"] do
      [] ->
        if snap["message"] in [nil, ""], do: IO.puts("  (no per-model quota reported)")

      models when is_list(models) ->
        Enum.each(models, &emit_model/1)

      _ ->
        :ok
    end
  end

  defp emit_model(m) do
    name = m["display_name"] || m["model_id"] || "—"
    reset = m["reset_at"] || "—"

    IO.puts(
      "  #{name}: #{format_pct_plain(m["remaining_percentage"])} remaining   resets #{reset}"
    )
  end

  defp format_pct(nil), do: "—"

  defp format_pct(n) when is_number(n) do
    :erlang.float_to_binary(n * 100 / 1, decimals: 1) <> "%"
  end

  defp format_pct(_), do: "—"

  # Google snapshots already carry a 0–100 percentage, so render it as-is.
  defp format_pct_plain(n) when is_number(n) do
    :erlang.float_to_binary(n / 1, decimals: 1) <> "%"
  end

  defp format_pct_plain(_), do: "—"
end
