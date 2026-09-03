defmodule Arbiter.Loop.RepoDocPatch do
  @moduledoc """
  Pure merge logic for the repo `CLAUDE.md` write path (bd-1cusio, Amendment D
  rung 2 of the destination ladder).

  A repo's `CLAUDE.md` is edited by humans and, now, by Arbiter. Both sides
  must survive the other's edits, so Arbiter never rewrites the whole file —
  it owns exactly one delimited **managed section**, bounded by
  `<!-- arbiter:begin -->` and `<!-- arbiter:end -->`. Everything outside
  those markers is copied through untouched; everything inside is Arbiter's,
  keyed by a stable fingerprint so a re-applied lesson updates its own line
  instead of duplicating it.

  ## Size discipline

  The managed section is injected into every dispatch in that repo, so it
  carries a byte cap (`:cap_bytes`, default 4000 bytes). Adding an entry that
  would push the section over budget evicts the *oldest* entries — not the
  new one — until it fits, and `upsert/4` reports exactly what it dropped so
  the caller can surface that instead of silently shrinking the file. A
  single entry that alone exceeds the cap is rejected outright rather than
  truncated, since a truncated lesson can read as a different instruction
  than the one that was proposed.
  """

  @begin_marker "<!-- arbiter:begin -->"
  @end_marker "<!-- arbiter:end -->"
  @default_cap_bytes 4_000

  @section_comment "<!-- Managed by Arbiter's loop pass. Hand edits inside this " <>
                     "block are overwritten at the next write — edit outside it instead. -->"

  @type entry :: %{id: String.t(), text: String.t()}

  @doc "The literal marker that opens the managed section."
  @spec begin_marker() :: String.t()
  def begin_marker, do: @begin_marker

  @doc "The literal marker that closes the managed section."
  @spec end_marker() :: String.t()
  def end_marker, do: @end_marker

  @doc """
  Returns the new full file content with `id => text` upserted into the
  managed section of `content` (the current `CLAUDE.md`, or `""`/`nil` if the
  file doesn't exist yet).

  `id` is a stable key (the proposal's fingerprint) — re-upserting the same
  `id` replaces its line in place rather than adding a duplicate, and counts
  as freshly touched for eviction purposes.

  Options:

    * `:cap_bytes` — byte budget for the managed section body (default
      #{@default_cap_bytes}). Oldest entries are evicted first when the
      section would exceed it.

  Returns `{:ok, %{content: new_content, removed: [id, ...]}}`,
  `{:error, {:entry_too_large, cap_bytes}}` when `text` alone (plus its
  rendered line overhead) cannot fit under the cap no matter what else is
  evicted, or `{:error, :invalid_entry_text}` when `text` contains a newline
  or either managed-section marker — an entry is rendered as one line
  (`render_entries/1`), so a newline would silently truncate on the next
  parse (`parse_entries/1` splits on `"\n"`), and a marker would prematurely
  close or reopen the managed section.
  """
  @spec upsert(String.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, %{content: String.t(), removed: [String.t()]}}
          | {:error, {:entry_too_large, pos_integer()}}
          | {:error, :invalid_entry_text}
  def upsert(content, id, text, opts \\ [])

  def upsert(nil, id, text, opts), do: upsert("", id, text, opts)

  def upsert(content, id, text, opts)
      when is_binary(content) and is_binary(id) and is_binary(text) do
    if invalid_entry_text?(text) do
      {:error, :invalid_entry_text}
    else
      cap_bytes = Keyword.get(opts, :cap_bytes, @default_cap_bytes)

      {before, entries, rest} = split(content)
      updated_entries = upsert_entry(entries, id, text)

      case fit_to_cap(updated_entries, cap_bytes) do
        {:ok, kept, removed} ->
          {:ok, %{content: render(before, kept, rest), removed: removed}}

        :error ->
          {:error, {:entry_too_large, cap_bytes}}
      end
    end
  end

  defp invalid_entry_text?(text) do
    String.contains?(text, "\n") or
      String.contains?(text, @begin_marker) or
      String.contains?(text, @end_marker)
  end

  # ---- parsing --------------------------------------------------------------

  # Splits `content` into the text before the managed section, its parsed
  # entries (in file order), and the text after — or, when no managed section
  # exists yet, `content` as "before" with no entries and no "after".
  defp split(content) do
    case String.split(content, @begin_marker, parts: 2) do
      [before, rest] ->
        case String.split(rest, @end_marker, parts: 2) do
          [section, after_] -> {trim_trailing_blank(before), parse_entries(section), after_}
          [_] -> {trim_trailing_blank(content), [], ""}
        end

      [_] ->
        {trim_trailing_blank(content), [], ""}
    end
  end

  @entry_prefix "- <!-- arbiter:lesson:"

  defp parse_entries(section) do
    section
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^- <!-- arbiter:lesson:(.+?) -->\s?(.*)$/, line) do
        [_, id, text] -> [%{id: id, text: text}]
        nil -> []
      end
    end)
  end

  defp trim_trailing_blank(text), do: String.trim_trailing(text)

  # ---- upsert + eviction -----------------------------------------------------

  defp upsert_entry(entries, id, text) do
    without = Enum.reject(entries, &(&1.id == id))
    without ++ [%{id: id, text: text}]
  end

  defp fit_to_cap(entries, cap_bytes) do
    fit_to_cap(entries, cap_bytes, [])
  end

  defp fit_to_cap([], _cap_bytes, removed), do: {:ok, [], removed}

  defp fit_to_cap([last], cap_bytes, removed) do
    if byte_size(render_entries([last])) <= cap_bytes do
      {:ok, [last], removed}
    else
      :error
    end
  end

  defp fit_to_cap([oldest | rest] = entries, cap_bytes, removed) do
    if byte_size(render_entries(entries)) <= cap_bytes do
      {:ok, entries, removed}
    else
      fit_to_cap(rest, cap_bytes, removed ++ [oldest.id])
    end
  end

  # ---- rendering --------------------------------------------------------------

  defp render_entries(entries) do
    entries
    |> Enum.map_join(
      "\n",
      &"#{@entry_prefix}#{&1.id} -->#{if &1.text == "", do: "", else: " " <> &1.text}"
    )
  end

  defp render(before, entries, rest) do
    section = [@section_comment, render_entries(entries)] |> Enum.join("\n")

    body = "#{@begin_marker}\n#{section}\n#{@end_marker}"

    rest = String.trim(rest)

    [String.trim_trailing(before), body, rest]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end
end
