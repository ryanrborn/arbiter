defmodule ArbiterWeb.WorkspaceDetailComponentsTest do
  @moduledoc """
  Structural guarantees for the workspace detail page after it was decomposed
  into per-section `Phoenix.LiveComponent`s.

  The behavioural suite lives in `ArbiterWeb.WorkspaceLiveTest` and is
  deliberately left untouched — it drives the page through the same DOM
  selectors before and after the split, so it is the regression net. What it
  *cannot* see is who handles an event: a page where the parent LiveView still
  owns all 34 clauses renders byte-identically. These tests pin that down.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.Workspace

  # Every section component the page is built from.
  @components [
    ArbiterWeb.WorkspaceDetail.PolicyConfigComponent,
    ArbiterWeb.WorkspaceDetail.TrackerConfigComponent,
    ArbiterWeb.WorkspaceDetail.RepoPathsComponent,
    ArbiterWeb.WorkspaceDetail.RepoOverridesComponent,
    ArbiterWeb.WorkspaceDetail.RoutingRulesComponent,
    ArbiterWeb.WorkspaceDetail.RoutingAdaptersComponent,
    ArbiterWeb.WorkspaceDetail.AgentModelConfigComponent,
    ArbiterWeb.WorkspaceDetail.WorkerSecurityComponent,
    ArbiterWeb.WorkspaceDetail.StandingOrdersComponent,
    ArbiterWeb.WorkspaceDetail.SecretsComponent,
    ArbiterWeb.WorkspaceDetail.WorkerEnvVarsComponent
  ]

  # The events that must be owned by a component rather than the parent.
  @component_events ~w[
    save_config preview_tracker_type add_agent_type remove_agent_type move_agent_type
    save_tracker_config
    add_repo_path rm_repo_path
    add_repo_override rm_repo_override
    save_routing_rule rm_routing_rule
    add_routing_adapter rm_routing_adapter
    save_agent_config add_provider_override rm_provider_override
    save_security confirm_security cancel_security
    add_order rm_order
    open_secret_modal close_secret_modal set_secret rm_secret
    open_worker_env_modal close_worker_env_modal set_worker_env rm_worker_env
    toggle_worker_env_secret reveal_worker_env hide_worker_env
  ]

  # `save_details` is page identity rather than a settings section and stays on
  # the parent LiveView (see the module doc on WorkspaceDetailLive).
  @parent_events ~w[save_details]

  defp new_workspace(attrs \\ %{}) do
    base = %{name: "ws-#{System.unique_integer([:positive])}", prefix: "wx"}
    {:ok, ws} = Ash.create(Workspace, Map.merge(base, attrs))
    ws
  end

  # A workspace configured so that *every* section renders its full markup:
  # the conditional tracker block, and at least one row in each add/remove
  # list (rows carry the rm_* buttons).
  defp fully_populated_workspace do
    {:ok, ws} =
      new_workspace()
      |> Ash.update(
        %{
          patch: %{
            "tracker" => %{"type" => "github"},
            "repo_paths" => %{"arbiter" => "/tmp/arbiter"},
            "review_automation" => %{"repo_overrides" => %{"acme/arbiter" => "auto"}},
            "routing" => %{
              "rules" => %{"D4" => %{"model_tier" => "premium"}},
              "adapters" => [%{"model_tier" => "economy"}]
            },
            "agent" => %{
              # A two-provider pool so the reorder/remove buttons render.
              "type" => ["claude", "codex"],
              "config" => %{"claude" => %{"tier_models" => %{"premium" => "opus"}}}
            },
            "standing_orders" => ["check your inbox"]
          },
          unset_paths: []
        },
        action: :patch_config
      )

    {:ok, ws} = Ash.update(ws, %{secrets: %{"tracker_token" => "hunter2"}}, action: :update)

    {:ok, ws} =
      Ash.update(ws, %{worker_env: %{"API_TOKEN" => %{"value" => "t", "secret" => true}}},
        action: :update
      )

    ws
  end

  # Every `phx-click`/`phx-submit`/`phx-change` binding on the page that names
  # one of the events under test, paired with its `phx-target` (nil = handled
  # by the parent LiveView).
  defp event_bindings(html) do
    doc = LazyHTML.from_document(html)

    for attr <- ~w[phx-click phx-submit phx-change],
        node <- doc |> LazyHTML.query("[#{attr}]") |> Enum.to_list(),
        event = node |> LazyHTML.attribute(attr) |> List.first(),
        event in @component_events or event in @parent_events do
      {event, node |> LazyHTML.attribute("phx-target") |> List.first()}
    end
  end

  # A security submit that gives up a guard, so the confirmation modal (and
  # its confirm/cancel bindings) renders.
  defp security_downgrade_params do
    %{
      "security" => %{
        "mode" => "bypass",
        "sandbox_enabled" => "false",
        "sandbox_filesystem" => "worktree",
        "sandbox_network" => "true",
        "allow" => "",
        "deny" => "",
        "safe_defaults" => %{
          "no_destructive_fs" => "true",
          "no_force_push" => "true",
          "no_secret_reads" => "true",
          "no_outside_writes" => "true",
          "no_pr_create" => "true"
        }
      }
    }
  end

  describe "component decomposition" do
    test "each named section component exists and is a LiveComponent" do
      for mod <- @components do
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} does not exist"

        assert function_exported?(mod, :render, 1),
               "#{inspect(mod)} is not a Phoenix.LiveComponent (no render/1)"
      end
    end

    test "every section event is bound with phx-target so a component owns it", %{conn: conn} do
      ws = fully_populated_workspace()
      {:ok, view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      # The three modals and the security confirmation only exist once opened,
      # so the binding census is taken across every state the page can be in.
      secret_modal =
        view |> element("button[phx-click=open_secret_modal]") |> render_click()

      _ = view |> element("button[phx-click=close_secret_modal]") |> render_click()

      env_modal =
        view |> element("button[phx-click=open_worker_env_modal]") |> render_click()

      _ = view |> element("button[phx-click=close_worker_env_modal]") |> render_click()

      # `hide_worker_env` only exists once a secret value has been revealed.
      revealed =
        view
        |> element("button[phx-click=reveal_worker_env][phx-value-key=API_TOKEN]")
        |> render_click()

      security_confirm =
        view
        |> form("form[phx-submit=save_security]", security_downgrade_params())
        |> render_submit()

      bindings =
        [html, secret_modal, env_modal, revealed, security_confirm]
        |> Enum.flat_map(&event_bindings/1)
        |> Enum.uniq()

      found = bindings |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()

      assert Enum.sort(@component_events ++ @parent_events) -- found == [],
             "not every event is rendered on this page; missing: " <>
               inspect(Enum.sort(@component_events ++ @parent_events) -- found)

      untargeted =
        bindings
        |> Enum.filter(fn {event, target} -> event in @component_events and is_nil(target) end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.sort()

      assert untargeted == [],
             "these events are still handled by the parent LiveView: #{inspect(untargeted)}"

      # The converse: the one event the parent still owns must not be targeted
      # at a component.
      assert Enum.all?(bindings, fn {event, target} ->
               event not in @parent_events or is_nil(target)
             end)
    end

    test "the parent LiveView no longer implements the section events", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      # Routed straight at the LiveView (no phx-target), a section event has no
      # matching clause and takes the view down.
      Process.flag(:trap_exit, true)
      catch_exit(render_click(view, "rm_order", %{"index" => "0"}))
    end
  end

  describe "component-scoped error state" do
    test "a blank repo-override name reports inside the repo-overrides section", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=add_repo_override]", %{
          "repo_override" => %{"repo" => "  ", "mode" => "auto"}
        })
        |> render_submit()

      assert html =~ "Repo override name can&#39;t be empty."
    end

    test "a blank repo path reports inside the repo-paths section", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=add_repo_path]", %{
          "repo_path" => %{"repo" => "arbiter", "path" => "  "}
        })
        |> render_submit()

      assert html =~ "Repo path can&#39;t be empty."
    end

    test "an empty routing adapter reports inside the adapters section", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=add_routing_adapter]", %{
          "adapter" => %{"model_tier" => "", "thinking" => "", "model" => ""}
        })
        |> render_submit()

      assert html =~ "Adapter entry can&#39;t be empty."
    end

    test "a blank routing rule key reports inside the rules section", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=save_routing_rule]", %{
          "rule" => %{"key" => "", "model_tier" => "premium"}
        })
        |> render_submit()

      assert html =~ "Rule key can&#39;t be empty."
    end
  end

  describe "cross-component wiring" do
    test "a secret set in the secrets section appears in both credentials selects", %{conn: conn} do
      ws = new_workspace(%{config: %{"tracker" => %{"type" => "github"}}})
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view |> element("button[phx-click=open_secret_modal]") |> render_click()

      html =
        view
        |> form("form[phx-submit=set_secret]", %{
          "secret" => %{"key" => "gh_token", "value" => "shhh"}
        })
        |> render_submit()

      # The section that wrote shows the key straight away...
      assert html =~ "gh_token"

      # ...and the sections that only *read* it pick it up from the
      # `{:workspace_updated, _}` the write hands the parent, which is the
      # next diff — hence re-rendering rather than asserting on `html`.
      assert render(view) =~ "secret:gh_token"

      assert has_element?(
               view,
               "select[name='agent_config[credentials_ref]'] option[value='secret:gh_token']"
             )

      assert has_element?(
               view,
               "select[name='tracker_config[credentials_ref]'] option[value='secret:gh_token']"
             )
    end

    test "a workspace write in one section is visible to the others", %{conn: conn} do
      ws = new_workspace(%{config: %{"tracker" => %{"type" => "none"}}})
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      refute has_element?(view, "form[phx-submit=save_tracker_config]")

      # Saving the config form in the policy component must re-render the
      # tracker component the parent owns.
      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "tracker_type" => "github",
          "merger_strategy" => "direct",
          "routing_policy" => "static"
        }
      })
      |> render_submit()

      assert has_element?(view, "form[phx-submit=save_tracker_config]")
      assert has_element?(view, "input[name='tracker_config[owner]']")
    end

    test "a successful save still raises a page-level flash", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=save_config]", %{
          "config" => %{
            "tracker_type" => "none",
            "merger_strategy" => "direct",
            "routing_policy" => "static"
          }
        })
        |> render_submit()

      # Flash is page-level state a LiveComponent cannot reach: its own
      # `@flash` is seeded empty and only merged into the parent's on
      # redirect, so sections `send/2` the message up and it lands in the
      # parent's next diff. See ArbiterWeb.WorkspaceDetail.Shared.
      refute html =~ "Configuration saved."
      assert render(view) =~ "Configuration saved."
    end
  end

  describe "a section reflects its own write" do
    # Before the split one LiveView owned both the write and the render, so a
    # saved value was already in the diff that answered the submit. A section
    # that writes now has to reload its *own* derived assigns to keep that
    # true: the `{:workspace_updated, _}` it sends the parent is a second
    # round trip, and leaning on it would leave the operator looking at a
    # stale section for a frame.

    test "standing orders shows the added order", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=add_order]", %{"order" => %{"text" => "Review the diff twice"}})
        |> render_submit()

      assert html =~ "Review the diff twice"
    end

    test "repo paths shows the added path", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=add_repo_path]", %{
          "repo_path" => %{"repo" => "arbiter", "path" => "/tmp/arbiter"}
        })
        |> render_submit()

      assert html =~ "/tmp/arbiter"
    end

    test "repo overrides shows the added override", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=add_repo_override]", %{
          "repo_override" => %{"repo" => "acme/arbiter", "mode" => "auto"}
        })
        |> render_submit()

      assert html =~ "acme/arbiter"
    end

    test "routing rules shows the saved rule", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=save_routing_rule]", %{
          "rule" => %{"key" => "D4", "model_tier" => "premium", "thinking" => "", "model" => ""}
        })
        |> render_submit()

      assert html =~ "model_tier=premium"
    end

    test "routing adapters shows the added adapter", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=add_routing_adapter]", %{
          "adapter" => %{"model_tier" => "economy", "thinking" => "", "model" => ""}
        })
        |> render_submit()

      assert html =~ "model_tier=economy"
    end

    test "secrets shows the stored key", %{conn: conn} do
      ws = new_workspace()
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view |> element("button[phx-click=open_secret_modal]") |> render_click()

      html =
        view
        |> form("form[phx-submit=set_secret]", %{
          "secret" => %{"key" => "gh_token", "value" => "shhh"}
        })
        |> render_submit()

      assert html =~ "gh_token"
    end

    test "the policy section reveals the tracker fields its own save selected", %{conn: conn} do
      ws = new_workspace(%{config: %{"tracker" => %{"type" => "none"}}})
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      # TrackerConfigComponent is rendered *by* the policy section off the
      # tracker type the policy form just wrote, so a stale derived assign
      # here hides the adapter fields the operator just asked for.
      html =
        view
        |> form("form[phx-submit=save_config]", %{
          "config" => %{
            "tracker_type" => "github",
            "merger_strategy" => "direct",
            "routing_policy" => "static"
          }
        })
        |> render_submit()

      assert html =~ "save_tracker_config"
    end
  end
end
