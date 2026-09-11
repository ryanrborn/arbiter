defmodule Arbiter.Workflows.ReviewPatrol.ThreadMemory do
  @moduledoc """
  Thread memory for ReviewPatrol re-reviews (bd-cccjtn).

  A re-review used to read the diff cold: it had no idea which of its own
  findings the author had already answered, so it re-raised them — sometimes
  verbatim, sometimes ones our own reply handler had *conceded* in-thread.
  This module is the memory that closes that loop.

  ## What "settled" means

  A review thread WE own is **settled** when one of these holds:

    * `"we_conceded"`    — a later comment of ours in the thread concedes
      ("my comment was wrong", "you're right", "withdrawing this"). Our reply
      handler (`Arbiter.Workflows.ReviewReply`) already writes these; the
      verdict pass simply never consumed them.
    * `"resolved"`       — the thread is marked resolved on the forge.
    * `"author_refuted"` — the PR author replied citing concrete evidence
      (a `file.ex:41`-style citation). A bare "seems fine to me" is NOT a
      refutation and does not settle anything.

  `"we_conceded"` outranks `"resolved"`, which outranks `"author_refuted"`.

  ## What settled buys

  Two things, and deliberately both — a prompt-only fix would be advisory:

    1. `prompt_section/1` tells the reviewer what is already answered, with
       our finding, the author's reply, and the rule for re-raising.
    2. `filter_findings/3` **enforces** it: a fresh finding anchored within
       `#{5}` lines of a settled thread is dropped unless the new commits
       actually touch that line window. Settled stays settled on a fixed
       head; new code on those lines re-opens the question.

  Entries are persisted on the engagement (`Issue.settled_threads`) as
  string-keyed maps, so a thread stays settled after it drops off
  `list_open_review_threads/1` (which only returns *unresolved* threads —
  resolving a conceded thread would otherwise erase the memory of it).
  """

  # How far a re-raise may drift from the settled thread's anchor and still
  # count as "the same finding". Review comments move by a line or two as the
  # file around them changes; an exact-line match would miss almost every
  # real re-raise.
  @anchor_window 5

  @max_snippet 400

  # An explicit `path/to/file.ex:41` (or `:L41`, or `#41`) citation.
  @file_line_citation ~r/[\w.\/-]*[\w-]\.[a-zA-Z0-9]+[:#]L?\d+/

  # A backticked filename followed closely by "line N".
  @file_then_line ~r/`[^`\n]*\.[a-zA-Z0-9]+`[^\n]{0,80}?\bline\s+\d+/i

  @concession_patterns [
    ~r/\bmy\s+(?:comment|note|finding|review|concern)\s+(?:was|is)\s+(?:wrong|incorrect|mistaken)\b/i,
    ~r/\b(?:you(?:'re|’re|\s+are)|that(?:'s|’s|\s+is))\s+(?:right|correct)\b/i,
    ~r/\bi\s+(?:was|am)\s+(?:wrong|mistaken|incorrect)\b/i,
    ~r/\b(?:withdraw|withdrawing|retract|retracting|dropping)\s+(?:this|the|my)\b/i,
    ~r/\bmy\s+(?:mistake|error)\b/i,
    ~r/\bdisregard\s+(?:this|my|that)\b/i,
    ~r/\b(?:no\s+issue\s+here|not\s+an\s+issue|false\s+positive)\b/i
  ]

  @type entry :: %{String.t() => term()}

  @doc """
  The settled entries among `threads`, as persistable string-keyed maps.

  Only threads we participated in (`our_login` authored a comment) are
  considered — another reviewer's thread is none of our memory. `head_sha` is
  stamped on each entry so the settle point is auditable.
  """
  @spec settle([map()], String.t() | nil, String.t() | nil, String.t() | nil) :: [entry()]
  def settle(threads, our_login, pr_author, head_sha \\ nil)

  def settle(threads, our_login, pr_author, head_sha)
      when is_list(threads) and is_binary(our_login) and our_login != "" do
    threads
    |> Enum.filter(&ours?(&1, our_login))
    |> Enum.flat_map(fn thread ->
      case settle_reason(thread, our_login, pr_author) do
        nil -> []
        reason -> [entry(thread, reason, pr_author, head_sha)]
      end
    end)
  end

  def settle(_threads, _our_login, _pr_author, _head_sha), do: []

  @doc """
  Merge freshly-settled entries into the engagement's stored list.

  Keyed on `"thread_id"`: an existing entry keeps its position but takes the
  new entry's content, so a thread that was `"author_refuted"` and later
  conceded ends up recorded as `"we_conceded"`.
  """
  @spec merge([entry()] | nil, [entry()] | nil) :: [entry()]
  def merge(existing, fresh) do
    existing = List.wrap(existing)
    fresh = List.wrap(fresh)
    by_id = Map.new(fresh, &{&1["thread_id"], &1})

    updated = Enum.map(existing, &Map.get(by_id, &1["thread_id"], &1))
    seen = MapSet.new(existing, & &1["thread_id"])

    updated ++ Enum.reject(fresh, &MapSet.member?(seen, &1["thread_id"]))
  end

  @doc """
  Drop findings that re-raise a settled thread on lines the new commits
  didn't touch.

  A finding is dropped when a settled entry anchors to the same file within
  `#{@anchor_window}` lines of it AND the diff adds no line inside that
  window. File-level settled threads (no `"line"`) suppress nothing — they
  have no anchor to compare against, and suppressing a whole file would
  silence genuinely new problems.
  """
  @spec filter_findings([map()], [entry()] | nil, String.t() | nil) :: [map()]
  def filter_findings(findings, settled, diff) when is_list(findings) do
    case anchored(settled) do
      [] ->
        findings

      anchors ->
        touched = added_lines(diff)
        Enum.reject(findings, &suppress?(&1, anchors, touched))
    end
  end

  @doc """
  The prompt block describing the settled threads to the reviewer.

  Returns `""` when there is nothing settled, so the prompt is byte-identical
  to the pre-thread-memory one for a first-round PR.
  """
  @spec prompt_section([entry()] | nil) :: String.t()
  def prompt_section(settled) do
    case List.wrap(settled) do
      [] ->
        ""

      entries ->
        """
        --- SETTLED REVIEW THREADS ---
        These findings were already raised on this PR and are CLOSED. For each,
        either the author refuted it with cited evidence or we conceded it was
        wrong. Do NOT raise any of them again unless the diff below changes
        the code at the cited line — and if it does, the message MUST
        name what changed to re-open it. A settled finding repeated with
        no new commits on its lines is a bug in the review, not a finding.

        #{Enum.map_join(entries, "\n", &render_entry/1)}
        --- End SETTLED REVIEW THREADS ---

        """
    end
  end

  @doc """
  Whether a comment body of ours concedes the finding.

  Used both when settling a thread we can still read and at reply-dispatch
  time, where the reply we just composed is the only copy we have.
  """
  @spec concession?(String.t() | nil) :: boolean()
  def concession?(body) when is_binary(body) do
    Enum.any?(@concession_patterns, &Regex.match?(&1, body))
  end

  def concession?(_body), do: false

  @doc """
  Whether an author reply refutes with concrete, checkable evidence.
  """
  @spec cited_evidence?(String.t() | nil) :: boolean()
  def cited_evidence?(body) when is_binary(body) do
    Regex.match?(@file_line_citation, body) or Regex.match?(@file_then_line, body)
  end

  def cited_evidence?(_body), do: false

  # ---- internals ----------------------------------------------------------

  defp ours?(thread, our_login) do
    thread
    |> comments()
    |> Enum.any?(&(&1[:author] == our_login))
  end

  defp comments(thread), do: List.wrap(Map.get(thread, :comments) || [])

  # `"we_conceded"` > `"resolved"` > `"author_refuted"`; nil = not settled.
  defp settle_reason(thread, our_login, pr_author) do
    cond do
      Enum.any?(comments(thread), &(&1[:author] == our_login and concession?(&1[:body]))) ->
        "we_conceded"

      Map.get(thread, :resolved) == true ->
        "resolved"

      is_binary(pr_author) and pr_author != "" and author_refuted?(thread, pr_author) ->
        "author_refuted"

      true ->
        nil
    end
  end

  defp author_refuted?(thread, pr_author) do
    Enum.any?(comments(thread), &(&1[:author] == pr_author and cited_evidence?(&1[:body])))
  end

  defp entry(thread, reason, pr_author, head_sha) do
    %{
      "thread_id" => to_string(Map.get(thread, :id)),
      "file" => Map.get(thread, :path),
      "line" => Map.get(thread, :line),
      "finding" => snippet(opening_body(thread)),
      "reason" => reason,
      "author_reply" => snippet(last_author_body(thread, pr_author)),
      "settled_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "settled_sha" => head_sha
    }
  end

  defp opening_body(thread) do
    case comments(thread) do
      [first | _] -> first[:body] || Map.get(thread, :body)
      [] -> Map.get(thread, :body)
    end
  end

  defp last_author_body(thread, pr_author) when is_binary(pr_author) do
    thread
    |> comments()
    |> Enum.filter(&(&1[:author] == pr_author))
    |> List.last()
    |> case do
      nil -> nil
      c -> c[:body]
    end
  end

  defp last_author_body(_thread, _pr_author), do: nil

  defp snippet(nil), do: nil

  defp snippet(body) when is_binary(body) do
    body = body |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(body) > @max_snippet,
      do: String.slice(body, 0, @max_snippet) <> "…",
      else: body
  end

  defp snippet(_body), do: nil

  # Settled entries that carry a usable {file, line} anchor.
  defp anchored(settled) do
    settled
    |> List.wrap()
    |> Enum.filter(fn e ->
      is_binary(e["file"]) and e["file"] != "" and is_integer(e["line"])
    end)
  end

  defp suppress?(finding, anchors, touched) do
    file = finding[:file] || finding["file"]
    line = finding[:line] || finding["line"]

    is_binary(file) and is_integer(line) and
      Enum.any?(anchors, fn a ->
        a["file"] == file and abs(a["line"] - line) <= @anchor_window and
          not window_touched?(touched, file, a["line"])
      end)
  end

  defp window_touched?(touched, file, anchor) do
    lines = Map.get(touched, file, MapSet.new())
    Enum.any?((anchor - @anchor_window)..(anchor + @anchor_window), &MapSet.member?(lines, &1))
  end

  # `%{file => MapSet.t(new-file line numbers ADDED by the diff)}`. Context
  # lines don't count as touched — they're the unchanged code a settled thread
  # is still anchored to.
  defp added_lines(diff) when is_binary(diff) do
    diff
    |> String.split("\n")
    |> Enum.reduce({nil, nil, %{}}, &scan_line/2)
    |> elem(2)
  end

  defp added_lines(_diff), do: %{}

  defp scan_line("+++ " <> rest, {_file, _n, acc}), do: {diff_path(rest), nil, acc}
  defp scan_line("--- " <> _rest, {file, n, acc}), do: {file, n, acc}

  defp scan_line("@@" <> _ = line, {file, _n, acc}) do
    case Regex.run(~r/^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
      [_, start] -> {file, String.to_integer(start), acc}
      _ -> {file, nil, acc}
    end
  end

  defp scan_line("+" <> _rest, {file, n, acc}) when is_binary(file) and is_integer(n) do
    {file, n + 1, Map.update(acc, file, MapSet.new([n]), &MapSet.put(&1, n))}
  end

  defp scan_line("-" <> _rest, {file, n, acc}), do: {file, n, acc}

  defp scan_line(_line, {file, n, acc}) when is_integer(n), do: {file, n + 1, acc}
  defp scan_line(_line, state), do: state

  defp diff_path(rest) do
    path = rest |> String.split("\t", parts: 2) |> List.first() |> to_string() |> String.trim()

    cond do
      path in ["/dev/null", ""] -> nil
      String.starts_with?(path, "b/") -> String.replace_prefix(path, "b/", "")
      String.starts_with?(path, "a/") -> String.replace_prefix(path, "a/", "")
      true -> path
    end
  end

  defp render_entry(entry) do
    loc =
      case {entry["file"], entry["line"]} do
        {f, l} when is_binary(f) and is_integer(l) -> "#{f}:#{l}"
        {f, _} when is_binary(f) -> f
        _ -> "(no location)"
      end

    [
      "* #{loc} — #{reason_phrase(entry["reason"])}",
      "  Our finding: #{entry["finding"] || "(unrecorded)"}",
      entry["author_reply"] && "  Author's reply: #{entry["author_reply"]}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp reason_phrase("we_conceded"), do: "we conceded this finding was wrong"
  defp reason_phrase("resolved"), do: "the thread was resolved"
  defp reason_phrase("author_refuted"), do: "the author refuted it with cited evidence"
  defp reason_phrase(other), do: to_string(other)
end
