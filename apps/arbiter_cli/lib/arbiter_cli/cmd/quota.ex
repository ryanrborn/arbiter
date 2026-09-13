defmodule ArbiterCli.Cmd.Quota do
  @moduledoc """
  `arb quota` — show the current rate-limit / quota state per provider.

  Every provider is read from its persisted snapshot (a pure DB read, bd-ajh7bd);
  background probes keep them fresh, so this command never fetches live and
  carries no request-time latency:

  * Claude: the local HTTP proxy captures Anthropic's
    `anthropic-ratelimit-unified-*` headers off every Claude request and stores
    the latest snapshot per workspace, plus the secondary `/api/oauth/usage`
    per-model weekly breakdown and `extra_usage` overage (bd-8tpha6).
  * Codex: OpenAI session + weekly windows, refreshed by the quota probe using
    the `codex` CLI's stored token. Shows a short message until a snapshot has
    been captured (i.e. the CLI isn't authenticated on this host).
  * Gemini CLI: per-model Cloud Code Assist quota (remaining %, reset time),
    shown once that CLI is authenticated and probed on this host.
  * Antigravity: per-window remaining % + reset time for each model group
    (`Gemini Models`, `Claude and GPT models` × `5h`, `weekly`), sourced
    directly from `agy --output-format json --print "/usage"` (bd-d7hmqn) —
    shown once the `agy` CLI is authenticated on this host.

  Each provider also shows its recent spend (last 30 days, actual dollars from
  the usage ledger) when any is recorded.

  Usage:

      arb quota [--workspace <id|name>] [--json]

  Defaults to the installation's default workspace. With `--json` emits the
  machine-readable snapshot; otherwise a short human-readable summary.

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
    emit_google(data["gemini"], "Gemini CLI", provider_cost(data, "gemini_cli"))
    emit_google(data["antigravity"], "Antigravity", provider_cost(data, "antigravity"))
  end

  # Recent-spend line, sourced from the multi-provider `quotas` list each entry
  # of which carries `cost_usd` (30-day actual spend from the usage ledger).
  defp emit_spend(data, provider) do
    case provider_cost(data, provider) do
      cost when is_number(cost) ->
        IO.puts("  recent spend (30d): $#{:erlang.float_to_binary(cost / 1, decimals: 2)}")

      _ ->
        :ok
    end
  end

  defp provider_cost(data, provider) do
    (data["quotas"] || [])
    |> Enum.find(&(&1["provider"] == provider))
    |> case do
      %{"cost_usd" => c} when is_number(c) -> c
      _ -> nil
    end
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

    captured_at_str = q["captured_at"] || "—"
    stale_indicator = stale_indicator(q, captured_at_str)

    IO.puts("  captured at:           #{captured_at_str}#{stale_indicator}")
    IO.puts("  source:                #{capture_source_label(q["capture_source"])}")
    IO.puts("  gating dispatch:       #{gating_line(q)}")
    IO.puts("")

    IO.puts(
      "  5h:  #{format_frac(q["utilization_5h"])} used   status=#{q["status_5h"] || "—"}   resets #{q["reset_5h_at"] || "—"}"
    )

    IO.puts(
      "  7d:  #{format_frac(q["utilization_7d"])} used   status=#{q["status_7d"] || "—"}   resets #{q["reset_7d_at"] || "—"}"
    )

    emit_spend(data, "claude")
    emit_oauth_usage(q)
  end

  # bd-b7umwj: staleness is scoped per window, and the two windows go
  # opposite ways — say which is which rather than the old blanket
  # "dispatches may be incorrectly held", which was backwards for both.
  defp stale_indicator(%{"stale" => true} = q, captured_at_str) do
    base =
      " ⚠️ STALE (older than the gate trusts — the 5h gate fails open; a 7d hold stays in force)"

    base <> stale_detail(q, captured_at_str)
  end

  defp stale_indicator(_q, _captured_at_str), do: ""

  # bd-4fbpto: "STALE" alone can't tell "nothing has worked in a while" apart
  # from "the poll is fine, it just didn't carry a usable 5h figure this
  # cycle" — both look identical (STALE, old `captured_at`) without this.
  # Say which one it is.
  defp stale_detail(%{"oauth_poll_fresh" => true} = q, _captured_at_str) do
    " — /api/oauth/usage last succeeded #{q["oauth_captured_at"] || "—"}"
  end

  defp stale_detail(q, captured_at_str) do
    " — no fresh data from any source (last success: " <>
      "#{capture_source_label(q["capture_source"])} at #{captured_at_str})"
  end

  # Which window, if any, is currently holding dispatch (bd-1tuxv8). Both the 5h
  # and the 7d figures are printed above; this line says which one the gate is
  # actually acting on, so "7d is at 76%" can no longer be misread as the reason
  # Autopilot is idle when the gate is not looking at it.
  defp gating_line(q) do
    case q["gating_window"] do
      nil -> "none — dispatch is not quota-held"
      window -> "#{window} — #{q["gating_reason"] || "held"}"
    end
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
    emit_spend(data, "codex")
  end

  defp emit_codex(data) do
    IO.puts("Codex quota (workspace #{data["workspace_id"]}):")
    IO.puts("  (no Codex quota available)")
  end

  # Live Cloud Code Assist snapshots (Gemini CLI / Antigravity). `nil` means
  # that CLI isn't authenticated on this host — stay quiet rather than noisy.
  defp emit_google(nil, _label, _cost), do: :ok

  # Pre-existing complexity 10 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp emit_google(snap, label, cost) do
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

    if is_number(cost) do
      IO.puts("  recent spend (30d): $#{:erlang.float_to_binary(cost / 1, decimals: 2)}")
    end
  end

  # bd-b0zody: the primary columns now have two possible writers — the proxy's
  # header capture and the /api/oauth/usage poll — and while both are live the
  # row is unreadable without saying which one wrote it. Legacy rows predate
  # the marker and can only have come from the proxy.
  defp capture_source_label("oauth_poll"), do: "/api/oauth/usage poll"
  defp capture_source_label("headers"), do: "proxy rate-limit headers"
  defp capture_source_label(nil), do: "— (pre-dates source tracking)"
  defp capture_source_label(other), do: to_string(other)

  defp emit_model(m) do
    name = m["display_name"] || m["model_id"] || "—"
    reset = m["reset_at"] || "—"

    IO.puts(
      "  #{name}: #{format_pct_plain(m["remaining_percentage"])} remaining   resets #{reset}"
    )
  end

  defp emit_oauth_usage(%{"per_model_utilization" => models, "extra_usage" => extra} = q)
       when map_size(models) > 0 or map_size(extra) > 0 do
    IO.puts("")

    IO.puts(
      "  per-model weekly (7d) — via /api/oauth/usage, captured #{q["oauth_captured_at"] || "—"}:"
    )

    models
    |> Enum.sort()
    |> Enum.each(fn {model, util} ->
      IO.puts("    #{model}: #{format_frac(util)} used")
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

  # Google snapshots already carry a 0–100 percentage, so render it as-is.
  defp format_pct_plain(n) when is_number(n) do
    :erlang.float_to_binary(n / 1, decimals: 1) <> "%"
  end

  defp format_pct_plain(_), do: "—"
end
