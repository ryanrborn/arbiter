defmodule Arbiter.Loop.FindingBuckets do
  @moduledoc """
  The controlled vocabulary reviewer findings are matched against (bd-5ja2vb,
  `docs/design/loop-inference-discovery-pass.md` §2): a four-regex allowlist.

  Shared by `Arbiter.Loop.Analysis` (which clusters the bucketed side into
  `finding_categories`) and `Arbiter.Loop.Corpus` (which counts and retains the
  **residue** — the units that match none of these regexes, previously dropped
  uncounted by `Enum.reject(&is_nil/1)`). Pulling the allowlist out to its own
  module is what lets both sides share one definition instead of drifting.

  Growing this list is out of scope for bd-5ja2vb — only its residue is now
  counted instead of silently discarded.
  """

  @finding_buckets [
    {~r/inert|never (?:executed|called|invoked|run|wired)|not (?:wired|reachable)|green tests? but|passes? but .*runtime/i,
     "plausible code, green tests, inert at runtime"},
    {~r/no test|missing test|untested|test coverage|without a test/i, "missing test coverage"},
    {~r/secret|credential|token leaked/i, "secret / credential exposure"},
    {~r/regression|breaks? existing|broke /i, "regression in existing behaviour"}
  ]

  @doc """
  Match `text` against the bucket allowlist, first match wins. Returns
  `{category, text}`, or `nil` when no bucket matches — that `nil` is the
  finding residue.
  """
  @spec bucket_finding(String.t()) :: {String.t(), String.t()} | nil
  def bucket_finding(text) when is_binary(text) do
    Enum.find_value(@finding_buckets, fn {re, cat} ->
      if Regex.match?(re, text), do: {cat, text}
    end)
  end
end
