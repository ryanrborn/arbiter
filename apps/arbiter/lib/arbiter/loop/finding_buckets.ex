defmodule Arbiter.Loop.FindingBuckets do
  @moduledoc """
  The controlled vocabulary reviewer findings are matched against (bd-5ja2vb,
  `docs/design/loop-inference-discovery-pass.md` §2): a four-regex allowlist —
  **and, beside it, the category → skill attribution table** those categories
  resolve through (bd-5w8h0r).

  Shared by `Arbiter.Loop.Analysis` (which clusters the bucketed side into
  `finding_categories`) and `Arbiter.Loop.Corpus` (which counts and retains the
  **residue** — the units that match none of these regexes, previously dropped
  uncounted by `Enum.reject(&is_nil/1)`). Pulling the allowlist out to its own
  module is what lets both sides share one definition instead of drifting.

  Growing this list is out of scope for bd-5ja2vb — only its residue is now
  counted instead of silently discarded.

  ## The attribution table

  Category → skill attribution reads like an open relation to be discovered. It
  is not: it is a five-row table over a closed set (`categories/0`), and it
  lives here, in the same module as the regexes that produce those categories,
  so the two cannot drift. A bucket added without an attribution row **fails to
  compile** — see the guard at the bottom of this module — so an unhomed
  category can never ship an empty clause.

  Each row carries three things:

    * `:kind` — `:skill_patch` when an existing fleet skill governs the
      category, `:skill_create` when none does. Routing the unhomed categories
      to `:skill_create` is the correct answer, not a fallback: that kind has
      full payload support and forces `managed_by: :loop`, whereas a
      `:skill_patch` naming a nonexistent skill fails with `no skill named …`
      forever.
    * `:skill` — the target skill's name. This is the proposal's `target`.
    * `:imperative` — the one sentence that cannot be derived from the
      evidence. Everything else in a rendered clause (heading, evidence,
      verbatim citation, provenance) comes off the candidate;
      *"confirm every new branch has a test that fails without the change"*
      does not. Five categories, five sentences, written once, in code, by a
      human — which is the entire thing an LLM pass inside `Loop` would have
      bought (`docs/design/loop-payload-authoring.md` §3).

  ## This table is fingerprint-load-bearing

  `target` is an input to `Arbiter.Loop.fingerprint/1` (the digest is
  `{kind, target, category, difficulty, repo}`). Changing a row's `:kind` or
  `:skill` therefore changes the digest of every proposal in that category, and
  a naive edit inserts a fresh row beside the live one — which keeps the
  accumulated evidence and is never reinforced again.

  **Editing this table is a schema-shaped change, not a copy edit.** It needs a
  supersede/backfill step in the same release, of the shape
  `Arbiter.Loop.PendingWriteTargetBackfill` performs. `:imperative` is *not* a
  fingerprint input and may be reworded freely.

  A consequence of the same rule, worth stating before it surprises someone:
  once the loop has actually created one of the two `:skill_create` skills, a
  later window's row for that category is *still* `:skill_create` and will fail
  on the unique-name constraint. Moving that row to `:skill_patch` is itself a
  fingerprint change, so it takes the same supersede/backfill step. That is the
  documented operational rule rather than silent behaviour: the alternative —
  deciding the kind at apply time from whether the skill happens to exist —
  would make the fingerprint depend on mutable state outside the table.

  ## Skills are global today

  All fleet skills carry `workspace_id: nil`, and this table is not
  workspace-aware: `:skill` names a global skill. A per-workspace skill of the
  same name (`Arbiter.Skills.resolve_skill/2` shadowing) would make the target
  ambiguous — the proposal would name one string and two skills could answer to
  it. Out of scope here, and deliberately not assumed away: if workspace-scoped
  skills start being used for these names, this table needs a workspace
  dimension before the attribution means anything.
  """

  alias Arbiter.Loop.SkillClause

  @finding_buckets [
    {~r/inert|never (?:executed|called|invoked|run|wired)|not (?:wired|reachable)|green tests? but|passes? but .*runtime/i,
     "plausible code, green tests, inert at runtime"},
    {~r/no test|missing test|untested|test coverage|without a test/i, "missing test coverage"},
    {~r/secret|credential|token leaked/i, "secret / credential exposure"},
    {~r/regression|breaks? existing|broke /i, "regression in existing behaviour"}
  ]

  # Not a regex bucket: this category is produced by `Analysis`'s
  # `from_context` branch, from a run's own failure subcategory
  # (`:context_exhaustion`), not from reviewer prose. It is defined here so the
  # analyser and the attribution table cannot disagree about its exact text —
  # which they would, silently, the first time either was reworded, since the
  # table is keyed on it.
  @context_exhaustion_category "context exhaustion — agent burned its own context window (no read discipline)"

  @attribution %{
    "plausible code, green tests, inert at runtime" => %{
      kind: :skill_patch,
      skill: "verification-before-completion",
      imperative:
        "Before you report a change as done, run the code path you changed and " <>
          "paste the output you observed — a green test suite is not evidence " <>
          "that the new path executed."
    },
    "missing test coverage" => %{
      kind: :skill_patch,
      skill: "test-driven-development",
      imperative:
        "Before requesting review, confirm every new branch has a test that " <>
          "fails without the change — write it first and watch it fail, so you " <>
          "know it is testing the change and not passing by accident."
    },
    "regression in existing behaviour" => %{
      kind: :skill_patch,
      skill: "test-driven-development",
      imperative:
        "Before requesting review, re-run the existing tests that cover the " <>
          "code you touched, and name them in your test plan — the behaviour " <>
          "you did not intend to change is the behaviour nobody is watching."
    },
    "secret / credential exposure" => %{
      kind: :skill_create,
      skill: "credential-hygiene",
      imperative:
        "Never write a credential, token, key or connection string into source, " <>
          "config, a fixture or a log line — read it from the environment at the " <>
          "point of use, and grep your own diff for literals before requesting review."
    },
    @context_exhaustion_category => %{
      kind: :skill_create,
      skill: "context-budget-discipline",
      imperative:
        "Locate what you need with grep or a symbol search and read a bounded " <>
          "range around it — never read a large file whole to find one " <>
          "definition, and pipe large command output to a file you can slice."
    }
  }

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

  @doc """
  The exact category text `Arbiter.Loop.Analysis` emits for a context-exhaustion
  death. Not a regex bucket — see the module attribute's comment.
  """
  @spec context_exhaustion_category() :: String.t()
  def context_exhaustion_category, do: @context_exhaustion_category

  @doc """
  Every category the analyser can emit: the four regex buckets plus context
  exhaustion. A closed set of five, sorted for stable output.
  """
  @spec categories() :: [String.t()]
  def categories, do: Enum.sort(Map.keys(@attribution))

  @doc """
  The attribution row for `category` — `%{kind:, skill:, imperative:}` — or
  `nil` for a string no bucket produces.

  `nil` is reachable only from hand-built or historical input: every category
  in `categories/0` is guaranteed a row at compile time. Callers treat it as
  "leave this candidate unattributed" rather than guessing a target.
  """
  @spec attribution(String.t() | nil) ::
          %{kind: atom(), skill: String.t(), imperative: String.t()} | nil
  def attribution(category) when is_binary(category), do: Map.get(@attribution, category)
  def attribution(_), do: nil

  @doc """
  The marker slug `category`'s clause is keyed by in a skill body — the stable
  identity that makes a later window replace its own clause instead of
  appending a copy.
  """
  @spec clause_id(String.t()) :: String.t()
  def clause_id(category) when is_binary(category), do: SkillClause.slug(category)

  # ---- compile-time totality guard ----------------------------------------
  #
  # The whole point of keeping the table next to the regexes is that neither
  # can move without the other. These raise at compile time rather than
  # deferring to a test, so a new bucket cannot reach `main` (or a dev's own
  # `iex`) with no target and no imperative — which would ship a proposal
  # carrying an empty clause.

  bucket_categories = Enum.map(@finding_buckets, fn {_re, cat} -> cat end)
  attributed = Map.keys(@attribution)
  known = [@context_exhaustion_category | bucket_categories]

  case Enum.reject(known, &(&1 in attributed)) do
    [] ->
      :ok

    missing ->
      raise CompileError,
        description:
          "Arbiter.Loop.FindingBuckets: these finding categories have no attribution row: " <>
            "#{inspect(missing)}. Every category the analyser can emit must resolve to a " <>
            "target skill (or to :skill_create) with an imperative sentence — see the " <>
            "moduledoc. Adding one changes the fingerprint of that category's proposals; " <>
            "ship the supersede/backfill with it."
  end

  case Enum.reject(attributed, &(&1 in known)) do
    [] ->
      :ok

    orphans ->
      raise CompileError,
        description:
          "Arbiter.Loop.FindingBuckets: these attribution rows match no finding category " <>
            "the analyser can emit: #{inspect(orphans)}. Delete them, or fix the bucket " <>
            "regex / context-exhaustion category text they were meant to key on."
  end
end
