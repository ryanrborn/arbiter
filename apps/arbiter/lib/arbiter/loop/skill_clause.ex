defmodule Arbiter.Loop.SkillClause do
  @moduledoc """
  Deterministic rendering of one reviewer-finding category into a **marked
  skill clause**, and the in-place upsert of that clause into a skill body
  (bd-5w8h0r).

  This is the "(b)" half of the `bd-4xc69o` decision record
  (`docs/design/loop-payload-authoring.md` §3): a `:skill_patch` proposal that
  names a target but carries no content is still "advice a human must
  hand-apply". Everything a clause needs is already on the candidate —
  category, a verbatim `example` finding, the incident and task counts, the
  window — except the imperative sentence, which is a per-category constant in
  `Arbiter.Loop.FindingBuckets`. No model is involved at any point.

  ## Markers, and why a clause replaces itself

  A skill body is edited by humans and, now, by the loop. The same discipline
  `Arbiter.Loop.RepoDocPatch` applies to a repo `CLAUDE.md` applies here:
  the loop owns exactly the span between

      <!-- arbiter:loop:begin <slug> -->
      <!-- arbiter:loop:end <slug> -->

  and copies everything outside it through untouched. The slug is derived from
  the category, so a later window over the same finding **replaces its own
  clause** instead of appending a second copy — which is the difference between
  a skill that stays readable and one that accumulates a paragraph a week.

  Unlike `RepoDocPatch`, which packs many single-line lessons into one managed
  section under a byte cap, each category owns its own marker pair: a clause is
  a multi-line markdown block, and the categories are a closed set of five, so
  there is nothing to evict.

  ## The verbatim citation is untrusted text

  `example` is a reviewer's own words, copied through. `sanitize/1` collapses
  it to one line and strips comment delimiters and marker prefixes, so a
  finding that happens to quote `<!-- arbiter:loop:end … -->` cannot close the
  section it is being rendered inside.
  """

  @begin_prefix "<!-- arbiter:loop:begin "
  @end_prefix "<!-- arbiter:loop:end "
  @marker_suffix " -->"

  # A verbatim reviewer finding is quoted whole; a pathological one is elided
  # rather than allowed to dominate every future dispatch's prompt.
  @example_limit 240

  # Enough of the digest to identify the row by eye against `arb loop pending`,
  # short enough not to dominate the line.
  @fingerprint_prefix 12

  @type clause_input :: %{
          required(:category) => String.t(),
          required(:imperative) => String.t(),
          optional(:example) => String.t() | nil,
          optional(:incidents) => non_neg_integer(),
          optional(:tasks) => [String.t()],
          optional(:fingerprint) => String.t() | nil,
          optional(:window_until) => DateTime.t() | Date.t() | nil
        }

  @doc "The literal marker that opens `slug`'s clause."
  @spec begin_marker(String.t()) :: String.t()
  def begin_marker(slug), do: @begin_prefix <> slug <> @marker_suffix

  @doc "The literal marker that closes `slug`'s clause."
  @spec end_marker(String.t()) :: String.t()
  def end_marker(slug), do: @end_prefix <> slug <> @marker_suffix

  @doc """
  The stable marker key for `category`: its head segment, kebab-cased.

  The gloss after an em-dash (the context-exhaustion category carries one) is
  dropped so the key stays short and stable; the full category text still
  appears in the rendered evidence sentence.
  """
  @spec slug(String.t()) :: String.t()
  def slug(category) when is_binary(category) do
    category
    |> head()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc """
  Render `input` as a complete clause, markers included.

  Pure and total: the same inputs always render byte-identical output, which is
  what makes two consecutive passes over one window produce one clause rather
  than two.
  """
  @spec render(clause_input()) :: String.t()
  def render(%{category: category, imperative: imperative} = input) do
    slug = slug(category)
    incidents = Map.get(input, :incidents) || 0
    tasks = Map.get(input, :tasks) || []

    [
      begin_marker(slug),
      "## #{heading(category)}",
      "",
      evidence(category, incidents, tasks, Map.get(input, :example)),
      "",
      String.trim(imperative),
      "",
      provenance(Map.get(input, :fingerprint), incidents, tasks, Map.get(input, :window_until)),
      end_marker(slug)
    ]
    |> Enum.join("\n")
  end

  @doc """
  Return `body` with `slug`'s clause replaced in place, or appended when the
  body carries none yet. `nil` body is treated as empty (a skill about to be
  created).

  Re-upserting an unchanged clause is byte-idempotent.
  """
  @spec upsert(String.t() | nil, String.t(), String.t()) :: String.t()
  def upsert(body, slug, clause) when is_binary(slug) and is_binary(clause) do
    body = body || ""
    opening = begin_marker(slug)
    closing = end_marker(slug)

    with [before, rest] <- String.split(body, opening, parts: 2),
         [_replaced, after_] <- String.split(rest, closing, parts: 2) do
      join(before, clause, after_)
    else
      _ -> join(body, clause, "")
    end
  end

  @doc """
  The body for a skill the loop is creating from scratch: a short preamble
  naming the loop as its author and warning that the marked clauses are
  rewritten, followed by `clause`.

  A `:skill_create` row exists precisely because no fleet skill governs the
  category (`FindingBuckets.attribution/1`), so there is no human-authored body
  to patch — this is the honest minimum that still applies cleanly and carries
  its evidence.
  """
  @spec stub_body(String.t(), String.t()) :: String.t()
  def stub_body(name, clause) when is_binary(name) and is_binary(clause) do
    preamble =
      """
      # #{name}

      Authored by the arbiter loop from recurring reviewer findings, and managed
      by it (`managed_by: :loop`). Each clause below is bounded by
      `arbiter:loop:begin` / `arbiter:loop:end` markers and is rewritten in place
      when its finding recurs — edit outside the markers, not inside them.
      """
      |> String.trim_trailing()

    join(preamble, clause, "")
  end

  # ---- rendering pieces ----------------------------------------------------

  defp heading(category) do
    category |> head() |> upcase_first()
  end

  defp head(category) do
    category |> String.split(~r/\s+[—–-]\s+/u, parts: 2) |> hd() |> String.trim()
  end

  defp upcase_first(""), do: ""
  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp evidence(category, incidents, tasks, example) do
    quoted = ~s("#{sanitize(category)}")

    [
      "Reviewers raised this in #{plural(incidents, "incident")} across " <>
        "#{plural(length(tasks), "distinct task")} this window, under " <>
        quoted <> ".",
      citation(tasks, example)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # No example (or no task to attribute it to) means no citation sentence —
  # a quotation with nothing to quote reads as padding.
  defp citation([task | _], example) when is_binary(example) do
    case sanitize(example) do
      "" -> nil
      text -> ~s(e.g. #{task}: "#{text}".)
    end
  end

  defp citation(_tasks, _example), do: nil

  defp provenance(fingerprint, incidents, tasks, window_until) do
    parts =
      [
        "authored by the arbiter loop",
        fingerprint_ref(fingerprint),
        "#{plural(incidents, "incident")} / #{plural(length(tasks), "distinct task")}",
        window_ref(window_until)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    "<!-- #{parts} -->"
  end

  # The pending-write id does not exist yet when the payload is authored (the
  # row is inserted from it), so the provenance cites the *fingerprint* — the
  # stable cross-window identity of the finding, and the same digest
  # `arb loop pending` shows. `loop:proposal:<id>` still lands on the skill's
  # paper-trail version, via `Arbiter.Loop.Apply.attribution/1`.
  defp fingerprint_ref(fp) when is_binary(fp) and fp != "",
    do: "finding #{String.slice(fp, 0, @fingerprint_prefix)}"

  defp fingerprint_ref(_), do: nil

  defp window_ref(%DateTime{} = dt), do: window_ref(DateTime.to_date(dt))
  defp window_ref(%Date{} = d), do: "window ending #{Date.to_iso8601(d)}"
  defp window_ref(_), do: nil

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"

  @doc """
  Collapse untrusted verbatim text to one safe line: no newlines, no HTML
  comment delimiters, no `arbiter:loop:` marker prefix, bounded length.

  Without this a reviewer finding that quoted a marker would close the clause
  it is rendered inside, and everything after it in the skill body would read
  as loop-owned.
  """
  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(nil), do: ""

  def sanitize(text) when is_binary(text) do
    text
    |> String.replace(~r/<!--|-->/, " ")
    |> String.replace("arbiter:loop:", "arbiter loop ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> elide()
  end

  defp elide(text) when byte_size(text) <= @example_limit, do: text
  defp elide(text), do: String.slice(text, 0, @example_limit - 1) <> "…"

  # ---- assembly ------------------------------------------------------------

  defp join(before, clause, after_) do
    [String.trim_trailing(before), clause, String.trim(after_)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end
end
