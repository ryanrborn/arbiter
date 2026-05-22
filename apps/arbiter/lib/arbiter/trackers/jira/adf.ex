defmodule Arbiter.Trackers.Jira.ADF do
  @moduledoc """
  Markdown → Atlassian Document Format (ADF) converter.

  Jira's REST API v3 requires rich-text fields (description, custom textarea
  fields, etc.) to be JSON-encoded ADF documents — not the historic
  wiki-markup or plain Markdown that the v2 API accepted. This module
  converts the small Markdown subset we actually emit (QA Testing Notes,
  Deployment Notes, summary descriptions) into ADF.

  ## Supported subset

  Block-level:

    * paragraphs (blank-line separated)
    * ATX headings, `#` through `####` (h1–h4)
    * bullet lists (`-` or `*` at line start; one level, no nesting)
    * ordered lists (`1.` / `2.` at line start; one level, no nesting)
    * fenced code blocks (```` ``` ````), optional language fence-info

  Inline:

    * `**bold**`
    * `*italic*` (single `*`)
    * backtick-inline `code`

  ## Out of scope

  Nested lists, blockquotes, tables, links, images, hard-breaks, HTML,
  raw embeds. These are deliberately out of scope for the QA/Deployment
  notes use case. If a future caller needs them, extend `parse_inline/1`
  and `parse_blocks/1`. The decision-doc covers the rationale: we
  format-convert, we do not author full Markdown.

  ## Public API

      Arbiter.Trackers.Jira.ADF.from_markdown(string) :: map()

  Returns a Jason-encodable ADF document (top-level `%{"type" => "doc", ...}`).

  ## Helpers

  The lower-level builders (`doc/1`, `heading/2`, `paragraph/1`,
  `bullet_list/1`, `code_block/1`) are exported for callers that want to
  build ADF without going through Markdown.
  """

  @adf_version 1

  # ---- Public: top-level ---------------------------------------------------

  @doc """
  Convert a Markdown string to an ADF document.

  An empty string returns an empty doc — Jira requires content to be a
  list, even if empty.
  """
  @spec from_markdown(String.t() | nil) :: map()
  def from_markdown(nil), do: doc([])
  def from_markdown(""), do: doc([])

  def from_markdown(md) when is_binary(md) do
    md
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> parse_blocks([])
    |> Enum.reverse()
    |> doc()
  end

  # ---- Public: builder helpers --------------------------------------------

  @doc "Wraps `content_nodes` in an ADF doc envelope."
  @spec doc([map()]) :: map()
  def doc(content_nodes) when is_list(content_nodes) do
    %{"type" => "doc", "version" => @adf_version, "content" => content_nodes}
  end

  @doc "ADF heading node. `level` must be in 1..6 (Jira clamps; we accept anything)."
  @spec heading(pos_integer(), String.t() | [map()]) :: map()
  def heading(level, text) when is_binary(text) do
    heading(level, parse_inline(text))
  end

  def heading(level, inline_nodes) when is_list(inline_nodes) do
    %{
      "type" => "heading",
      "attrs" => %{"level" => level},
      "content" => inline_nodes
    }
  end

  @doc "ADF paragraph node from a string (parses inline marks) or pre-built inline nodes."
  @spec paragraph(String.t() | [map()]) :: map()
  def paragraph(text) when is_binary(text) do
    paragraph(parse_inline(text))
  end

  def paragraph(inline_nodes) when is_list(inline_nodes) do
    %{"type" => "paragraph", "content" => inline_nodes}
  end

  @doc "ADF bullet list. `items` is a list of strings or list of inline-node lists."
  @spec bullet_list([String.t() | [map()]]) :: map()
  def bullet_list(items) when is_list(items) do
    %{"type" => "bulletList", "content" => Enum.map(items, &list_item/1)}
  end

  @doc "ADF ordered list. Same input shape as `bullet_list/1`."
  @spec ordered_list([String.t() | [map()]]) :: map()
  def ordered_list(items) when is_list(items) do
    %{"type" => "orderedList", "content" => Enum.map(items, &list_item/1)}
  end

  @doc """
  ADF code block. `lang` is an optional language hint; pass `nil` (or `""`)
  to omit.
  """
  @spec code_block(String.t(), String.t() | nil) :: map()
  def code_block(text, lang \\ nil) do
    attrs =
      case lang do
        l when is_binary(l) and l != "" -> %{"language" => l}
        _ -> %{}
      end

    %{
      "type" => "codeBlock",
      "attrs" => attrs,
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  # ---- Block parsing -------------------------------------------------------

  defp parse_blocks([], acc), do: acc

  # Skip leading blank lines.
  defp parse_blocks(["" | rest], acc), do: parse_blocks(rest, acc)

  # Fenced code block.
  defp parse_blocks(["```" <> lang | rest], acc) do
    {body_lines, after_fence} = take_until_fence(rest, [])
    block = code_block(Enum.join(body_lines, "\n"), String.trim(lang))
    parse_blocks(after_fence, [block | acc])
  end

  # ATX heading. Match #..#### with a following space.
  defp parse_blocks([line | rest], acc) do
    cond do
      heading_match = heading_level(line) ->
        {level, text} = heading_match
        parse_blocks(rest, [heading(level, text) | acc])

      bullet_line?(line) ->
        {items, remaining} = take_list(rest, [bullet_text(line)], &bullet_line?/1, &bullet_text/1)
        parse_blocks(remaining, [bullet_list(items) | acc])

      ordered_line?(line) ->
        {items, remaining} = take_list(rest, [ordered_text(line)], &ordered_line?/1, &ordered_text/1)
        parse_blocks(remaining, [ordered_list(items) | acc])

      true ->
        {para_lines, remaining} = take_paragraph(rest, [line])
        text = para_lines |> Enum.reverse() |> Enum.join(" ")
        parse_blocks(remaining, [paragraph(text) | acc])
    end
  end

  defp take_until_fence([], acc), do: {Enum.reverse(acc), []}
  defp take_until_fence(["```" <> _ | rest], acc), do: {Enum.reverse(acc), rest}
  defp take_until_fence([line | rest], acc), do: take_until_fence(rest, [line | acc])

  # Pre-compiled here so the `#{1,4}` regex quantifier doesn't collide with
  # Elixir's `#{ }` string interpolation in a ~r sigil.
  @heading_regex Regex.compile!("^(\#{1,4})\\s+(.+?)\\s*\#*\\s*$")

  defp heading_level(line) do
    case Regex.run(@heading_regex, line) do
      [_, hashes, text] -> {String.length(hashes), text}
      _ -> nil
    end
  end

  defp bullet_line?(line), do: Regex.match?(~r/^\s*[-*]\s+/, line)

  defp bullet_text(line) do
    Regex.replace(~r/^\s*[-*]\s+/, line, "")
  end

  defp ordered_line?(line), do: Regex.match?(~r/^\s*\d+\.\s+/, line)

  defp ordered_text(line) do
    Regex.replace(~r/^\s*\d+\.\s+/, line, "")
  end

  defp take_list([], acc, _pred, _extract), do: {Enum.reverse(acc), []}

  defp take_list([line | rest] = lines, acc, pred, extract) do
    if pred.(line) do
      take_list(rest, [extract.(line) | acc], pred, extract)
    else
      {Enum.reverse(acc), lines}
    end
  end

  defp take_paragraph([], acc), do: {acc, []}
  defp take_paragraph(["" | _] = rest, acc), do: {acc, rest}

  defp take_paragraph([line | rest] = lines, acc) do
    cond do
      heading_level(line) -> {acc, lines}
      bullet_line?(line) -> {acc, lines}
      ordered_line?(line) -> {acc, lines}
      String.starts_with?(line, "```") -> {acc, lines}
      true -> take_paragraph(rest, [line | acc])
    end
  end

  # ---- List items ----------------------------------------------------------

  defp list_item(text) when is_binary(text) do
    %{
      "type" => "listItem",
      "content" => [paragraph(text)]
    }
  end

  defp list_item(nodes) when is_list(nodes) do
    %{"type" => "listItem", "content" => [paragraph(nodes)]}
  end

  # ---- Inline parsing ------------------------------------------------------

  @doc """
  Parse an inline-text string into ADF text nodes with marks. Public so
  the higher-level builders can use it and so callers can hand-roll
  blocks while still getting `**bold**` / `*italic*` / `` `code` `` support.
  """
  @spec parse_inline(String.t()) :: [map()]
  def parse_inline(""), do: []

  def parse_inline(text) when is_binary(text) do
    text
    |> tokenize_inline([], "")
    |> Enum.reverse()
    |> Enum.reject(&match?(%{"text" => ""}, &1))
  end

  # State machine: scan char by char, emitting text nodes when we hit a
  # marker. Markers: `**` (bold), `*` (italic), `` ` `` (code). We treat
  # unmatched markers as literal characters (best-effort).

  defp tokenize_inline("", acc, buf), do: push_text(acc, buf)

  defp tokenize_inline("**" <> rest, acc, buf) do
    case String.split(rest, "**", parts: 2) do
      [inner, after_close] ->
        acc = push_text(acc, buf)
        acc = [%{"type" => "text", "text" => inner, "marks" => [%{"type" => "strong"}]} | acc]
        tokenize_inline(after_close, acc, "")

      [_] ->
        # no closing `**`; treat as literal
        tokenize_inline(rest, acc, buf <> "**")
    end
  end

  defp tokenize_inline("*" <> rest, acc, buf) do
    case String.split(rest, "*", parts: 2) do
      [inner, after_close] when inner != "" ->
        acc = push_text(acc, buf)
        acc = [%{"type" => "text", "text" => inner, "marks" => [%{"type" => "em"}]} | acc]
        tokenize_inline(after_close, acc, "")

      _ ->
        tokenize_inline(rest, acc, buf <> "*")
    end
  end

  defp tokenize_inline("`" <> rest, acc, buf) do
    case String.split(rest, "`", parts: 2) do
      [inner, after_close] when inner != "" ->
        acc = push_text(acc, buf)
        acc = [%{"type" => "text", "text" => inner, "marks" => [%{"type" => "code"}]} | acc]
        tokenize_inline(after_close, acc, "")

      _ ->
        tokenize_inline(rest, acc, buf <> "`")
    end
  end

  defp tokenize_inline(<<ch::utf8, rest::binary>>, acc, buf) do
    tokenize_inline(rest, acc, buf <> <<ch::utf8>>)
  end

  defp push_text(acc, ""), do: acc
  defp push_text(acc, text), do: [%{"type" => "text", "text" => text} | acc]
end
