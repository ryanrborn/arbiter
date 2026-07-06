defmodule ArbiterCli.Cmd.Quota do
  @moduledoc """
  `arb quota` — show the current Anthropic rate-limit / quota state.

  The local HTTP proxy captures Anthropic's `anthropic-ratelimit-unified-*`
  headers off every Claude request and stores the latest snapshot per
  workspace. This surfaces it, plus an on-demand secondary fetch of
  Anthropic's `/api/oauth/usage` for a per-model weekly breakdown and
  `extra_usage` overage (bd-8tpha6) — best-effort, so it never hides the
  header-capture figures if it fails or is cooling down from a 429.

  Usage:

      arb quota [--workspace <id|name>] [--json]

  Defaults to the installation's default workspace. With `--json` emits the
  machine-readable snapshot; otherwise a short human-readable summary of the
  5h and 7d windows (utilization, status, reset time), per-model weekly
  utilization, and extra usage overage.

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

  defp emit(%{"claude" => nil} = data, :text) do
    IO.puts("Anthropic quota (workspace #{data["workspace_id"]}):")
    IO.puts("  (no quota captured yet — dispatch a Claude worker to populate it)")
  end

  defp emit(%{"claude" => q} = data, :text) do
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

    emit_oauth_usage(q)
  end

  defp emit_oauth_usage(%{"per_model_utilization" => models, "extra_usage" => extra} = q)
       when map_size(models) > 0 or map_size(extra) > 0 do
    IO.puts("")
    IO.puts("  per-model weekly (7d) — via /api/oauth/usage, captured #{q["oauth_captured_at"] || "—"}:")

    models
    |> Enum.sort()
    |> Enum.each(fn {model, util} ->
      IO.puts("    #{model}: #{format_pct(util)} used")
    end)

    if map_size(extra) > 0 do
      IO.puts("  extra usage overage: #{format_extra_usage(extra)}")
    end
  end

  defp emit_oauth_usage(_), do: :ok

  defp format_extra_usage(%{"amount_usd" => n}) when is_number(n) do
    "$" <> :erlang.float_to_binary(n / 1, decimals: 2)
  end

  defp format_extra_usage(extra), do: inspect(extra)

  defp format_pct(nil), do: "—"

  defp format_pct(n) when is_number(n) do
    :erlang.float_to_binary(n * 100 / 1, decimals: 1) <> "%"
  end

  defp format_pct(_), do: "—"
end
