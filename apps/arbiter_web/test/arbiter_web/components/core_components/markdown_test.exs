defmodule ArbiterWeb.CoreComponents.MarkdownTest do
  use ExUnit.Case, async: true

  use Phoenix.Component
  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Markdown

  describe "markdown/1 rendering" do
    test "renders headings, lists and inline emphasis" do
      html =
        render_component(&markdown/1, text: "# Title\n\nSome **bold** text.\n\n- one\n- two\n")

      assert html =~ "<h1>Title</h1>"
      assert html =~ "<strong>bold</strong>"
      assert html =~ "<li>one</li>"
      assert html =~ "<li>two</li>"
    end

    test "renders fenced code blocks" do
      html = render_component(&markdown/1, text: "```elixir\nIO.puts(\"hi\")\n```\n")

      assert html =~ "<pre"
      assert html =~ "<code"
      assert html =~ "IO.puts"
    end

    test "renders GFM tables" do
      html =
        render_component(&markdown/1, text: "| a | b |\n| --- | --- |\n| 1 | 2 |\n")

      assert html =~ "<table>"
      assert html =~ "<th>a</th>"
      assert html =~ "<td>1</td>"
    end

    test "renders GFM task-list checkboxes" do
      html = render_component(&markdown/1, text: "- [ ] todo\n- [x] done\n")

      assert html =~ ~s(type="checkbox")
      assert html =~ "checked"
      assert html =~ "todo"
      assert html =~ "done"
    end

    test "renders strikethrough and bare autolinks" do
      html = render_component(&markdown/1, text: "~~gone~~ and https://example.com/x\n")

      assert html =~ "<del>gone</del>"
      assert html =~ ~s(href="https://example.com/x")
    end

    test "adds rel=noopener noreferrer to links" do
      html = render_component(&markdown/1, text: "[site](https://example.com)\n")

      assert html =~ ~s(rel="noopener noreferrer")
    end

    test "renders nil and empty text as nothing" do
      assert render_component(&markdown/1, text: nil) |> strip_wrapper() == ""
      assert render_component(&markdown/1, text: "") |> strip_wrapper() == ""
      assert render_component(&markdown/1, text: "   \n") |> strip_wrapper() == ""
    end

    test "wraps output in a themed markdown-body container" do
      html = render_component(&markdown/1, text: "hi")

      assert html =~ "markdown-body"
    end

    test "accepts an extra class and an id" do
      html = render_component(&markdown/1, text: "hi", class: "mt-2", id: "desc-md")

      assert html =~ "mt-2"
      assert html =~ ~s(id="desc-md")
    end
  end

  describe "markdown/1 sanitization" do
    @xss """
    # Heading

    <script>alert(1)</script>

    <img src=x onerror=alert(1)>

    [link](javascript:alert(1))

    <a href="javascript:alert(1)">click</a>

    <iframe src="https://evil.example.com"></iframe>

    <div onclick="alert(1)">hi</div>

    <img src="data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==">
    """

    test "strips scripts, event handlers and javascript: urls" do
      html = render_component(&markdown/1, text: @xss)

      refute html =~ "<script"
      refute html =~ "onerror="
      refute html =~ "onclick="
      refute html =~ "javascript:"
      refute html =~ "<iframe"
      refute html =~ "data:text/html"
      # ...but the legitimate markdown around it still renders.
      assert html =~ "<h1>Heading</h1>"
    end

    test "escapes raw HTML rather than trusting it" do
      html = render_component(&markdown/1, text: "<b>not bold</b>\n")

      refute html =~ "<b>not bold</b>"
    end

    test "html-escapes text that merely looks like markup" do
      html = render_component(&markdown/1, text: "a < b && c > d\n")

      assert html =~ "&lt;"
      assert html =~ "&amp;"
    end
  end

  # `render_component` emits only the component's own markup; strip the
  # wrapper element so "rendered nothing" is assertable.
  defp strip_wrapper(html) do
    html
    |> String.replace(~r|<div[^>]*>|, "")
    |> String.replace("</div>", "")
    |> String.trim()
  end
end
