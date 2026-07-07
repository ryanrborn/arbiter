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
          "agent_types" => ["claude"],
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

    test "displays agent.type and review_agent.type provider checkboxes", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{"type" => ["claude", "gemini"]},
            "review_agent" => %{"type" => "gemini"}
          }
        })

      {:ok, _view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert html =~ ~s(name="config[agent_types][]")
      assert html =~ ~s(name="config[review_agent_types][]")

      # Both agent.type providers checked.
      assert html =~
               ~s(name="config[agent_types][]" value="claude" checked)

      assert html =~
               ~s(name="config[agent_types][]" value="gemini" checked)

      # Only the configured review_agent.type provider is checked.
      assert html =~
               ~s(name="config[review_agent_types][]" value="gemini" checked)
    end

    test "saves a multi-provider pool for agent.type", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "agent_types" => ["claude", "gemini"],
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "static",
          "review_required" => "false"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["agent"]["type"] == ["claude", "gemini"]
    end

    test "saves a single review_agent.type and can clear it back to fallback", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "agent_types" => ["claude"],
          "review_agent_types" => ["gemini"],
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "static",
          "review_required" => "false"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["review_agent"]["type"] == "gemini"

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "agent_types" => ["claude"],
          "review_agent_types" => [],
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "static",
          "review_required" => "false"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      refute Map.has_key?(reloaded.config["review_agent"] || %{}, "type")
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
