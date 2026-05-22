defmodule ArbiterWeb.WorkspaceVernacularLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Beads.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "vern-ui-test-#{System.unique_integer([:positive])}",
        prefix: "vu"
      })

    {:ok, ws: ws}
  end

  describe "mount" do
    test "renders the JSON editor + preview", %{conn: conn, ws: ws} do
      {:ok, _view, html} = live(conn, "/workspace/#{ws.id}/settings/vernacular")

      assert html =~ "Vernacular settings"
      assert html =~ ws.name
      # Default fallback values render in the preview when no overrides.
      assert html =~ "polecat"
      assert html =~ "mayor"
      assert html =~ "JSON editor"
    end

    test "missing workspace redirects to /", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               live(conn, "/workspace/01000000-0000-7000-0000-000000000000/settings/vernacular")
    end
  end

  describe "live editing" do
    test "valid JSON updates the preview without saving", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, "/workspace/#{ws.id}/settings/vernacular")

      new_json = ~s({"worker": "Acolyte"})

      render_change(view, "update_json", %{"vernacular" => %{"json" => new_json}})

      assert render(view) =~ "Acolyte"
      # Other keys still fall back to defaults
      assert render(view) =~ "mayor"
    end

    test "invalid JSON shows error, no save", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, "/workspace/#{ws.id}/settings/vernacular")

      bad = ~s({"worker": )

      html = render_change(view, "update_json", %{"vernacular" => %{"json" => bad}})

      assert html =~ "invalid JSON"
    end
  end

  describe "save" do
    test "save writes vernacular to workspace.config", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, "/workspace/#{ws.id}/settings/vernacular")

      new_json = ~s({"worker": "Captain", "coordinator": "Admiral"})

      render_change(view, "update_json", %{"vernacular" => %{"json" => new_json}})
      render_submit(view, "save", %{})

      ws_reloaded = Ash.get!(Workspace, ws.id)
      assert ws_reloaded.config["vernacular"]["worker"] == "Captain"
      assert ws_reloaded.config["vernacular"]["coordinator"] == "Admiral"
    end

    test "save with invalid JSON doesn't persist", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, "/workspace/#{ws.id}/settings/vernacular")

      render_change(view, "update_json", %{"vernacular" => %{"json" => "{nope"}})
      render_submit(view, "save", %{})

      ws_reloaded = Ash.get!(Workspace, ws.id)
      assert (ws_reloaded.config["vernacular"] || %{}) == %{}
    end

    test "save with non-object JSON (e.g. a string) is rejected", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, "/workspace/#{ws.id}/settings/vernacular")

      render_change(view, "update_json", %{"vernacular" => %{"json" => ~s("just a string")}})
      render_submit(view, "save", %{})

      assert render(view) =~ "must be an object"
      ws_reloaded = Ash.get!(Workspace, ws.id)
      assert (ws_reloaded.config["vernacular"] || %{}) == %{}
    end
  end

  describe "reset to defaults" do
    test "loads defaults into the editor and preview", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, "/workspace/#{ws.id}/settings/vernacular")

      # First, set something
      render_change(view, "update_json", %{"vernacular" => %{"json" => ~s({"worker": "X"})}})
      assert render(view) =~ "X"

      # Reset
      html = render_click(view, "reset", %{})

      # Default values now present
      assert html =~ "polecat"
      assert html =~ "mayor"
      # X is no longer the preview value
      refute String.contains?(html, ~s(>\nX\n))
    end
  end
end
