defmodule Arbiter.CircuitBreaker.Signature do
  @moduledoc """
  Signature keying for `Arbiter.CircuitBreaker` (bd-5jr49o).

  A breaker is keyed by **workspace + kind + normalised subject**. The whole
  value of a generic breaker rests on that normalisation being right in both
  directions:

    * too loose and it suppresses genuinely distinct alerts — two different PRs
      collapsing into one signature means the second PR silently never gets a
      follow-up;
    * too tight and it dedupes nothing — the flood that motivated this work
      (bd-6bg54c's 303 Watchdog retries, bd-8lnnnt's 14 identical pre-flight
      escalations in 75 minutes) carried an attempt counter or a timestamp in
      every message, so a naive "same string" key never matched twice.

  The rule is therefore: **strip what varies per occurrence, keep what
  identifies the subject.**

  ## Stripped (volatile)

  | Shape | Placeholder |
  |---|---|
  | UUIDs | `<uuid>` |
  | ISO-8601 timestamps (`T` or space separated) | `<ts>` |
  | Standalone hex runs of 7–40 chars (commit SHAs) | `<sha>` |
  | A number immediately followed by a time unit (`ms`/`s`/`m`/`h`/`d`) | `<dur>` |
  | Any other bare number (counts, attempt numbers, poll counts) | `<n>` |

  ## Kept (identifying)

    * Forge refs — a number preceded by `#` or `!` (`repo/x#3282`, `!77`) is
      never touched, which is what keeps two different PRs from colliding.
    * Slug-embedded numbers — a digit preceded by a word character or `-`
      (`bd-7rxwzc`, `verus_server2`) is part of an identifier, not a count.
    * All non-numeric words: repo slugs, task ids, block reasons.

  ## Structured subjects

  A subject may be a list (or tuple) of components instead of one string,
  joined with ` :: `.
  Non-binary components — integers, atoms, `nil` — are **stable**: they are
  rendered verbatim and never scrubbed. That is the escape hatch for a subject
  whose identity IS a number:

      Signature.signature(ws, :pr_patrol_follow_up, ["leo/verus_server", 3282])

  keeps `3282` intact regardless of the free-text rules, while any binary
  component in the same list still goes through the scrubber. Component order
  is significant.
  """

  # Placeholder-substitution table, applied in order. UUIDs and timestamps must
  # run before the SHA rule (their segments are hex), and every specific rule
  # must run before the bare-number rules, which are the catch-all.
  @uuid ~r/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/
  @timestamp ~r/\d{4}-\d{2}-\d{2}[t ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:z|[+-]\d{2}:?\d{2})?/
  @sha ~r/(?<![\w#!-])[0-9a-f]{7,40}(?![\w-])/
  @duration ~r/(?<![\w#!.-])\d+(?:\.\d+)?\s?(?:ms|s|m|h|d)(?![\w-])/
  @decimal ~r/(?<![\w#!.-])\d+\.\d+(?![\w-])/
  @integer ~r/(?<![\w#!.-])\d+(?![\w-])/
  @whitespace ~r/\s+/
  # Reserved for the structured-subject separator — see `@component_sep`.
  @repeated_colon ~r/:{2,}/

  # Components of a structured subject are joined on ` :: `. It has to be
  # printable: the whole signature is quoted verbatim in the trip escalation
  # and in `arb breaker list`, and an operator copies that line into a shell to
  # reset the breaker — a control byte is invisible in a terminal and does not
  # survive selection/paste (round 2, finding 2). Injectivity is preserved by
  # collapsing any run of colons inside a normalised component (see `scrub/1`),
  # so the separator provably cannot occur inside a component and `["a", "b::c"]`
  # can never be confused with `["a::b", "c"]`. (Signatures already contain
  # spaces — normalised free text keeps them — so the surrounding spaces cost
  # nothing: every printed signature is quoted either way.)
  @component_sep " :: "

  # How much normalised subject text survives into the readable part of a
  # signature. Anything longer is truncated and disambiguated with a digest of
  # the full value, so a 5 KB subject stays discriminating without making the
  # key (which appears verbatim in the trip escalation) unreadable.
  @max_subject_bytes 200

  @doc """
  The full breaker key: `"<workspace>|<kind>|<normalised subject>"`.

  Deliberately human-readable rather than an opaque hash — the trip escalation
  quotes it, and `arb breaker list` prints it, so an operator has to be able to
  tell at a glance which flood was stopped. A `nil` workspace is rendered as
  `-`, and is its own scope (it never shares a key with a real workspace).
  """
  @spec signature(String.t() | nil, atom() | String.t(), term()) :: String.t()
  def signature(workspace_id, kind, subject) do
    ws = workspace_id || "-"
    "#{ws}|#{kind}|#{truncate(normalize_subject(subject))}"
  end

  @doc """
  Normalise a subject to its deduplication form. See the module doc for the
  rules; `signature/3` is the usual entry point, this is exposed for tests and
  for callers that want to log what a subject collapsed to.
  """
  @spec normalize_subject(term()) :: String.t()
  def normalize_subject(subject) when is_list(subject),
    do: Enum.map_join(subject, @component_sep, &component/1)

  def normalize_subject(subject) when is_tuple(subject),
    do: subject |> Tuple.to_list() |> normalize_subject()

  def normalize_subject(subject), do: component(subject)

  # A binary component is free text and gets scrubbed. Everything else —
  # integer, atom, nil, or any other term — is a stable identifier supplied by
  # the caller and is rendered verbatim.
  defp component(text) when is_binary(text), do: scrub(text)
  defp component(other), do: inspect(other)

  defp scrub(text) do
    text
    |> String.downcase()
    |> String.replace(@uuid, "<uuid>")
    |> String.replace(@timestamp, "<ts>")
    |> String.replace(@sha, "<sha>")
    |> String.replace(@duration, "<dur>")
    |> String.replace(@decimal, "<n>")
    |> String.replace(@integer, "<n>")
    |> String.replace(@whitespace, " ")
    |> String.replace(@repeated_colon, ":")
    |> String.trim()
  end

  defp truncate(subject) when byte_size(subject) <= @max_subject_bytes, do: subject

  defp truncate(subject) do
    digest = :crypto.hash(:sha256, subject) |> Base.encode16(case: :lower) |> binary_part(0, 12)
    # String.slice/3 (not binary_part/3) so truncation can never split a UTF-8
    # codepoint — subjects routinely carry an em dash.
    String.slice(subject, 0, @max_subject_bytes) <> "…~" <> digest
  end
end
