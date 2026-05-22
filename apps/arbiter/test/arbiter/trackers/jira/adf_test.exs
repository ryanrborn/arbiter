defmodule Arbiter.Trackers.Jira.ADFTest do
  use ExUnit.Case, async: true

  alias Arbiter.Trackers.Jira.ADF

  describe "from_markdown/1" do
    test "empty input produces an empty doc" do
      assert ADF.from_markdown("") == %{"type" => "doc", "version" => 1, "content" => []}
      assert ADF.from_markdown(nil) == %{"type" => "doc", "version" => 1, "content" => []}
    end

    test "plain paragraph becomes a paragraph node with a single text node" do
      doc = ADF.from_markdown("Hello world.")

      assert doc == %{
               "type" => "doc",
               "version" => 1,
               "content" => [
                 %{
                   "type" => "paragraph",
                   "content" => [%{"type" => "text", "text" => "Hello world."}]
                 }
               ]
             }
    end

    test "two paragraphs separated by a blank line" do
      doc = ADF.from_markdown("First.\n\nSecond.")
      assert length(doc["content"]) == 2
      assert [%{"type" => "paragraph"}, %{"type" => "paragraph"}] = doc["content"]
    end

    test "headings h1..h4" do
      for level <- 1..4 do
        prefix = String.duplicate("#", level)
        doc = ADF.from_markdown("#{prefix} Title")
        assert [%{"type" => "heading", "attrs" => %{"level" => ^level}}] = doc["content"]
      end
    end

    test "bullet list with `-` markers" do
      doc = ADF.from_markdown("- one\n- two\n- three")
      assert [%{"type" => "bulletList", "content" => items}] = doc["content"]
      assert length(items) == 3
      assert Enum.all?(items, fn %{"type" => "listItem"} -> true end)
    end

    test "bullet list with `*` markers" do
      doc = ADF.from_markdown("* alpha\n* beta")
      assert [%{"type" => "bulletList", "content" => items}] = doc["content"]
      assert length(items) == 2
    end

    test "ordered list" do
      doc = ADF.from_markdown("1. first\n2. second")
      assert [%{"type" => "orderedList", "content" => items}] = doc["content"]
      assert length(items) == 2
    end

    test "fenced code block with language" do
      doc = ADF.from_markdown("```elixir\nIO.puts(\"hi\")\n```")

      assert [
               %{
                 "type" => "codeBlock",
                 "attrs" => %{"language" => "elixir"},
                 "content" => [%{"type" => "text", "text" => "IO.puts(\"hi\")"}]
               }
             ] = doc["content"]
    end

    test "fenced code block without language" do
      doc = ADF.from_markdown("```\nplain code\n```")
      assert [%{"type" => "codeBlock", "attrs" => %{}}] = doc["content"]
    end

    test "inline bold + italic + code marks" do
      nodes = ADF.parse_inline("Click **save** then *retry* using `mix test`.")

      marks =
        Enum.flat_map(nodes, fn
          %{"marks" => ms} -> Enum.map(ms, & &1["type"])
          _ -> []
        end)

      assert "strong" in marks
      assert "em" in marks
      assert "code" in marks
    end

    test "unmatched markers are treated as literal text" do
      assert [%{"type" => "text", "text" => text}] = ADF.parse_inline("just * one star")
      assert text == "just * one star"
    end

    test "mixed document with heading + paragraph + list + code" do
      md = """
      # Deployment

      Steps to roll out:

      - run `mix migrate`
      - bump version

      ```bash
      kubectl apply -f deploy.yaml
      ```
      """

      doc = ADF.from_markdown(md)
      types = Enum.map(doc["content"], & &1["type"])

      assert "heading" in types
      assert "paragraph" in types
      assert "bulletList" in types
      assert "codeBlock" in types
    end

    test "result is Jason-encodable end-to-end" do
      md = "**bold** and *italic* and `code`"
      assert is_binary(Jason.encode!(ADF.from_markdown(md)))
    end
  end

  describe "builder helpers" do
    test "doc/1 wraps content with the version" do
      assert ADF.doc([]) == %{"type" => "doc", "version" => 1, "content" => []}
    end

    test "heading/2 accepts a level + string" do
      node = ADF.heading(2, "Hi")
      assert node["type"] == "heading"
      assert node["attrs"] == %{"level" => 2}
      assert [%{"type" => "text", "text" => "Hi"}] = node["content"]
    end

    test "paragraph/1 parses inline marks from the string form" do
      node = ADF.paragraph("a **b** c")
      texts = Enum.map(node["content"], & &1["text"])
      assert "a " in texts
      assert "b" in texts
      assert " c" in texts
    end

    test "bullet_list/1 and ordered_list/1 build the right node types" do
      assert ADF.bullet_list(["x", "y"])["type"] == "bulletList"
      assert ADF.ordered_list(["x", "y"])["type"] == "orderedList"
    end

    test "code_block/2 omits language attr when nil" do
      assert ADF.code_block("x")["attrs"] == %{}
      assert ADF.code_block("x", "elixir")["attrs"] == %{"language" => "elixir"}
    end
  end
end
