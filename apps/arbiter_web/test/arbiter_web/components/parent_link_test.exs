defmodule ArbiterWeb.ParentLinkTest do
  @moduledoc """
  bd-38of5i / design bd-2s901b §7: one component, two sizes. The board card's
  `↳ bd-epic` chip and the child detail page's "Part of …" banner are the same
  edge rendered at two scales, so they cannot drift.
  """
  use ExUnit.Case, async: true

  use Phoenix.Component
  import Phoenix.LiveViewTest
  import ArbiterWeb.ParentLink

  defp epic(attrs \\ %{}) do
    Map.merge(
      %{
        id: "bd-cv1inp",
        title: "Browser coordinator sessions",
        issue_type: :epic,
        status: :open,
        child_total: 14,
        child_closed: 9
      },
      attrs
    )
  end

  describe "compact mode (board card chip)" do
    test "renders a ↳ chip of the parent id, linking to the parent's page" do
      html = render_component(&parent_link/1, parent: epic(), mode: "compact")

      assert html =~ "↳"
      assert html =~ "bd-cv1inp"
      assert html =~ ~s(href="/tasks/bd-cv1inp")
      assert html =~ ~s(data-role="parent-chip")
    end

    test "keeps the parent's title and progress in the tooltip, not on the card" do
      html = render_component(&parent_link/1, parent: epic(), mode: "compact")

      assert html =~ ~s(title="Browser coordinator sessions — 9/14 closed")
      # The chip itself is the id and nothing else: a board card has no room
      # for a second title.
      refute html =~ ">Browser coordinator sessions<"
    end

    test "a non-epic parent's tooltip is just its title — it has no progress to show" do
      html =
        render_component(&parent_link/1,
          parent: epic(%{issue_type: :task, title: "Split the importer"}),
          mode: "compact"
        )

      assert html =~ ~s(title="Split the importer")
      refute html =~ "9/14 closed"
    end

    test "falls back to the id when the parent has no title" do
      html =
        render_component(&parent_link/1,
          parent: %{id: "bd-x", title: nil},
          mode: "compact"
        )

      assert html =~ "bd-x"
    end
  end

  describe "full mode (child detail banner)" do
    test "renders ↳ Part of <id> — <title> • <closed>/<total> closed, linked" do
      html = render_component(&parent_link/1, parent: epic(), mode: "full")

      assert html =~ "↳"
      assert html =~ "Part of"
      assert html =~ "bd-cv1inp"
      assert html =~ "Browser coordinator sessions"
      assert html =~ "9/14 closed"
      assert html =~ ~s(href="/tasks/bd-cv1inp")
      assert html =~ ~s(data-role="parent-banner")
    end

    test "full is the default mode" do
      assert render_component(&parent_link/1, parent: epic()) =~ "Part of"
    end

    # Edge case: a `parent_of` edge whose parent is a plain task with subtasks.
    test "a non-epic parent reads 'Child of' and carries no progress" do
      html =
        render_component(&parent_link/1,
          parent: epic(%{issue_type: :task}),
          mode: "full"
        )

      assert html =~ "Child of"
      refute html =~ "Part of"
      refute html =~ "closed"
      refute html =~ ~s(data-role="parent-progress")
    end

    # Edge case: the epic is done. The banner is still true, so it still
    # renders — muted, and finished rather than partway.
    test "a closed epic is muted and reads n/n closed ✓" do
      html =
        render_component(&parent_link/1,
          parent: epic(%{status: :closed, child_total: 14, child_closed: 14}),
          mode: "full"
        )

      assert html =~ "14/14 closed ✓"
      assert html =~ ~s(data-closed="true")
      assert html =~ "var(--text-label)"
    end

    # Edge case: the parent lives in another workspace — the same marker the
    # relationships panel uses for a cross-workspace edge.
    test "a cross-workspace parent gets a workspace tag and the ⧉ marker" do
      html =
        render_component(&parent_link/1,
          parent: epic(%{workspace_name: "vstim"}),
          mode: "full"
        )

      assert html =~ ~s(data-role="cross-workspace-marker")
      assert html =~ "⧉"
      assert html =~ "workspace: vstim"
    end

    test "no workspace tag when the parent is in the same workspace" do
      html = render_component(&parent_link/1, parent: epic(), mode: "full")

      refute html =~ ~s(data-role="cross-workspace-marker")
    end

    # Design §7: the sibling position is shown only when it is a real fact.
    test "shows the sibling position when one was resolved" do
      html =
        render_component(&parent_link/1,
          parent: epic(%{position: {3, 14}}),
          mode: "full"
        )

      assert html =~ "3 of 14"
      assert html =~ ~s(data-role="parent-position")
    end

    test "omits the sibling position entirely when it is ambiguous" do
      html = render_component(&parent_link/1, parent: epic(%{position: nil}), mode: "full")

      refute html =~ ~s(data-role="parent-position")
      refute html =~ " of 14"
    end
  end

  describe "parent_links/1 — the stacked list" do
    test "renders one banner per parent, in the order given" do
      html =
        render_component(&parent_links/1,
          parents: [epic(%{id: "bd-new", title: "Newer"}), epic(%{id: "bd-old", title: "Older"})]
        )

      assert html =~ "bd-new"
      assert html =~ "bd-old"

      assert :binary.match(html, "bd-new") < :binary.match(html, "bd-old")
    end

    test "renders nothing at all when there are no parents" do
      html = render_component(&parent_links/1, parents: [])

      refute html =~ "parent-banner"
    end
  end
end
