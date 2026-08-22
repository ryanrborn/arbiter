defmodule ArbiterWeb.CoreComponents.DataTest do
  use ExUnit.Case, async: true

  use Phoenix.Component
  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Data

  describe "status_chip/1" do
    test "renders the literal status value, never prettified" do
      html = render_component(&status_chip/1, status: :awaiting_review_gate)

      assert html =~ "awaiting_review_gate"
      refute html =~ "In review_gate"
      refute html =~ "Awaiting Review Gate"
    end

    test "renders literal in_progress verbatim" do
      html = render_component(&status_chip/1, status: :in_progress)

      assert html =~ "in_progress"
      refute html =~ "In Progress"
    end

    test "accepts string statuses verbatim too" do
      html = render_component(&status_chip/1, status: "weird_custom_status")

      assert html =~ "weird_custom_status"
    end

    test "known statuses get a semantic badge class" do
      html = render_component(&status_chip/1, status: :completed)
      assert html =~ "badge-success"

      html = render_component(&status_chip/1, status: :failed)
      assert html =~ "badge-error"
    end

    test "the handoff's spaced display labels get the same badge as their snake_case twins" do
      # RunRow renders `status="awaiting review"` straight from the design
      # handoff; without this it fell through to badge-ghost and the amber
      # "needs you" signal was lost on the roster.
      html = render_component(&status_chip/1, status: "awaiting review")

      assert html =~ "badge-warning"
      assert html =~ "awaiting review"
    end

    test "unknown status falls back to a ghost badge without crashing" do
      html = render_component(&status_chip/1, status: :some_unmapped_status)

      assert html =~ "badge-ghost"
      assert html =~ "some_unmapped_status"
    end

    test "Issue status vocabulary gets a semantic badge class" do
      html = render_component(&status_chip/1, status: :open)
      assert html =~ "badge-success"

      html = render_component(&status_chip/1, status: :in_progress)
      assert html =~ "badge-info"

      html = render_component(&status_chip/1, status: :closed)
      assert html =~ "badge-ghost"
    end
  end

  describe "priority_tag/1" do
    test "P0 and P1 tint red" do
      assert render_component(&priority_tag/1, priority: 0) =~ "badge-error"
      assert render_component(&priority_tag/1, priority: 1) =~ "badge-error"
    end

    test "P2 is neutral" do
      html = render_component(&priority_tag/1, priority: 2)
      assert html =~ "badge-neutral"
    end

    test "P3 and P4 are ghost" do
      assert render_component(&priority_tag/1, priority: 3) =~ "badge-ghost"
      assert render_component(&priority_tag/1, priority: 4) =~ "badge-ghost"
    end

    test "renders the P-prefixed label" do
      html = render_component(&priority_tag/1, priority: 1)
      assert html =~ "P1"
    end

    test "nil priority renders a placeholder ghost tag" do
      html = render_component(&priority_tag/1, priority: nil)
      assert html =~ "badge-ghost"
      assert html =~ "—"
    end
  end

  describe "difficulty_meter/1" do
    test "D0 fills exactly one of five bars" do
      html = render_component(&difficulty_meter/1, difficulty: 0)

      assert count_occurrences(html, "difficulty-bar-filled") == 1
      assert count_occurrences(html, "difficulty-bar-empty") == 4
    end

    test "D2 fills exactly three of five bars (n+1)" do
      html = render_component(&difficulty_meter/1, difficulty: 2)

      assert count_occurrences(html, "difficulty-bar-filled") == 3
      assert count_occurrences(html, "difficulty-bar-empty") == 2
    end

    test "D4 fills all five bars and tints them red" do
      html = render_component(&difficulty_meter/1, difficulty: 4)

      assert count_occurrences(html, "difficulty-bar-filled") == 5
      assert count_occurrences(html, "difficulty-bar-empty") == 0
      assert html =~ "bg-error"
    end

    test "only D4 tints red; lower difficulties use the neutral fill" do
      html = render_component(&difficulty_meter/1, difficulty: 3)

      refute html =~ "bg-error"
    end

    test "nil difficulty renders all five bars empty" do
      html = render_component(&difficulty_meter/1, difficulty: nil)

      assert count_occurrences(html, "difficulty-bar-filled") == 0
      assert count_occurrences(html, "difficulty-bar-empty") == 5
    end

    test "out-of-range or wrong-type difficulty degrades gracefully instead of crashing" do
      html = render_component(&difficulty_meter/1, difficulty: 5)
      assert count_occurrences(html, "difficulty-bar-filled") == 0
      assert count_occurrences(html, "difficulty-bar-empty") == 5
      assert html =~ "Difficulty: not set"

      html = render_component(&difficulty_meter/1, difficulty: "3")
      assert count_occurrences(html, "difficulty-bar-filled") == 0
      assert count_occurrences(html, "difficulty-bar-empty") == 5
    end
  end

  describe "type_tag/1" do
    test "renders the literal type value" do
      html = render_component(&type_tag/1, type: :bug_fix)
      assert html =~ "bug_fix"
    end

    test "accepts string types" do
      html = render_component(&type_tag/1, type: "spike")
      assert html =~ "spike"
    end
  end

  describe "data_list/1" do
    test "renders each item's label and value" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.data_list>
          <:item label="Priority">P1</:item>
          <:item label="Status">running</:item>
        </.data_list>
        """)

      assert html =~ "Priority"
      assert html =~ "P1"
      assert html =~ "Status"
      assert html =~ "running"
    end
  end

  describe "data_table/1" do
    test "renders a header per column and a cell per row" do
      assigns = %{rows: [%{name: "alpha"}, %{name: "beta"}]}

      html =
        rendered_to_string(~H"""
        <.data_table id="things" rows={@rows}>
          <:col :let={row} label="Name">{row.name}</:col>
        </.data_table>
        """)

      assert html =~ "Name"
      assert html =~ "alpha"
      assert html =~ "beta"
    end
  end

  defp count_occurrences(haystack, needle) do
    haystack
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end
end
