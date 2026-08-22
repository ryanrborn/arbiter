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
    test "lists skills and auto-selects the first one into the detail pane", %{conn: conn} do
      skill = new_skill(%{metadata: %{"description" => "does a thing"}})

      {:ok, _view, html} = live(conn, ~p"/skills")

      assert html =~ skill.name
      assert html =~ "does a thing"
      assert html =~ ~s(id="skills-list")
      assert html =~ ~s(id="skill-detail")
    end

    test "shows empty state with no skills", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/skills")
      assert html =~ "No skills yet"
    end

    test "flags a name that collides with a bundled skill", %{conn: conn} do
      new_skill(%{name: "code-review"})

      {:ok, _view, html} = live(conn, ~p"/skills")

      assert html =~ "Collides with a bundled skill name"
    end
  end

  describe "detail selection" do
    test "clicking a list item selects it into the detail pane", %{conn: conn} do
      _first = new_skill(%{name: "aaa-skill"})
      second = new_skill(%{name: "zzz-skill", metadata: %{"description" => "second one"}})

      {:ok, view, _html} = live(conn, ~p"/skills")

      html =
        view
        |> element("#skill-row-#{second.id}")
        |> render_click()

      assert html =~ "second one"
    end

    test "detail pane shows materialized/invoked/invoke-rate/scope and toggles with consequence hints",
         %{conn: conn} do
      skill = new_skill(%{code_only: true})

      {:ok, _view, html} = live(conn, ~p"/skills")

      assert html =~ "materialized"
      assert html =~ "invoked"
      assert html =~ "invoke rate"
      assert html =~ "scope"
      assert html =~ "feature · bug · chore"
      assert html =~ "Auto-invoke"
      assert html =~ "added to every worker prompt where it applies"
      assert html =~ "Code-producing tasks only"
      assert html =~ "skipped on decision and epic types"
      assert html =~ skill.name
    end

    test "shows the never-invoked EmptyState when invoke count is zero", %{conn: conn} do
      new_skill()

      {:ok, _view, html} = live(conn, ~p"/skills")

      assert html =~ "This skill has never been invoked. The loop pass will propose retiring it."
      assert html =~ "materialized 0 times, invoked 0"
    end
  end

  describe "toggles write through to the skill record" do
    test "toggling auto-invoke flips activation_mode on the skill", %{conn: conn} do
      skill = new_skill(%{activation_mode: :situational})

      {:ok, view, _html} = live(conn, ~p"/skills")

      view
      |> element("#toggle-auto-invoke")
      |> render_click()

      {:ok, reloaded} = Skills.get_skill(skill.id)
      assert reloaded.activation_mode == :always_on
    end

    test "toggling code-producing-tasks-only flips code_only on the skill", %{conn: conn} do
      skill = new_skill(%{code_only: false})

      {:ok, view, _html} = live(conn, ~p"/skills")

      view
      |> element("#toggle-code-only")
      |> render_click()

      {:ok, reloaded} = Skills.get_skill(skill.id)
      assert reloaded.code_only == true
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

      assert html =~ name
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
    test "edits the selected skill's body from the detail pane", %{conn: conn} do
      skill = new_skill(%{body: "v1"})

      {:ok, view, _html} = live(conn, ~p"/skills")

      view |> element("#skill-detail button", "Edit") |> render_click()

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
    test "deletes the selected skill from the detail pane", %{conn: conn} do
      skill = new_skill()

      {:ok, view, _html} = live(conn, ~p"/skills")

      view
      |> element("#skill-detail button[phx-click=delete][phx-value-id='#{skill.id}']")
      |> render_click()

      assert {:error, :not_found} = Skills.get_skill(skill.id)
    end
  end
end
