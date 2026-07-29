defmodule ArbiterCli.Cmd.Loop do
  @moduledoc """
  `arb loop` — the operator-invoked loop-engineering surface.

  ## `arb loop analyze`

  Run the Stage 1 loop-analysis pass (bd-dyfaq3) over a window and print its
  markdown report. The pass reads `worker_runs ⨝ usage_events ⨝
  review_gate_rounds ⨝ issues`, segments failures operational-vs-agent-quality
  by allowlist (corroborating each `failure_reason` against the transcript),
  clusters reviewer findings, and flags difficulty misestimates — then emits a
  report and **writes nothing** but its own cost row. The operator reads it and
  decides where each lesson lands (a skill, the repo's `CLAUDE.md`, or a
  per-task override).

  Usage:

      arb loop analyze [--since 7d | <iso8601>] [--until <iso8601>]
                       [--limit N] [--workspace <id>] [--json]

  `--since` accepts `7d` / `24h` / `30m` shortcuts or ISO8601 (default: last 7
  days). `--json` prints the raw envelope (markdown + structured summary)
  instead of just the report.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)
      rest = Output.drop_json(argv)

      case rest do
        ["analyze" | tail] -> analyze(tail, mode)
        [] -> analyze([], mode)
        [other | _] -> Output.die("unknown `arb loop` subcommand: #{other}")
      end
    end
  end

  defp analyze(argv, mode) do
    {opts, _rest, _bad} =
      OptionParser.parse(argv,
        switches: [since: :string, until: :string, limit: :integer, workspace: :string],
        aliases: [s: :since, l: :limit, w: :workspace]
      )

    params =
      []
      |> maybe_put(:since, Keyword.get(opts, :since))
      |> maybe_put(:until, Keyword.get(opts, :until))
      |> maybe_put(:limit, Keyword.get(opts, :limit))
      |> maybe_put(:workspace_id, Keyword.get(opts, :workspace))

    case Client.get("/api/loop/analyze", params) do
      {:ok, %{"markdown" => markdown} = envelope} -> emit(markdown, envelope, mode)
      {:ok, other} -> Output.die("unexpected response: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp emit(_markdown, envelope, :json), do: IO.puts(Jason.encode!(envelope))
  defp emit(markdown, _envelope, :text), do: IO.puts(markdown)

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)
end
