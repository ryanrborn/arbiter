defmodule Arbiter.Worker.ReviewFindings do
  @moduledoc """
  Finding identity and the per-round DISPOSITIONS protocol (bd-6r8caj / #1137).

  ## The hole this closes

  `Arbiter.Worker.ReviewGate` could return `VERDICT: APPROVE` /
  `VERIFICATION: FULL` on a revision round that never revisited the finding it
  itself raised in the previous round. Observed on `bd-8mtb0q` (#1132): round 1
  raised a Medium finding citing `failure_classifier.ex:172-185`, the implementer
  round produced an *empty* diff for that file (it only ran `mix format`), and
  round 2 approved with zero findings in 94.7s. Nothing in the gate could tell,
  because `review_gate_rounds.findings` is free prose — a finding had no identity
  that survived the round boundary, so "was finding X addressed?" was not a
  question the gate could ask, let alone answer.

  That failure mode is worse than the two already-known ones (a revising round
  that times out, a round with no parseable verdict): those fail loudly. This one
  succeeds loudly and wrongly, manufacturing unearned confidence — and with no CI
  on pull requests, ReviewGate is the only automated gate between a diff and
  `main`.

  ## What this module provides

    * **Identity** — `extract/2` turns a REQUEST_CHANGES round's prose findings
      into `%{id: "F<round>.<n>", severity:, files:, text:}` items. Ids are
      round-namespaced so round 2's findings can never collide with round 1's.
    * **Severity ranking** — `blocking?/1` is true for Medium-or-higher. A
      finding whose text carries no recognizable severity label ranks `:unknown`
      and is treated as blocking: this is a correctness gate, so an unlabelled
      finding fails closed rather than slipping through.
    * **Disposition parsing** — `dispositions/1` reads the `DISPOSITIONS:` block
      a round-N+1 reviewer must emit: one `[ADDRESSED]` / `[NOT ADDRESSED]` /
      `[OBSOLETE]` line per carried-forward finding id.
    * **The approval gap** — `approval_gap/3` is what makes `VERIFICATION: FULL`
      checkable. It returns the blocking findings that the approving round left
      `missing` (no disposition at all), `unaddressed` (explicitly
      `[NOT ADDRESSED]`), or `unproven` (claimed `[ADDRESSED]` while the
      implementer's diff never touched a cited file and the disposition names no
      alternative location — the mechanical backstop that would have caught
      bd-8mtb0q on its own).
    * **Prompt + persistence surfaces** — the blocks the re-review prompt renders,
      and the JSON encodings persisted onto `review_gate_rounds`.

  `[OBSOLETE]` is a first-class disposition on purpose: a finding invalidated by
  a different fix must be dispositionable, or the guard would dead-end
  legitimately stale findings.
  """

  # Severity vocabulary, ranked. The gate's threshold is Medium-or-higher, so
  # everything at rank >= @blocking_rank must be accounted for by an approving
  # round. `:unknown` deliberately sits AT the threshold: the reviewer prompt
  # requires a severity on every finding, so an unlabelled one is a malformed
  # finding, and a gate fails closed on malformed input.
  @severity_ranks %{
    critical: 5,
    blocker: 5,
    high: 4,
    major: 4,
    medium: 3,
    moderate: 3,
    unknown: 3,
    low: 2,
    minor: 2,
    nit: 1,
    nitpick: 1,
    trivial: 1,
    info: 1,
    informational: 1
  }

  @blocking_rank 3

  @severity_pattern ~r/\b(critical|blockers?|high|major|medium|moderate|low|minor|nitpick|nits?|trivial|informational|info)\b/i

  # A top-level enumerated item: `-`, `*`, or `1.`/`1)` at column 0..3. Deeper
  # indentation is a continuation line of the item above it, not a new finding —
  # a nested sub-bullet must not fragment one finding into several ids.
  @item ~r/^ {0,3}(?:[-*]|\d+[.)])\s+\S/

  # A file path token, optionally with `:line` / `:line-line`. Deliberately
  # requires a dotted extension of 1..6 letters so ordinary prose ("e.g.", "i.e.")
  # and bare identifiers do not read as paths — see `@path_stoplist`.
  @path ~r/((?:[\w.\-]+\/)*[\w\-]+\.[a-zA-Z]{1,6})(?::\d+(?:-\d+)?)?/
  @path_stoplist ~w(e.g i.e etc vs no.of)

  # A finding id as it appears in a DISPOSITIONS line.
  @id_pattern "F\\d+\\.\\d+"
  @status_pattern "ADDRESSED|NOT\\s+ADDRESSED|OBSOLETE|NO\\s+LONGER\\s+APPLICABLE"

  # Status-first (`- [ADDRESSED] F1.1 — …`) and id-first (`- F1.1 [ADDRESSED] …`)
  # forms are both accepted; reviewers reach for either. Each anchors the status
  # alternation to the opening `[`, so `[NOT ADDRESSED]` can never be mis-read as
  # `[ADDRESSED]` (the `A`-first branch fails on the leading `N`) — the same trick
  # `Arbiter.Worker.ReviewVerification` uses for `[NOT MET]`.
  @status_first Regex.compile!(
                  "^\\s*(?:[-*]|\\d+[.)])?\\s*\\[\\s*(#{@status_pattern})\\s*\\]\\s*[:\\-—]?\\s*(#{@id_pattern})\\b",
                  "im"
                )
  @id_first Regex.compile!(
              "^\\s*(?:[-*]|\\d+[.)])?\\s*(#{@id_pattern})\\s*[:\\-—]*\\s*\\[\\s*(#{@status_pattern})\\s*\\]",
              "im"
            )

  @type finding :: %{
          id: String.t(),
          round: pos_integer(),
          severity: atom(),
          files: [String.t()],
          text: String.t()
        }

  @type status :: :addressed | :not_addressed | :obsolete
  @type disposition :: %{status: status(), line: String.t()}
  @type gap :: %{missing: [finding()], unaddressed: [finding()], unproven: [finding()]}

  @doc """
  Extract the enumerated findings from a reviewer's findings text, assigning each
  a stable `F<round>.<n>` id.

  A findings body with no enumerated items but real prose collapses to a single
  fail-closed `:unknown`-severity finding: the round did raise *something*, and a
  later round must still account for it.
  """
  @spec extract(String.t() | nil, pos_integer()) :: [finding()]
  def extract(nil, _round), do: []

  def extract(findings, round) when is_binary(findings) and is_integer(round) do
    body = payload_lines(findings)

    body
    |> group_items()
    |> Enum.with_index(1)
    |> Enum.map(fn {text, n} ->
      %{
        id: "F#{round}.#{n}",
        round: round,
        severity: severity_of(text),
        files: files_in(text),
        text: String.trim(text)
      }
    end)
  end

  @doc "Whether a finding is Medium-or-higher (or unlabelled, which fails closed)."
  @spec blocking?(finding()) :: boolean()
  def blocking?(%{severity: severity}), do: rank(severity) >= @blocking_rank

  @doc "Numeric rank for a severity atom; unrecognized severities fail closed at Medium."
  @spec rank(atom()) :: pos_integer()
  def rank(severity), do: Map.get(@severity_ranks, severity, @blocking_rank)

  @doc """
  Parse the `DISPOSITIONS:` block out of a round's findings text into
  `%{finding_id => %{status: , line: }}`. Returns `%{}` when the round emitted no
  dispositions at all — which is precisely the bd-8mtb0q failure and what
  `approval_gap/3` reads back.
  """
  @spec dispositions(String.t() | nil) :: %{String.t() => disposition()}
  def dispositions(nil), do: %{}

  def dispositions(text) when is_binary(text) do
    lines = String.split(text, "\n")

    Enum.reduce(lines, %{}, fn line, acc ->
      case disposition_line(line) do
        {id, status} -> Map.put_new(acc, id, %{status: status, line: String.trim(line)})
        nil -> acc
      end
    end)
  end

  @doc """
  The gap between an approving round and the findings still open against it.

  `open` is the accumulated set of findings carried forward from prior rounds,
  `text` the approving round's own findings text, and `touched_files` a `MapSet`
  of repo-relative paths the implementer round(s) actually changed (`nil` when no
  worktree/git was available — the backstop then stays silent rather than
  guessing).

  Only blocking (Medium-or-higher) findings can produce a gap; a Low/Nit finding
  left undispositioned never blocks an approval.
  """
  @spec approval_gap([finding()], String.t() | nil, MapSet.t() | nil) :: gap()
  def approval_gap(open, text, touched_files) when is_list(open) do
    d = dispositions(text)
    blocking = Enum.filter(open, &blocking?/1)

    missing = Enum.reject(blocking, &Map.has_key?(d, &1.id))

    unaddressed =
      Enum.filter(blocking, fn f -> match?(%{status: :not_addressed}, Map.get(d, f.id)) end)

    unproven =
      Enum.filter(blocking, fn f ->
        match?(%{status: :addressed}, Map.get(d, f.id)) and
          unproven?(f, Map.fetch!(d, f.id), touched_files)
      end)

    %{missing: missing, unaddressed: unaddressed, unproven: unproven}
  end

  @doc "Whether an `approval_gap/3` result contains anything that must block an APPROVE."
  @spec gap?(gap()) :: boolean()
  def gap?(%{missing: m, unaddressed: u, unproven: p}), do: m != [] or u != [] or p != []

  @doc """
  Every finding named by a gap, de-duplicated and in id order — the set an
  approving round failed to account for.
  """
  @spec gap_findings(gap()) :: [finding()]
  def gap_findings(%{missing: m, unaddressed: u, unproven: p}) do
    (m ++ u ++ p) |> Enum.uniq_by(& &1.id) |> Enum.sort_by(& &1.id)
  end

  @doc """
  The findings that stay open into the next round: those the round left
  undispositioned, plus those it explicitly marked `[NOT ADDRESSED]`. An
  `[ADDRESSED]` or `[OBSOLETE]` finding is closed and drops out, so the carried
  set converges instead of growing forever.
  """
  @spec carry_over([finding()], String.t() | nil) :: [finding()]
  def carry_over(open, text) when is_list(open) do
    d = dispositions(text)

    Enum.reject(open, fn f ->
      match?(%{status: s} when s in [:addressed, :obsolete], Map.get(d, f.id))
    end)
  end

  # ---- prompt surfaces -----------------------------------------------------

  @doc """
  The carried-forward findings, rendered for the re-review prompt: each id, its
  severity, the files it cited, and — when the implementer's diff is known — a
  loud `NOT TOUCHED` marker on any finding whose cited files the revision never
  changed. That marker is the bd-8mtb0q signal handed to the reviewer directly.
  """
  @spec open_findings_block([finding()], MapSet.t() | nil) :: String.t()
  def open_findings_block([], _touched), do: ""

  def open_findings_block(open, touched_files) do
    rendered =
      Enum.map_join(open, "\n\n", fn f ->
        "  #{f.id} [#{f.severity}] #{cited(f)}#{touch_note(f, touched_files)}\n" <>
          indent(f.text)
      end)

    """
    OPEN FINDINGS CARRIED FORWARD — you (or an earlier round) raised these and
    they are still open. They are listed with the ids you must use below:

    #{rendered}
    """
  end

  @doc """
  The DISPOSITIONS instruction: a round that has open findings must account for
  each one explicitly, by id, before any verdict it issues can be honored.
  """
  @spec disposition_block([finding()]) :: String.t()
  def disposition_block([]), do: ""

  def disposition_block(open) do
    ids = Enum.map_join(open, ", ", & &1.id)
    first = open |> List.first() |> Map.fetch!(:id)

    """
    After the `VERDICT:` line, print a DISPOSITIONS block that accounts for EVERY
    open finding id above — one line each, exactly one bracketed status:

        DISPOSITIONS:
        - [ADDRESSED] #{first} — <the file:line / commit where the fix actually landed>
        - [NOT ADDRESSED] <id> — <what is still missing, right now, in the current diff>
        - [OBSOLETE] <id> — <why the finding no longer applies>

    Ids to account for: #{ids}

    Rules — this is verdict payload, not a formality:
    - `[ADDRESSED]` means you re-opened the CURRENT file and confirmed the problem
      is gone. It does NOT mean the implementer said they fixed it. If the
      implementer's diff did not touch the file the finding cited, you must name
      where the fix landed instead — an `[ADDRESSED]` with neither a touched file
      nor a cited location is rejected as unproven.
    - `[OBSOLETE]` is for a finding a different change invalidated (the code it
      cited is gone, or the concern cannot arise any more). Say why.
    - An APPROVE that leaves any Medium-or-higher id above undispositioned, or
      marks one `[NOT ADDRESSED]`, will NOT be honored — the same way a missing
      `VERDICT:` line is not honored. `VERIFICATION: FULL` on a round that skipped
      these dispositions is a false claim.
    """
  end

  # ---- banner --------------------------------------------------------------

  @doc """
  Prepend the "prior findings not accounted for" banner right after the
  `VERDICT:` line, so a rejected-for-missing-dispositions payload carries the
  reason (and the offending ids) into the durable thread, the revise prompt, and
  any escalation.
  """
  @spec prepend_disposition_banner(String.t(), gap()) :: String.t()
  def prepend_disposition_banner(findings, gap) when is_binary(findings) do
    banner = disposition_banner_text(gap)

    case String.split(findings, "\n", parts: 2) do
      [verdict_line, rest] -> verdict_line <> "\n\n" <> banner <> "\n\n" <> rest
      [verdict_line] -> verdict_line <> "\n\n" <> banner
    end
  end

  @doc "The missing-dispositions banner text. Public for inspection in tests."
  @spec disposition_banner_text(gap()) :: String.t()
  def disposition_banner_text(gap) do
    "⚠️ PRIOR FINDINGS NOT ACCOUNTED FOR — this round returned APPROVE without " <>
      "establishing that the findings raised against this work were actually addressed. " <>
      "An approval is not a verdict on how the diff reads; it is a claim that every open " <>
      "finding is resolved, and that claim must be made per finding, by id. Unresolved:\n" <>
      reason_lines(gap) <>
      "\nRe-open each cited location in the CURRENT diff and either show where it was fixed, " <>
      "say what is still missing, or explain why the finding no longer applies."
  end

  # ---- persistence surfaces ------------------------------------------------

  @doc """
  The finding ids raised by a round, as a JSON array string for
  `review_gate_rounds.finding_ids`. Nil when the round raised none, so the column
  distinguishes "no findings" from "not recorded".
  """
  @spec encode_ids([finding()]) :: String.t() | nil
  def encode_ids([]), do: nil
  def encode_ids(findings) when is_list(findings), do: Jason.encode!(Enum.map(findings, & &1.id))

  @doc """
  The per-round disposition of each carried-forward finding, as a JSON object
  string for `review_gate_rounds.dispositions`. Every open id appears — a finding
  the round never mentioned records as `"none"`, which is the queryable form of
  the bd-8mtb0q defect.
  """
  @spec encode_dispositions([finding()], String.t() | nil) :: String.t() | nil
  def encode_dispositions([], _text), do: nil

  def encode_dispositions(open, text) when is_list(open) do
    d = dispositions(text)

    open
    |> Map.new(fn f ->
      {f.id, Map.get(d, f.id) |> then(&if(&1, do: Atom.to_string(&1.status), else: "none"))}
    end)
    |> Jason.encode!()
  end

  # ---- internals -----------------------------------------------------------

  # Findings prose with every non-finding line removed: the `VERDICT:` sentinel,
  # CRITERIA / DISPOSITIONS / VERIFICATION payload, guard banners, the `arb done`
  # marker, and the harness's `⚙` session-stats footer. What remains is the
  # reviewer's actual findings.
  defp payload_lines(findings) do
    findings
    |> String.split("\n")
    |> drop_banner_paragraphs()
    |> Enum.reject(&drop_line?/1)
  end

  # A guard banner (`⚠️ …`) is a wrapped paragraph, so only its FIRST line carries
  # the marker. Drop from the marker line through the blank line that ends the
  # paragraph; otherwise the continuation lines survive as a phantom finding on
  # any payload that was re-routed through a banner path.
  defp drop_banner_paragraphs(lines) do
    {kept, _in_banner} =
      Enum.reduce(lines, {[], false}, fn line, {acc, in_banner} ->
        trimmed = String.trim(line)

        cond do
          String.starts_with?(trimmed, "⚠️") -> {acc, true}
          in_banner and trimmed == "" -> {acc, false}
          in_banner -> {acc, true}
          true -> {[line | acc], false}
        end
      end)

    Enum.reverse(kept)
  end

  defp drop_line?(line) do
    trimmed = String.trim(line)

    trimmed == "" or
      Regex.match?(~r/^\s*VERDICT:/i, line) or
      Regex.match?(~r/^\s*VERIFICATION:/i, line) or
      Regex.match?(~r/^\s*CRITERIA:\s*$/i, line) or
      Regex.match?(~r/^\s*DISPOSITIONS:\s*$/i, line) or
      Regex.match?(~r/\barb done\b/, line) or
      Regex.match?(~r/^\s*⚙/, line) or
      Arbiter.Worker.ReviewVerification.criteria_line?(line) or
      disposition_line(line) != nil
  end

  # Group the payload lines into findings: a top-level list item starts a new
  # one; anything else continues the current one. With no list items at all, the
  # whole body is a single finding (fail-closed).
  defp group_items(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      cond do
        Regex.match?(@item, line) -> [[line] | acc]
        acc == [] -> [[line]]
        true -> [[line | hd(acc)] | tl(acc)]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn chunk -> chunk |> Enum.reverse() |> Enum.join("\n") end)
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp severity_of(text) do
    case Regex.run(@severity_pattern, text, capture: :all_but_first) do
      [label] -> normalize_severity(label)
      _ -> :unknown
    end
  end

  defp normalize_severity(label) do
    case label |> String.downcase() |> String.trim_trailing("s") do
      "blocker" -> :blocker
      "nit" -> :nit
      "nitpick" -> :nitpick
      other -> String.to_existing_atom(other)
    end
  end

  defp files_in(text) do
    @path
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [path | _] -> path end)
    |> Enum.reject(&(String.downcase(&1) in @path_stoplist))
    |> Enum.uniq()
  end

  defp disposition_line(line) do
    cond do
      match = Regex.run(@status_first, line, capture: :all_but_first) ->
        [status, id] = match
        {id, normalize_status(status)}

      match = Regex.run(@id_first, line, capture: :all_but_first) ->
        [id, status] = match
        {id, normalize_status(status)}

      true ->
        nil
    end
  end

  defp normalize_status(raw) do
    case raw |> String.upcase() |> String.replace(~r/\s+/, " ") do
      "ADDRESSED" -> :addressed
      "NOT ADDRESSED" -> :not_addressed
      _ -> :obsolete
    end
  end

  # The mechanical backstop: an `[ADDRESSED]` claim is unproven when nothing the
  # implementer actually changed can support it — neither a file the finding
  # cited nor any file the disposition line points at was touched by a revision.
  # (A fix cannot have landed in a file git says is unchanged, so "I fixed it in
  # <untouched file>" is not an escape hatch; naming the file where the work
  # really landed is.) Silent when the diff is unknown (`nil` touched set) or the
  # finding cited no file at all — both are "cannot tell", and the guard fires on
  # evidence, not on the absence of it.
  defp unproven?(_finding, _disposition, nil), do: false

  defp unproven?(%{files: []}, _disposition, _touched), do: false

  defp unproven?(%{files: files}, %{line: line}, touched) do
    not Enum.any?(files ++ files_in(line), &touched?(&1, touched))
  end

  # A finding may cite a shortened path (`failure_classifier.ex:172`) while git
  # reports the repo-relative one, so match on either the full path or the
  # basename.
  defp touched?(path, touched) do
    base = Path.basename(path)

    Enum.any?(touched, fn changed ->
      changed == path or Path.basename(changed) == base or String.ends_with?(changed, "/" <> path)
    end)
  end

  defp cited(%{files: []}), do: "(no file cited)"
  defp cited(%{files: files}), do: Enum.join(files, ", ")

  defp touch_note(_finding, nil), do: ""
  defp touch_note(%{files: []}, _touched), do: ""

  defp touch_note(%{files: files}, touched) do
    if Enum.any?(files, &touched?(&1, touched)) do
      ""
    else
      "  ← NOT TOUCHED by any revision so far"
    end
  end

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("      " <> String.trim_leading(&1)))
  end

  defp reason_lines(%{missing: missing, unaddressed: unaddressed, unproven: unproven}) do
    [
      label_lines(missing, "no disposition at all — the round never mentioned it"),
      label_lines(unaddressed, "marked [NOT ADDRESSED] — admitted still open"),
      label_lines(
        unproven,
        "claimed [ADDRESSED], but no revision touched a file it cited and the disposition names no other location"
      )
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join()
  end

  defp label_lines([], _label), do: ""

  defp label_lines(findings, label) do
    Enum.map_join(findings, "", fn f ->
      "  • #{f.id} [#{f.severity}] #{cited(f)} — #{label}\n"
    end)
  end
end
