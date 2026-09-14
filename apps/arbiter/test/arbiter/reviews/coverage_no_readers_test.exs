defmodule Arbiter.Reviews.CoverageNoReadersTest do
  @moduledoc """
  Acceptance 5 of bd-203cl5 (#1648): P1 wires the **writers** of
  `review_coverage` and nothing else. No module may read the table for a
  decision yet — `Coverage.decide/3` (§3.2) exists as of P2 (#1665) but has no
  call site, and the guard rewrites that consume it are P3/P4. Until they land
  `issues.last_reviewed_sha` remains the authoritative input to every merge
  guard.

  This is a source scan rather than a prose promise: a reader added by a later
  phase without also landing the predicate fails here, which is exactly the
  "guard-begets-guard" drift the design doc's §5 enforcement exists to stop.
  Comments are stripped before scanning, so documenting what P3/P4 will add is
  still allowed — only real call sites count.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)

  # Exempt, and why:
  #   * `coverage.ex` — the single writer. `record/1` reads back the
  #     `{mr_ref, head_sha, kind}` row to stay idempotent; that is bookkeeping
  #     internal to the writer, not a consumer making a decision.
  #   * `coverage/entry.ex` — the resource module itself.
  #   * `reviews.ex` — the Ash domain, which must name every resource it owns.
  @exempt [
    "arbiter/reviews/coverage.ex",
    "arbiter/reviews/coverage/entry.ex",
    "arbiter/reviews.ex"
  ]

  @sites [
    "arbiter/worker/review_gate.ex",
    "arbiter/workflows/review_patrol.ex",
    "arbiter/reviews/external_review.ex"
  ]

  defp lib_sources do
    exempt = MapSet.new(@exempt)

    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&{Path.relative_to(&1, @lib_root), File.read!(&1)})
    |> Enum.reject(fn {rel, _source} -> MapSet.member?(exempt, rel) end)
  end

  # Drop `#` comments so a moduledoc/inline note about the P3/P4 reader is not
  # mistaken for the reader. Crude but sufficient: `#` inside a string literal
  # would only ever produce a false POSITIVE here, never a false negative.
  defp code_only(source) do
    source
    |> String.split("\n")
    |> Enum.map(&Regex.replace(~r/#.*$/, &1, ""))
    |> Enum.join("\n")
  end

  defp offenders(pattern) do
    for {rel, source} <- lib_sources(),
        code_only(source) =~ pattern,
        do: rel
  end

  test "no module calls Coverage.decide/3" do
    assert offenders(~r/Coverage\.decide\(/) == [],
           "P3/P4 owns `Coverage.decide/3`; P1 writes only."
  end

  test "no module outside the writer touches the Coverage.Entry resource" do
    assert offenders(~r/Coverage\.Entry/) == [],
           "Only Arbiter.Reviews.Coverage may touch the Entry resource in P1."
  end

  test "the three P1 sites do call the writer, so the scan above is not vacuous" do
    sources = Map.new(lib_sources())

    for path <- @sites do
      assert Map.fetch!(sources, path) =~ "Coverage.record",
             "#{path} must write coverage (§3.3)"
    end
  end
end
