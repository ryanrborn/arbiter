defmodule ArbiterCli.Cmd.PreflipGate do
  @moduledoc """
  `arb preflip-gate` — is §6.3's rollout gate clear to flip
  `merge.coverage_enabled`?

  Runs `Arbiter.Reviews.CoverageShadow.preflip_gate/0` against the running
  install's own database (bd-cy2mmu: previously this function had no caller
  outside its own tests — the operator had to hand-run it via `iex -S mix`).

  Reports the merge count, disagreements broken down by `old->new` transition
  (blocking vs. the one documented `covered->uncovered` fix_pass exception —
  see `Arbiter.Reviews.CoverageShadow.deferred_reasons/0`), and the pass/fail
  verdict with its reason.

  A "merge" is one distinct durable `coverage_shadow` observation (deduped by
  `{site, mr_ref, head, old, new}` at write time) where the old guard both
  merged (`old = "covered"`) and was still authoritative.

  The gate itself does not filter by a fix-boundary timestamp — it reads the
  whole topic — so every listed disagreement carries `occurred_at`. That is
  how an operator sees whether blocking disagreements predate a since-landed
  fix rather than waiting on `Arbiter.Events.Retention` to age the old rows
  out.

  Usage:

      arb preflip-gate [--json]

  Reads from `GET /api/coverage_shadow/preflip_gate`.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      mode = Output.mode(argv)

      case Client.get("/api/coverage_shadow/preflip_gate", []) do
        {:ok, %{"data" => data}} -> emit(data, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp emit(data, :json), do: IO.puts(Jason.encode!(data))

  defp emit(data, :text) do
    verdict = if data["pass?"], do: "PASS", else: "FAIL"

    IO.puts("preflip gate: #{verdict}")
    IO.puts("  #{data["reason"]}")
    IO.puts("")
    IO.puts("  merges: #{data["merges"]} (min #{data["min_merges"]})")
    IO.puts("  agreements: #{data["agreements"]}")
    IO.puts("  truncated: #{data["truncated?"]}")

    emit_transitions("blocking", data["blocking"], data["blocking_observations"])
    emit_transitions("deferred", data["deferred"], data["deferred_observations"])
  end

  defp emit_transitions(_label, counts, _observations) when counts in [%{}, nil], do: :ok

  defp emit_transitions(label, counts, observations) do
    IO.puts("")
    IO.puts("  #{label}:")

    for {transition, count} <- counts do
      IO.puts("    #{transition}: #{count}")
    end

    for obs <- observations || [] do
      IO.puts(
        "    - #{obs["occurred_at"]} #{obs["old"]}->#{obs["new"]} " <>
          "site=#{obs["site"]} task=#{obs["task_id"]} mr=#{obs["mr_ref"]} head=#{obs["head"]}"
      )
    end
  end
end
