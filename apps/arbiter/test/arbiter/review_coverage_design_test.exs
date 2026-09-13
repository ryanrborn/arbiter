defmodule Arbiter.ReviewCoverageDesignTest do
  @moduledoc """
  Keeps the review-coverage design doc's guard inventory honest (bd-6woz0x).

  The doc's whole value is an inventory of every guard in the review/merge
  control plane, each pinned to a `file:line`. Line numbers rot the moment
  anyone edits `watchdog.ex` — and a rotted inventory is worse than none,
  because the next person patches the guard the doc did not actually point at.

  So every citation in the doc is written in a machine-checkable form:

      `apps/arbiter/lib/arbiter/worker/watchdog.ex:2917` (`resolve_stale_reviewed_head`)

  a backticked repo-relative `path:line`, immediately followed by a backticked
  symbol in parentheses. This test re-reads each cited file and asserts the
  symbol still appears near the cited line. Prose may cite a file however it
  likes; only the `path:line` + `(symbol)` pairing is checked.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @doc_path Path.join(@repo_root, "docs/review-coverage-and-guard-policy.md")

  # How far a cited line may drift from its symbol before the citation counts
  # as stale. Generous enough to survive an unrelated edit inside the same
  # function, tight enough that a guard moving to a different part of the file
  # (or being deleted outright) fails.
  @drift 60

  # `path:line` in backticks, then `(`symbol`)`.
  @citation ~r/`(apps\/[^`\s:]+\.ex):(\d+)`\s*\(`([A-Za-z0-9_?!.\/]+)`\)/

  setup_all do
    assert File.exists?(@doc_path),
           "expected the review-coverage design doc at docs/review-coverage-and-guard-policy.md"

    {:ok, doc: File.read!(@doc_path)}
  end

  test "the doc cites the control-plane files the inventory must cover", %{doc: doc} do
    for file <- [
          "apps/arbiter/lib/arbiter/worker/review_gate.ex",
          "apps/arbiter/lib/arbiter/worker/watchdog.ex",
          "apps/arbiter/lib/arbiter/workflows/merge_queue.ex",
          "apps/arbiter/lib/arbiter/workflows/review_patrol.ex",
          "apps/arbiter/lib/arbiter/workflows/pr_patrol.ex",
          "apps/arbiter/lib/arbiter/mergers/reviewed_sha.ex"
        ] do
      assert doc =~ file,
             "the guard inventory does not mention #{file} — AC2 requires every guard/refusal " <>
               "path in the review/merge control plane"
    end
  end

  test "every anchored citation still resolves to its symbol", %{doc: doc} do
    citations = Regex.scan(@citation, doc)

    assert length(citations) >= 25,
           "expected the inventory to carry at least 25 anchored `file:line` (`symbol`) " <>
             "citations, found #{length(citations)}"

    stale =
      for [_, path, line, symbol] <- citations,
          problem = citation_problem(path, String.to_integer(line), symbol),
          do: "#{path}:#{line} (#{symbol}) — #{problem}"

    assert stale == [],
           "stale citations in docs/review-coverage-and-guard-policy.md; re-anchor them " <>
             "against the current source:\n  " <> Enum.join(stale, "\n  ")
  end

  defp citation_problem(path, line, symbol) do
    full = Path.join(@repo_root, path)

    cond do
      not File.exists?(full) ->
        "file does not exist"

      true ->
        lines = full |> File.read!() |> String.split("\n")

        if line > length(lines) do
          "line #{line} is past end of file (#{length(lines)} lines)"
        else
          window =
            lines
            |> Enum.slice(max(line - 1 - @drift, 0), 2 * @drift + 1)
            |> Enum.join("\n")

          unless String.contains?(window, symbol) do
            "#{symbol} not found within ±#{@drift} lines"
          end
        end
    end
  end
end
