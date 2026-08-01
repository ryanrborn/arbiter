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

    test "edits name and prefix via the details form, validated like the API", %{conn: conn} do
      ws = new_workspace(%{name: "old-name", prefix: "old"})

      {:ok, view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert html =~ "does not rename existing issue IDs"

      html =
        view
        |> form("form[phx-submit=save_details]", %{
          "details" => %{"name" => "new-name", "prefix" => "newpfx"}
        })
        |> render_submit()

      assert html =~ "new-name"
      assert html =~ "newpfx"

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.name == "new-name"
      assert reloaded.prefix == "newpfx"

      # Reuses the backend's own changeset validation for the prefix format.
      html =
        view
        |> form("form[phx-submit=save_details]", %{
          "details" => %{"name" => "new-name", "prefix" => "Bad-Prefix!"}
        })
        |> render_submit()

      assert html =~ "must match"

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.prefix == "newpfx"
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

    test "saves merge.* settings (auto_merge, pr_title_format, watchdog_max_polls, watch_pipeline, auto_sync_primary) through patch_config",
         %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "static",
          "merge_auto_merge" => "true",
          "merge_pr_title_format" => "conventional_commit",
          "merge_watchdog_max_polls" => "40",
          "merge_watch_pipeline" => "true",
          "merge_auto_sync_primary" => "true"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["merge"]["strategy"] == "direct"
      assert reloaded.config["merge"]["auto_merge"] == true
      assert reloaded.config["merge"]["pr_title_format"] == "conventional_commit"
      assert reloaded.config["merge"]["watchdog_max_polls"] == "40"
      assert reloaded.config["merge"]["watch_pipeline"] == true
      assert reloaded.config["merge"]["auto_sync_primary"] == true
    end

    test "blank merge.pr_title_format/watchdog_max_polls unset rather than writing empty strings",
         %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "merge" => %{
              "strategy" => "direct",
              "pr_title_format" => "conventional_commit",
              "watchdog_max_polls" => "40",
              "config" => %{"owner" => "acme", "repo" => "widgets"}
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "static",
          "merge_pr_title_format" => "",
          "merge_watchdog_max_polls" => "  "
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      refute Map.has_key?(reloaded.config["merge"], "pr_title_format")
      refute Map.has_key?(reloaded.config["merge"], "watchdog_max_polls")
      assert reloaded.config["merge"]["auto_merge"] == false
      assert reloaded.config["merge"]["watch_pipeline"] == false
      assert reloaded.config["merge"]["auto_sync_primary"] == false
      # Sibling merge.config (adapter-specific, set via `arb config set`) is
      # untouched by the dashboard's merge.* patch.
      assert reloaded.config["merge"]["config"] == %{"owner" => "acme", "repo" => "widgets"}
    end

    test "saves review_gate.* and review_automation.* settings through patch_config", %{
      conn: conn
    } do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "static",
          "review_gate_max_rounds" => "3",
          "review_gate_timeout_ms" => "1800000",
          "review_automation_default" => "propose",
          "review_automation_auto_authors" => "alice, bob ,, carol"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["review_gate"]["max_rounds"] == "3"
      assert reloaded.config["review_gate"]["timeout_ms"] == "1800000"
      assert reloaded.config["review_automation"]["default"] == "propose"
      assert reloaded.config["review_automation"]["auto_authors"] == ["alice", "bob", "carol"]
    end

    test "blank review_gate/review_automation fields unset rather than writing empty values", %{
      conn: conn
    } do
      ws =
        new_workspace(%{
          config: %{
            "review_gate" => %{"max_rounds" => "3", "timeout_ms" => "1800000"},
            "review_automation" => %{"default" => "propose", "auto_authors" => ["alice"]}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "static",
          "review_gate_max_rounds" => "",
          "review_gate_timeout_ms" => "  ",
          "review_automation_default" => "",
          "review_automation_auto_authors" => ""
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      refute Map.has_key?(reloaded.config["review_gate"] || %{}, "max_rounds")
      refute Map.has_key?(reloaded.config["review_gate"] || %{}, "timeout_ms")
      refute Map.has_key?(reloaded.config["review_automation"] || %{}, "default")
      refute Map.has_key?(reloaded.config["review_automation"] || %{}, "auto_authors")
    end

    test "adds and removes review_automation.repo_overrides entries", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=add_repo_override]", %{
        "repo_override" => %{"repo" => "acme/widgets", "mode" => "auto"}
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["review_automation"]["repo_overrides"] == %{"acme/widgets" => "auto"}

      view
      |> element("button[phx-click=rm_repo_override][phx-value-repo='acme/widgets']")
      |> render_click()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["review_automation"]["repo_overrides"] == %{}
    end

    test "renders agent.type and review_agent.type as an ordered precedence list", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{"type" => ["claude", "gemini"]},
            "review_agent" => %{"type" => "gemini"}
          }
        })

      {:ok, _view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert html =~ ~s(phx-value-role="agent")
      assert html =~ ~s(phx-value-role="review_agent")

      # Selected providers render in config order (claude first, then gemini).
      claude_idx = :binary.match(html, "claude") |> elem(0)
      gemini_idx = :binary.match(html, "gemini") |> elem(0)
      assert claude_idx < gemini_idx

      # Codex isn't selected for the worker agent, so it shows as an add button.
      assert html =~ ~s(phx-click="add_agent_type" phx-value-role="agent" phx-value-type="codex")
    end

    test "adds, reorders, and removes agent.type providers, persisting order", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      render_click(view, "add_agent_type", %{"role" => "agent", "type" => "gemini"})
      render_click(view, "add_agent_type", %{"role" => "agent", "type" => "codex"})

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["agent"]["type"] == ["gemini", "codex"]

      # Move codex to the front.
      render_click(view, "move_agent_type", %{"role" => "agent", "type" => "codex", "dir" => "up"})

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["agent"]["type"] == ["codex", "gemini"]

      render_click(view, "remove_agent_type", %{"role" => "agent", "type" => "codex"})

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["agent"]["type"] == "gemini"
    end

    test "removing the last agent.type falls back to claude, review_agent.type unsets", %{
      conn: conn
    } do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{"type" => "gemini"},
            "review_agent" => %{"type" => "gemini"}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      render_click(view, "remove_agent_type", %{"role" => "agent", "type" => "gemini"})
      render_click(view, "remove_agent_type", %{"role" => "review_agent", "type" => "gemini"})

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["agent"]["type"] == "claude"
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

    test "sets, reveals, toggles, and removes a secret worker env var", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      render_click(view, "open_worker_env_modal", %{})

      html =
        view
        |> form("form[phx-submit=set_worker_env]", %{
          "worker_env" => %{
            "key" => "API_TOKEN",
            "value" => "tok-supersecret",
            "secret" => "true"
          }
        })
        |> render_submit()

      # Stored encrypted with the secret flag; masked (never echoed) in the UI.
      assert html =~ "API_TOKEN"
      refute html =~ "tok-supersecret"
      assert html =~ "••••••••"

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.worker_env_map(reloaded) == %{"API_TOKEN" => "tok-supersecret"}
      assert Workspace.worker_env_keys(reloaded) == [%{name: "API_TOKEN", secret?: true}]

      # Explicit reveal shows the decrypted value.
      html = render_click(view, "reveal_worker_env", %{"key" => "API_TOKEN"})
      assert html =~ "tok-supersecret"

      # Toggling to plain flips the flag without touching the value...
      render_click(view, "toggle_worker_env_secret", %{"key" => "API_TOKEN"})
      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.worker_env_keys(reloaded) == [%{name: "API_TOKEN", secret?: false}]
      assert Workspace.worker_env_map(reloaded) == %{"API_TOKEN" => "tok-supersecret"}

      # ...and removal clears it.
      render_click(view, "rm_worker_env", %{"key" => "API_TOKEN"})
      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.worker_env_map(reloaded) == %{}
      assert Workspace.worker_env_keys(reloaded) == []
    end

    test "rejects an invalid worker env var name", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      render_click(view, "open_worker_env_modal", %{})

      html =
        view
        |> form("form[phx-submit=set_worker_env]", %{
          "worker_env" => %{"key" => "9-bad", "value" => "v"}
        })
        |> render_submit()

      assert html =~ "must match"

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert Workspace.worker_env_map(reloaded) == %{}
    end
  end
end
