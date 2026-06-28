defmodule ArbiterWeb.WorkspaceLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.Workspace

  defp new_workspace(attrs \\ %{}) do
    base = %{name: "ws-#{System.unique_integer([:positive])}", prefix: "wx"}
    {:ok, ws} = Ash.create(Workspace, Map.merge(base, attrs))
    ws
  end

  describe "index" do
    test "lists workspaces with prefix and tracker", %{conn: conn} do
      ws =
        new_workspace(%{config: %{"tracker" => %{"type" => "github"}}})

      {:ok, _view, html} = live(conn, ~p"/workspaces")

      assert html =~ ws.name
      assert html =~ "tracker: github"
      assert html =~ ~s(id="workspaces")
    end

    test "creates a workspace via the inline form and navigates to detail", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workspaces")

      name = "created-#{System.unique_integer([:positive])}"

      view
      |> element("button", "New workspace")
      |> render_click()

      {:ok, _detail, html} =
        view
        |> form("form[phx-submit=create]", %{
          "workspace" => %{
            "name" => name,
            "prefix" => "cr",
            "tracker_type" => "none",
            "merger_strategy" => "direct"
          }
        })
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ name
      assert html =~ "cr"
    end
  end

  describe "detail" do
    test "renders 404 for an unknown workspace", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workspaces/#{Ash.UUID.generate()}")
      assert html =~ "Workspace not found"
    end

    test "adds and removes a standing order", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=add_order]", %{"order" => %{"text" => "Review the diff twice"}})
        |> render_submit()

      assert html =~ "Review the diff twice"

      # Persisted in config.
      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["standing_orders"] == ["Review the diff twice"]

      render_click(view, "rm_order", %{"index" => "0"})

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["standing_orders"] == []
    end

    test "saves configuration enums through patch_config", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "agent_type" => "claude",
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "by_priority",
          "review_required" => "true"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["routing"]["policy"] == "by_priority"
      assert reloaded.config["review"]["required"] == true
    end

    test "sets and removes a secret without ever echoing its value", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      render_click(view, "open_secret_modal", %{})

      html =
        view
        |> form("form[phx-submit=set_secret]", %{
          "secret" => %{"key" => "tracker_token", "value" => "super-secret-value"}
        })
        |> render_submit()

      assert html =~ "tracker_token"
      refute html =~ "super-secret-value"

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.secrets_map(reloaded) == %{"tracker_token" => "super-secret-value"}

      render_click(view, "rm_secret", %{"key" => "tracker_token"})

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.secrets_map(reloaded) == %{}
    end
  end
end
