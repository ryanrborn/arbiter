defmodule ArbiterWeb.SkillIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Skills

  defp new_skill(attrs \\ %{}) do
    base = %{name: "skill-#{System.unique_integer([:positive])}", body: "# body"}
    {:ok, skill} = Skills.create_skill(Map.merge(base, attrs))
    skill
  end

  describe "index" do
    test "lists skills", %{conn: conn} do
      skill = new_skill(%{metadata: %{"description" => "does a thing"}})

      {:ok, _view, html} = live(conn, ~p"/skills")

      assert html =~ "/#{skill.name}"
      assert html =~ "does a thing"
      assert html =~ ~s(id="skills")
    end

    test "shows empty state with no skills", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/skills")
      assert html =~ "No skills yet"
    end
  end

  describe "create" do
    test "creates a skill via the textarea form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills")

      name = "created-#{System.unique_integer([:positive])}"

      view |> element("button", "New skill") |> render_click()

      html =
        view
        |> form("form[phx-submit=save]", %{
          "skill" => %{"name" => name, "body" => "# hello", "metadata" => ""}
        })
        |> render_submit()

      assert html =~ "/#{name}"
      assert {:ok, _} = Skills.get_skill(name)
    end

    test "surfaces a validation error inline", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills")

      view |> element("button", "New skill") |> render_click()

      html =
        view
        |> form("form[phx-submit=save]", %{
          "skill" => %{"name" => "Not Kebab", "body" => "x", "metadata" => ""}
        })
        |> render_submit()

      # Form stays open with an error; the skill was not created.
      assert html =~ "text-error"
      assert Skills.list_skills() == []
    end

    test "warns (does not block) on bundled-name collision via change validation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/skills")

      view |> element("button", "New skill") |> render_click()

      html =
        view
        |> form("form[phx-submit=save]", %{
          "skill" => %{"name" => "code-review", "body" => "x", "metadata" => ""}
        })
        |> render_change()

      assert html =~ "collides with a bundled skill"
    end
  end

  describe "edit" do
    test "edits an existing skill's body", %{conn: conn} do
      skill = new_skill(%{body: "v1"})

      {:ok, view, _html} = live(conn, ~p"/skills")

      view |> element("button", "Edit") |> render_click()

      view
      |> form("form[phx-submit=save]", %{
        "skill" => %{"name" => skill.name, "body" => "v2-updated", "metadata" => ""}
      })
      |> render_submit()

      {:ok, reloaded} = Skills.get_skill(skill.id)
      assert reloaded.body == "v2-updated"
    end
  end

  describe "delete" do
    test "deletes a skill", %{conn: conn} do
      skill = new_skill()

      {:ok, view, _html} = live(conn, ~p"/skills")

      view
      |> element("button[phx-click=delete][phx-value-id='#{skill.id}']")
      |> render_click()

      assert {:error, :not_found} = Skills.get_skill(skill.id)
    end
  end
end
