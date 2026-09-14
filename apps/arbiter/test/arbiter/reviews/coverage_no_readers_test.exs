defmodule Arbiter.Reviews.CoverageNoReadersTest do
  @moduledoc """
  Acceptance 5 of bd-203cl5 (#1648), narrowed by P3 (bd-b0fqcl / #1649).

  P1 wired the **writers** of `review_coverage` and nothing else. P3 adds
  exactly one reader — `Arbiter.Reviews.CoverageShadow`, which computes
  `Coverage.decide/3` *beside* the existing guard and only counts and logs the
  result. `issues.last_reviewed_sha` is still the authoritative input to every
  merge decision; the read-path flip is P4, behind `merge.coverage_enabled`.

  So the scan below still runs, with the shadow as its one new exemption: the
  Watchdog and the MergeQueue may reach coverage only *through* the shadow, and
  neither may call the predicate — or touch the `Entry` resource — itself.
  That is what keeps "shadow mode" an honest description of what shipped
  rather than a claim in a PR body.

  This is a source scan rather than a prose promise: a reader added by a later
  phase without also landing the predicate fails here, which is exactly the
  "guard-begets-guard" drift the design doc's §5 enforcement exists to stop.
  Comments are stripped before scanning, so documenting what P4 will add is
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
  #   * `reviews/coverage_shadow.ex` — P3's single reader. It calls the
  #     predicate and names the `Entry` type in its own typespecs, but acts on
  #     nothing: `observe/1` returns `:ok` for every input.
  @exempt [
    "arbiter/reviews/coverage.ex",
    "arbiter/reviews/coverage/entry.ex",
    "arbiter/reviews/coverage_shadow.ex",
    "arbiter/reviews.ex"
  ]

  @sites [
    "arbiter/worker/review_gate.ex",
    "arbiter/workflows/review_patrol.ex",
    "arbiter/reviews/external_review.ex"
  ]

  # P3's two adopters (§3.4).
  @merge_paths [
    "arbiter/worker/watchdog.ex",
    "arbiter/workflows/merge_queue.ex"
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

  test "no module outside the shadow calls the coverage predicate" do
    assert offenders(~r/Coverage\.decide/) == [],
           "only `Arbiter.Reviews.CoverageShadow` may call `Coverage.decide/3` " <>
             "or `decide_with_record/3` until P4 flips the read path."
  end

  test "no module outside the writer and the shadow touches the Coverage.Entry resource" do
    assert offenders(~r/Coverage\.Entry/) == [],
           "Only Arbiter.Reviews.Coverage may touch the Entry resource."
  end

  test "the three P1 sites do call the writer, so the scan above is not vacuous" do
    sources = Map.new(lib_sources())

    for path <- @sites do
      assert Map.fetch!(sources, path) =~ "Coverage.record",
             "#{path} must write coverage (§3.3)"
    end
  end

  test "both merge paths reach coverage through the shadow, so the exemption is not vacuous" do
    sources = Map.new(lib_sources())

    for path <- @merge_paths do
      assert code_only(Map.fetch!(sources, path)) =~ "CoverageShadow.observe(",
             "#{path} must evaluate the coverage predicate in shadow mode (§3.4)"
    end
  end
end
