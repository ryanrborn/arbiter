defmodule ArbiterWeb.WorkspaceLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Workspace

  defp new_workspace(attrs \\ %{}) do
    base = %{name: "ws-#{System.unique_integer([:positive])}", prefix: "wx"}
    {:ok, ws} = Ash.create(Workspace, Map.merge(base, attrs))
    ws
  end

  # The security form posts every field on every submit (checkboxes carry a
  # hidden "false" companion), so tests spell out the full baseline — the
  # posture a fresh workspace already resolves to — and override only the
  # field under test. Keeps "what changed" obvious at the call site.
  @security_baseline %{
    "mode" => "bypass",
    "sandbox_enabled" => "true",
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

  defp security_params(overrides) do
    merged =
      Map.merge(@security_baseline, overrides, fn
        "safe_defaults", base, override -> Map.merge(base, override)
        _key, _base, override -> override
      end)

    %{"security" => merged}
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

    test "saves routing.base_policy and routing.budget_usd_per_day through patch_config", %{
      conn: conn
    } do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "by_budget",
          "routing_base_policy" => "by_difficulty",
          "routing_budget_usd_per_day" => "12.5"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["routing"]["policy"] == "by_budget"
      assert reloaded.config["routing"]["base_policy"] == "by_difficulty"
      assert reloaded.config["routing"]["budget_usd_per_day"] == 12.5
    end

    test "blank routing.base_policy/budget_usd_per_day unset rather than writing empty values", %{
      conn: conn
    } do
      ws =
        new_workspace(%{
          config: %{
            "routing" => %{
              "policy" => "by_budget",
              "base_policy" => "by_difficulty",
              "budget_usd_per_day" => 12.5
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "by_budget",
          "routing_base_policy" => "",
          "routing_budget_usd_per_day" => "  "
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["routing"]["policy"] == "by_budget"
      refute Map.has_key?(reloaded.config["routing"], "base_policy")
      refute Map.has_key?(reloaded.config["routing"], "budget_usd_per_day")
    end

    test "rejects a non-numeric routing.budget_usd_per_day", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=save_config]", %{
          "config" => %{
            "tracker_type" => "none",
            "merger_strategy" => "direct",
            "routing_policy" => "by_budget",
            "routing_budget_usd_per_day" => "not-a-number"
          }
        })
        |> render_submit()

      assert html =~ "must be a number"
      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      refute Map.has_key?(reloaded.config["routing"] || %{}, "budget_usd_per_day")
    end

    test "adds, edits, and removes routing.rules entries (D0..D4 keyed rules)", %{conn: conn} do
      ws = new_workspace(%{config: %{"routing" => %{"policy" => "by_difficulty"}}})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_routing_rule]", %{
        "rule" => %{
          "key" => "D4",
          "model_tier" => "flagship",
          "thinking" => "xhigh",
          "model" => ""
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)

      assert reloaded.config["routing"]["rules"]["D4"] == %{
               "model_tier" => "flagship",
               "thinking" => "xhigh"
             }

      # routing.policy is untouched by the rule sub-form.
      assert reloaded.config["routing"]["policy"] == "by_difficulty"

      # Editing replaces the rule wholesale rather than merging stale fields.
      view
      |> form("form[phx-submit=save_routing_rule]", %{
        "rule" => %{"key" => "D4", "model_tier" => "premium", "thinking" => "", "model" => ""}
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["routing"]["rules"]["D4"] == %{"model_tier" => "premium"}

      view
      |> element("button[phx-click=rm_routing_rule][phx-value-key='D4']")
      |> render_click()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      refute Map.has_key?(reloaded.config["routing"]["rules"] || %{}, "D4")
    end

    test "adds and removes routing.adapters entries", %{conn: conn} do
      ws = new_workspace(%{config: %{"routing" => %{"policy" => "round_robin"}}})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=add_routing_adapter]", %{
        "adapter" => %{"model_tier" => "economy", "thinking" => "", "model" => ""}
      })
      |> render_submit()

      view
      |> form("form[phx-submit=add_routing_adapter]", %{
        "adapter" => %{"model_tier" => "premium", "thinking" => "high", "model" => ""}
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)

      assert reloaded.config["routing"]["adapters"] == [
               %{"model_tier" => "economy"},
               %{"model_tier" => "premium", "thinking" => "high"}
             ]

      view
      |> element("button[phx-click=rm_routing_adapter][phx-value-index='0']")
      |> render_click()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)

      assert reloaded.config["routing"]["adapters"] == [
               %{"model_tier" => "premium", "thinking" => "high"}
             ]
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

    test "saves quota.* settings and conductor.max_concurrent through patch_config", %{
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
          "quota_on_exhaustion" => "continue",
          "quota_overage_alert_usd" => "50",
          "quota_throttle_threshold" => "0.8",
          "conductor_max_concurrent" => "4"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["quota"]["on_exhaustion"] == "continue"
      assert reloaded.config["quota"]["overage_alert_usd"] == "50"
      assert reloaded.config["quota"]["throttle_threshold"] == "0.8"
      assert reloaded.config["conductor"]["max_concurrent"] == "4"
    end

    test "blank quota/conductor fields unset rather than writing empty values", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "quota" => %{
              "on_exhaustion" => "continue",
              "overage_alert_usd" => "50",
              "throttle_threshold" => "0.8"
            },
            "conductor" => %{"max_concurrent" => "4"}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "static",
          "quota_on_exhaustion" => "",
          "quota_overage_alert_usd" => "  ",
          "quota_throttle_threshold" => "",
          "conductor_max_concurrent" => "  "
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      refute Map.has_key?(reloaded.config["quota"] || %{}, "on_exhaustion")
      refute Map.has_key?(reloaded.config["quota"] || %{}, "overage_alert_usd")
      refute Map.has_key?(reloaded.config["quota"] || %{}, "throttle_threshold")
      refute Map.has_key?(reloaded.config["conductor"] || %{}, "max_concurrent")
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

    test "removes a review_automation.repo_overrides entry whose repo name contains a dot", %{
      conn: conn
    } do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=add_repo_override]", %{
        "repo_override" => %{"repo" => "acme/widgets.js", "mode" => "auto"}
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)

      assert reloaded.config["review_automation"]["repo_overrides"] == %{
               "acme/widgets.js" => "auto"
             }

      view
      |> element("button[phx-click=rm_repo_override][phx-value-repo='acme/widgets.js']")
      |> render_click()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["review_automation"]["repo_overrides"] == %{}
    end

    test "saves agent.config.* model/tier_models/thinking_argv through patch_config", %{
      conn: conn
    } do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_agent_config]", %{
        "agent_config" => %{
          "model" => "opus",
          "credentials_ref" => "",
          "tier_economy" => "haiku",
          "tier_standard" => "sonnet",
          "tier_premium" => "opus",
          "thinking_low" => "--effort low",
          "thinking_medium" => "",
          "thinking_high" => "--effort  high"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      agent_config = reloaded.config["agent"]["config"]

      assert agent_config["model"] == "opus"

      assert agent_config["tier_models"] == %{
               "economy" => "haiku",
               "standard" => "sonnet",
               "premium" => "opus"
             }

      assert agent_config["thinking_argv"]["low"] == ["--effort", "low"]
      assert agent_config["thinking_argv"]["high"] == ["--effort", "high"]
      refute Map.has_key?(agent_config["thinking_argv"], "medium")
    end

    test "blank agent.config fields unset rather than writing empty values, preserving siblings",
         %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{
              "type" => "claude",
              "config" => %{
                "model" => "opus",
                "credentials_ref" => "secret:anthropic",
                "tier_models" => %{"standard" => "sonnet"},
                "thinking_argv" => %{"high" => ["--effort", "high"]},
                "vernacular" => "keep-me"
              }
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_agent_config]", %{
        "agent_config" => %{
          "model" => "  ",
          "credentials_ref" => "",
          "tier_economy" => "",
          "tier_standard" => "",
          "tier_premium" => "",
          "thinking_low" => "",
          "thinking_medium" => "",
          "thinking_high" => ""
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      agent_config = reloaded.config["agent"]["config"]

      refute Map.has_key?(agent_config, "model")
      refute Map.has_key?(agent_config, "credentials_ref")
      refute Map.has_key?(agent_config["tier_models"] || %{}, "standard")
      refute Map.has_key?(agent_config["thinking_argv"] || %{}, "high")
      # Keys this form doesn't own (CLI-only) survive the patch.
      assert agent_config["vernacular"] == "keep-me"
      assert reloaded.config["agent"]["type"] == "claude"
    end

    # Real workspaces carry tier/thinking keys the adapters don't define
    # ("flagship", "xhigh"). A fixed row list would hide them, leaving config
    # only `arb config set` can reach — and an operator editing a neighbouring
    # field would have no idea they were there.
    test "surfaces tier_models/thinking_argv keys outside the built-in set", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{
              "config" => %{
                "tier_models" => %{"flagship" => "fable"},
                "thinking_argv" => %{"xhigh" => ["--effort", "xhigh"], "none" => []}
              }
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, "input[name='agent_config[tier_flagship]'][value=fable]")
      assert has_element?(view, "input[name='agent_config[thinking_xhigh]']")
      # "none" is hardcoded in every adapter as "pass no argv", so an override
      # there is inert — no row, and the key is left alone.
      refute has_element?(view, "input[name='agent_config[thinking_none]']")

      view
      |> form("form[phx-submit=save_agent_config]", %{
        "agent_config" => %{"tier_flagship" => "opus", "thinking_xhigh" => ""}
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      agent_config = reloaded.config["agent"]["config"]
      assert agent_config["tier_models"]["flagship"] == "opus"
      refute Map.has_key?(agent_config["thinking_argv"], "xhigh")
      assert agent_config["thinking_argv"]["none"] == []
    end

    test "credentials_ref is a select over existing secret names, never a raw value field", %{
      conn: conn
    } do
      {:ok, ws} =
        Ash.update(new_workspace(), %{secrets: %{"anthropic_key" => "sk-live-not-echoed"}},
          action: :update
        )

      {:ok, view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, "select[name='agent_config[credentials_ref]']")
      refute has_element?(view, "input[name='agent_config[credentials_ref]']")
      assert html =~ "secret:anthropic_key"
      refute html =~ "sk-live-not-echoed"

      view
      |> form("form[phx-submit=save_agent_config]", %{
        "agent_config" => %{"credentials_ref" => "secret:anthropic_key"}
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["agent"]["config"]["credentials_ref"] == "secret:anthropic_key"
    end

    test "tracker adapter config shows fields for the persisted tracker type only", %{
      conn: conn
    } do
      ws = new_workspace(%{config: %{"tracker" => %{"type" => "jira"}}})

      {:ok, view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert html =~ "tracker_config[host]"
      assert html =~ "tracker_config[project_key]"
      refute has_element?(view, "input[name='tracker_config[owner]']")
      refute has_element?(view, "input[name='tracker_config[repo]']")
    end

    test "changing tracker type in the config form live-updates the adapter fields shown", %{
      conn: conn
    } do
      ws = new_workspace(%{config: %{"tracker" => %{"type" => "jira"}}})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form("form[phx-submit=save_config]", %{"config" => %{"tracker_type" => "github"}})
        |> render_change()

      assert html =~ "tracker_config[owner]"
      assert html =~ "tracker_config[repo]"
      refute html =~ "tracker_config[host]"
      refute html =~ "tracker_config[project_key]"
    end

    test "saves tracker.config.* fields for the current adapter type through patch_config", %{
      conn: conn
    } do
      ws = new_workspace(%{config: %{"tracker" => %{"type" => "jira"}}})

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_tracker_config]", %{
        "tracker_config" => %{
          "type" => "jira",
          "host" => "acme.atlassian.net",
          "project_key" => "ARB",
          "email" => "bot@acme.example",
          "credentials_ref" => ""
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      tracker_config = reloaded.config["tracker"]["config"]

      assert tracker_config["host"] == "acme.atlassian.net"
      assert tracker_config["project_key"] == "ARB"
      assert tracker_config["email"] == "bot@acme.example"
    end

    test "switching tracker type doesn't discard the other type's saved config", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "tracker" => %{
              "type" => "jira",
              "config" => %{
                "host" => "acme.atlassian.net",
                "project_key" => "ARB",
                "credentials_ref" => "secret:jira"
              }
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{"config" => %{"tracker_type" => "github"}})
      |> render_submit()

      view
      |> form("form[phx-submit=save_tracker_config]", %{
        "tracker_config" => %{
          "type" => "github",
          "owner" => "acme",
          "repo" => "widgets",
          # Left as-is (unchanged from the value the form pre-filled) —
          # `credentials_ref` is one shared key in the flat `tracker.config`
          # map, not a per-type value, so an explicit blank here would
          # legitimately unset it. That's distinct from "switching type
          # discarded it".
          "credentials_ref" => "secret:jira"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      tracker_config = reloaded.config["tracker"]["config"]

      assert reloaded.config["tracker"]["type"] == "github"
      assert tracker_config["owner"] == "acme"
      assert tracker_config["repo"] == "widgets"
      # jira's host/project_key are distinct keys from github's owner/repo —
      # switching types and saving github's fields must not discard them.
      assert tracker_config["host"] == "acme.atlassian.net"
      assert tracker_config["project_key"] == "ARB"
      assert tracker_config["credentials_ref"] == "secret:jira"
    end

    test "tracker credentials_ref is a select over existing secret names, never a raw value field",
         %{conn: conn} do
      ws = new_workspace(%{config: %{"tracker" => %{"type" => "jira"}}})

      {:ok, ws} =
        Ash.update(ws, %{secrets: %{"jira_token" => "tok-not-echoed"}}, action: :update)

      {:ok, view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, "select[name='tracker_config[credentials_ref]']")
      refute has_element?(view, "input[name='tracker_config[credentials_ref]']")
      assert html =~ "secret:jira_token"
      refute html =~ "tok-not-echoed"

      view
      |> form("form[phx-submit=save_tracker_config]", %{
        "tracker_config" => %{"type" => "jira", "credentials_ref" => "secret:jira_token"}
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["tracker"]["config"]["credentials_ref"] == "secret:jira_token"
    end

    test "blank tracker.config fields unset rather than writing empty values", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "tracker" => %{
              "type" => "jira",
              "config" => %{
                "host" => "acme.atlassian.net",
                "project_key" => "ARB",
                "email" => "bot@acme.example",
                "credentials_ref" => "secret:jira"
              }
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_tracker_config]", %{
        "tracker_config" => %{
          "type" => "jira",
          "host" => "acme.atlassian.net",
          "project_key" => "ARB",
          "email" => "  ",
          "credentials_ref" => ""
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      tracker_config = reloaded.config["tracker"]["config"]

      refute Map.has_key?(tracker_config, "email")
      refute Map.has_key?(tracker_config, "credentials_ref")
      assert tracker_config["host"] == "acme.atlassian.net"
      assert tracker_config["project_key"] == "ARB"
    end

    test "adds and removes per-provider tier_models overrides", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=add_provider_override]", %{
        "provider_override" => %{
          "provider" => "gemini",
          "tier" => "premium",
          "model" => "gemini-3-pro"
        }
      })
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)

      assert reloaded.config["agent"]["config"]["gemini"]["tier_models"] == %{
               "premium" => "gemini-3-pro"
             }

      view
      |> element(
        "button[phx-click=rm_provider_override][phx-value-provider=gemini][phx-value-tier=premium]"
      )
      |> render_click()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["agent"]["config"]["gemini"]["tier_models"] == %{}
    end

    test "lists a per-provider override on a tier outside the built-in set", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{
              "config" => %{"codex" => %{"tier_models" => %{"flagship" => "gpt-5.5"}}}
            }
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(
               view,
               "button[phx-click=rm_provider_override][phx-value-provider=codex][phx-value-tier=flagship]"
             )
    end

    test "renders the effective security posture alongside the agent.security.* editor", %{
      conn: conn
    } do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{
              "security" => %{
                "permissions" => %{"mode" => "strict", "deny" => ["Bash(curl:*)"]},
                "sandbox" => %{"network" => false}
              }
            }
          }
        })

      {:ok, view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      # Effective posture (resolved, not just raw config).
      assert html =~ SecurityPolicy.one_line(SecurityPolicy.resolve(ws))
      # Visually separated from the routine settings form.
      assert has_element?(view, "#agent-security")
      assert has_element?(view, "form[phx-submit=save_security]")
      # Current raw values are pre-filled.
      assert html =~ "Bash(curl:*)"
    end

    test "saves a non-weakening agent.security.* change without a confirmation step", %{
      conn: conn
    } do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form(
        "form[phx-submit=save_security]",
        security_params(%{
          "mode" => "strict",
          "deny" => "Bash(curl:*)\nBash(rm:*)",
          "sandbox_network" => "false"
        })
      )
      |> render_submit()

      refute has_element?(view, "#security-confirm-modal")

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      policy = SecurityPolicy.resolve(reloaded)
      assert policy.permissions.mode == :strict
      assert policy.permissions.deny == ["Bash(curl:*)", "Bash(rm:*)"]
      assert policy.sandbox.network == false
      assert policy.permissions.safe_defaults == SecurityPolicy.safe_default_categories()
    end

    test "removing a safe_defaults guard requires an explicit confirmation step", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        view
        |> form(
          "form[phx-submit=save_security]",
          security_params(%{"safe_defaults" => %{"no_force_push" => "false"}})
        )
        |> render_submit()

      # First submit does NOT save — it opens an explicit confirmation.
      assert html =~ "no_force_push"
      assert has_element?(view, "#security-confirm-modal")
      {:ok, reloaded} = Ash.get(Workspace, ws.id)

      assert SecurityPolicy.resolve(reloaded).permissions.safe_defaults ==
               SecurityPolicy.safe_default_categories()

      # Explicit confirm applies it.
      view |> element("button[phx-click=confirm_security]") |> render_click()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      refute :no_force_push in SecurityPolicy.resolve(reloaded).permissions.safe_defaults
      refute has_element?(view, "#security-confirm-modal")
    end

    test "disabling the sandbox requires an explicit confirmation step", %{conn: conn} do
      ws = new_workspace()

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form(
        "form[phx-submit=save_security]",
        security_params(%{"sandbox_enabled" => "false", "sandbox_filesystem" => "none"})
      )
      |> render_submit()

      assert has_element?(view, "#security-confirm-modal")
      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert SecurityPolicy.resolve(reloaded).sandbox.enabled == true
    end

    test "loosening the permission mode requires an explicit confirmation step", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      # Everything else identical to the current posture — only strict → bypass,
      # which drops the allow-list restriction and the classifier.
      html =
        view
        |> form("form[phx-submit=save_security]", security_params(%{"mode" => "bypass"}))
        |> render_submit()

      assert has_element?(view, "#security-confirm-modal")
      assert html =~ "strict → bypass"

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert SecurityPolicy.resolve(reloaded).permissions.mode == :strict

      view |> element("button[phx-click=confirm_security]") |> render_click()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert SecurityPolicy.resolve(reloaded).permissions.mode == :bypass
    end

    test "tightening the permission mode saves without a confirmation step", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{"security" => %{"permissions" => %{"mode" => "bypass"}}}
          }
        })

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_security]", security_params(%{"mode" => "auto"}))
      |> render_submit()

      refute has_element?(view, "#security-confirm-modal")
      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert SecurityPolicy.resolve(reloaded).permissions.mode == :auto
    end

    # A stale tab or a hand-crafted submit can carry a value the select never
    # offered. `SecurityPolicy` parses config leniently, so persisting one would
    # silently revert the workspace to the base `:bypass` default while
    # `arb config get` showed the junk string.
    test "rejects a security submit carrying an unknown mode or filesystem", %{conn: conn} do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}
          }
        })

      before_config = ws.config

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      html =
        render_submit(view, "save_security", security_params(%{"mode" => "yolo"}))

      assert html =~ "Unknown permission mode"
      refute has_element?(view, "#security-confirm-modal")

      html =
        render_submit(view, "save_security", security_params(%{"sandbox_filesystem" => "/"}))

      assert html =~ "Unknown filesystem scope"
      refute has_element?(view, "#security-confirm-modal")

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config == before_config
      assert SecurityPolicy.resolve(reloaded).permissions.mode == :strict
    end

    test "surfaces per-repo security overrides alongside the workspace-wide posture", %{
      conn: conn
    } do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{
              "security" => %{
                "permissions" => %{"mode" => "strict"},
                "repos" => %{
                  "acme/widgets" => %{"sandbox" => %{"enabled" => false}}
                }
              }
            }
          }
        })

      {:ok, view, html} = live(conn, ~p"/workspaces/#{ws.id}")

      assert has_element?(view, "#security-repo-postures")
      assert html =~ "acme/widgets"
      # The repo layer is resolved, not just echoed: its sandbox is off even
      # though the workspace-wide line says it is on.
      assert html =~ SecurityPolicy.one_line(SecurityPolicy.resolve(ws, %{}, "acme/widgets"))
      refute SecurityPolicy.resolve(ws, %{}, "acme/widgets").sandbox.enabled
      assert SecurityPolicy.resolve(ws).sandbox.enabled
    end

    test "cancelling the security confirmation leaves the posture untouched", %{conn: conn} do
      ws = new_workspace()
      before = SecurityPolicy.resolve(ws)

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form(
        "form[phx-submit=save_security]",
        security_params(%{"safe_defaults" => %{"no_secret_reads" => "false"}})
      )
      |> render_submit()

      view |> element("button[phx-click=cancel_security]") |> render_click()

      refute has_element?(view, "#security-confirm-modal")
      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert SecurityPolicy.resolve(reloaded) == before
      assert reloaded.config == ws.config
    end

    test "viewing the page and saving unrelated config never changes the security posture", %{
      conn: conn
    } do
      ws =
        new_workspace(%{
          config: %{
            "agent" => %{
              "security" => %{
                "permissions" => %{"mode" => "strict", "safe_defaults" => ["no_force_push"]},
                "sandbox" => %{"enabled" => false}
              }
            }
          }
        })

      before_config = ws.config
      before_policy = SecurityPolicy.resolve(ws)

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

      view
      |> form("form[phx-submit=save_config]", %{
        "config" => %{
          "tracker_type" => "none",
          "merger_strategy" => "direct",
          "routing_policy" => "static"
        }
      })
      |> render_submit()

      view
      |> form("form[phx-submit=save_agent_config]", %{"agent_config" => %{"model" => "opus"}})
      |> render_submit()

      {:ok, reloaded} = Ash.get(Workspace, ws.id)
      assert reloaded.config["agent"]["security"] == before_config["agent"]["security"]
      assert SecurityPolicy.resolve(reloaded) == before_policy
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

  # Acceptance criterion (d): landing this ticket must not move any existing
  # workspace's security posture. These are verbatim `config` blobs lifted
  # from the live dev database (a read-only `.backup` copy) — including the
  # `flagship` tier and `xhigh`/`none` thinking levels that appear nowhere in
  # the codebase, and vstim's four-of-five `safe_defaults` list. Anything the
  # page does short of an explicit security submit has to leave
  # `SecurityPolicy.resolve/1` byte-identical.
  describe "real workspace configs — posture drift" do
    @real_configs %{
      "default" => %{
        "agent" => %{
          "config" => %{
            "codex" => %{
              "tier_models" => %{
                "economy" => "gpt-5.4-mini",
                "premium" => "gpt-5.5",
                "standard" => "gpt-5.5"
              }
            },
            "thinking_argv" => %{
              "high" => ["--effort", "high"],
              "low" => ["--effort", "low"],
              "medium" => ["--effort", "medium"],
              "none" => [],
              "xhigh" => ["--effort", "xhigh"]
            },
            "tier_models" => %{"flagship" => "fable"}
          },
          "type" => ["claude"]
        },
        "review" => %{"required" => true},
        "routing" => %{
          "policy" => "by_difficulty",
          "rules" => %{"D4" => %{"model_tier" => "flagship", "thinking" => "xhigh"}}
        }
      },
      "emricare" => %{
        "agent" => %{
          "config" => %{
            "thinking_argv" => %{"xhigh" => ["--effort", "xhigh"]},
            "tier_models" => %{"flagship" => "fable"}
          },
          "type" => ["claude"]
        },
        "review" => %{"required" => true}
      },
      "vstim" => %{
        "agent" => %{
          "config" => %{
            "thinking_argv" => %{"xhigh" => ["--effort", "xhigh"]},
            "tier_models" => %{"flagship" => "fable"}
          },
          "security" => %{
            "permissions" => %{
              "safe_defaults" => [
                "no_destructive_fs",
                "no_force_push",
                "no_secret_reads",
                "no_outside_writes"
              ]
            }
          },
          "type" => ["claude"]
        },
        "review" => %{"required" => true}
      }
    }

    test "viewing the page leaves every real workspace's config and posture untouched", %{
      conn: conn
    } do
      for {name, config} <- @real_configs do
        ws = new_workspace(%{config: config})
        before = SecurityPolicy.resolve(ws)

        {:ok, _view, html} = live(conn, ~p"/workspaces/#{ws.id}")

        {:ok, reloaded} = Ash.get(Workspace, ws.id)

        assert reloaded.config == config, "#{name}: viewing the page rewrote config"
        assert SecurityPolicy.resolve(reloaded) == before, "#{name}: posture drifted on view"

        # And the page actually renders the stored keys rather than silently
        # dropping the ones outside the built-in tier/level sets.
        assert html =~ "flagship"
      end
    end

    test "saving an unrelated section never moves the security posture", %{conn: conn} do
      for {name, config} <- @real_configs do
        ws = new_workspace(%{config: config})
        before = SecurityPolicy.resolve(ws)

        {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

        # Submit the agent-config form exactly as rendered — no edits.
        view |> form("form[phx-submit=save_agent_config]") |> render_submit()

        {:ok, reloaded} = Ash.get(Workspace, ws.id)

        assert SecurityPolicy.resolve(reloaded) == before,
               "#{name}: agent-config save changed the security posture"

        assert get_in(reloaded.config, ["agent", "security"]) ==
                 get_in(config, ["agent", "security"]),
               "#{name}: agent-config save touched agent.security"
      end
    end

    test "round-tripping the security form unchanged is not treated as a downgrade", %{conn: conn} do
      for {name, config} <- @real_configs do
        ws = new_workspace(%{config: config})
        before = SecurityPolicy.resolve(ws)

        {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")

        html = view |> form("form[phx-submit=save_security]") |> render_submit()

        refute html =~ "security-confirm-modal",
               "#{name}: an unchanged security submit demanded confirmation"

        {:ok, reloaded} = Ash.get(Workspace, ws.id)

        assert SecurityPolicy.resolve(reloaded) == before,
               "#{name}: unchanged security submit moved the posture"
      end
    end
  end
end
