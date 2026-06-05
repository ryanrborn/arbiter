defmodule Arbiter.Beads.WorkspaceTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Workspace

  describe "create/2" do
    test "succeeds with minimal valid attrs (name only); config defaults to empty map" do
      assert {:ok, ws} = Ash.create(Workspace, %{name: "minimal"})
      assert ws.name == "minimal"
      assert ws.config == %{}
      assert is_binary(ws.id)
    end

    test "succeeds with full vernacular + tracker config" do
      config = %{
        "vernacular" => %{
          "coordinator" => "Admiral",
          "worker" => "Acolyte",
          "aliases" => %{"deploy" => "sling", "report" => "done"},
          "emoji" => %{"worker" => "⚔️"}
        },
        "tracker" => %{
          "type" => "jira",
          "config" => %{
            "host" => "leotechnologies.atlassian.net",
            "project_key" => "VR",
            "credentials_ref" => "env:JIRA_TOKEN"
          }
        }
      }

      assert {:ok, ws} =
               Ash.create(Workspace, %{
                 name: "Death Squadron",
                 description: "Sith Fleet persona",
                 config: config
               })

      assert ws.config["vernacular"]["coordinator"] == "Admiral"
      assert ws.config["tracker"]["type"] == "jira"
      assert ws.config["tracker"]["config"]["project_key"] == "VR"
    end

    test "fails when tracker.type is not in the enum" do
      config = %{"tracker" => %{"type" => "asana"}}

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Workspace, %{name: "bad-tracker", config: config})

      assert err |> Exception.message() |> String.contains?("tracker.type must be one of")
    end

    test "fails when tracker is not a map" do
      config = %{"tracker" => "jira"}

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Workspace, %{name: "non-map-tracker", config: config})

      assert err |> Exception.message() |> String.contains?("tracker must be a map")
    end

    test "fails when tracker.config is not a map" do
      config = %{"tracker" => %{"type" => "jira", "config" => "not-a-map"}}

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Workspace, %{name: "bad-tracker-cfg", config: config})

      assert err |> Exception.message() |> String.contains?("tracker.config must be a map")
    end

    test "fails when vernacular.aliases has non-string values" do
      config = %{"vernacular" => %{"aliases" => %{"deploy" => 42}}}

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Workspace, %{name: "bad-aliases", config: config})

      assert err
             |> Exception.message()
             |> String.contains?("vernacular.aliases must be a map of string → string")
    end

    test "fails when name is missing" do
      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Workspace, %{})
    end

    test "fails when name is too long" do
      long_name = String.duplicate("a", 101)
      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Workspace, %{name: long_name})
    end

    test "accepts the :none tracker type" do
      config = %{"tracker" => %{"type" => "none"}}
      assert {:ok, _ws} = Ash.create(Workspace, %{name: "no-tracker", config: config})
    end

    test "allows unknown top-level config keys (forward compat)" do
      config = %{"future_feature" => %{"x" => 1}}
      assert {:ok, ws} = Ash.create(Workspace, %{name: "fwd-compat", config: config})
      assert ws.config["future_feature"] == %{"x" => 1}
    end

    test "succeeds with a valid merge.strategy" do
      config = %{"merge" => %{"strategy" => "direct"}}
      assert {:ok, ws} = Ash.create(Workspace, %{name: "direct-merge", config: config})
      assert ws.config["merge"]["strategy"] == "direct"
    end

    test "succeeds with the github merge.strategy and its config block" do
      config = %{
        "merge" => %{
          "strategy" => "github",
          "config" => %{
            "owner" => "octo",
            "repo" => "widget",
            "credentials_ref" => "env:GITHUB_TOKEN"
          }
        }
      }

      assert {:ok, ws} = Ash.create(Workspace, %{name: "github-merge", config: config})
      assert ws.config["merge"]["strategy"] == "github"
    end

    test "fails when merge.strategy is not in the enum" do
      config = %{"merge" => %{"strategy" => "bogus"}}

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Workspace, %{name: "bad-merge", config: config})

      assert err |> Exception.message() |> String.contains?("merge.strategy must be one of")
    end

    test "fails when merge is not a map" do
      config = %{"merge" => "direct"}

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Workspace, %{name: "non-map-merge", config: config})

      assert err |> Exception.message() |> String.contains?("merge must be a map")
    end

    test "accepts agent.type as a single valid string" do
      config = %{"agent" => %{"type" => "claude"}}
      assert {:ok, ws} = Ash.create(Workspace, %{name: "agent-single", config: config})
      assert ws.config["agent"]["type"] == "claude"
    end

    test "accepts agent.type as a list of valid strings (multi-provider pool)" do
      config = %{"agent" => %{"type" => ["claude", "gemini"]}}
      assert {:ok, ws} = Ash.create(Workspace, %{name: "agent-pool", config: config})
      assert ws.config["agent"]["type"] == ["claude", "gemini"]
    end

    test "accepts agent.type as a single-element list" do
      config = %{"agent" => %{"type" => ["gemini"]}}
      assert {:ok, ws} = Ash.create(Workspace, %{name: "agent-singleton-list", config: config})
      assert ws.config["agent"]["type"] == ["gemini"]
    end

    test "rejects agent.type as an empty list" do
      config = %{"agent" => %{"type" => []}}

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Workspace, %{name: "agent-empty-list", config: config})

      assert err |> Exception.message() |> String.contains?("agent.type list must not be empty")
    end

    test "rejects agent.type list with invalid entries" do
      config = %{"agent" => %{"type" => ["claude", "robots"]}}

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Workspace, %{name: "agent-bad-list", config: config})

      assert err |> Exception.message() |> String.contains?("agent.type list contains invalid types")
    end

    test "rejects agent.type as a non-string non-list" do
      config = %{"agent" => %{"type" => 42}}

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.create(Workspace, %{name: "agent-int-type", config: config})

      assert err |> Exception.message() |> String.contains?("agent.type must be a string or list")
    end
  end

  describe "update/2" do
    test "can update name + config; validation runs on update" do
      {:ok, ws} = Ash.create(Workspace, %{name: "renamable"})

      assert {:ok, updated} =
               Ash.update(ws, %{
                 name: "renamed",
                 config: %{"tracker" => %{"type" => "linear"}}
               })

      assert updated.name == "renamed"
      assert updated.config["tracker"]["type"] == "linear"
    end

    test "update rejects invalid tracker.type" do
      {:ok, ws} = Ash.create(Workspace, %{name: "to-be-broken"})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(ws, %{config: %{"tracker" => %{"type" => "bogus"}}})
    end
  end

  describe "patch_config/2" do
    test "deep-merges a patch without clobbering sibling keys" do
      initial = %{
        "tracker" => %{"type" => "github", "config" => %{"owner" => "leo"}},
        "rig_paths" => %{"arbiter" => "/srv/arbiter"},
        "merge" => %{"strategy" => "github", "config" => %{"owner" => "leo", "repo" => "arbiter"}}
      }

      {:ok, ws} = Ash.create(Workspace, %{name: "deep-merge", config: initial})

      {:ok, updated} =
        Ash.update(ws, %{patch: %{"merge" => %{"auto_merge" => true}}}, action: :patch_config)

      # The auto_merge leaf was set...
      assert updated.config["merge"]["auto_merge"] == true
      # ...and every other sibling survived (this is the original footgun).
      assert updated.config["merge"]["strategy"] == "github"
      assert updated.config["merge"]["config"]["owner"] == "leo"
      assert updated.config["merge"]["config"]["repo"] == "arbiter"
      assert updated.config["tracker"]["type"] == "github"
      assert updated.config["rig_paths"]["arbiter"] == "/srv/arbiter"
    end

    test "merges into a nil/empty existing config" do
      {:ok, ws} = Ash.create(Workspace, %{name: "empty-cfg"})
      assert ws.config == %{}

      {:ok, updated} =
        Ash.update(ws, %{patch: %{"tracker" => %{"type" => "none"}}}, action: :patch_config)

      assert updated.config["tracker"]["type"] == "none"
    end

    test "unset_paths removes a dotted leaf without touching siblings" do
      initial = %{
        "tracker" => %{
          "type" => "jira",
          "config" => %{"host" => "h.example", "project_key" => "VR"}
        }
      }

      {:ok, ws} = Ash.create(Workspace, %{name: "unset-leaf", config: initial})

      {:ok, updated} =
        Ash.update(ws, %{unset_paths: ["tracker.config.host"]}, action: :patch_config)

      refute Map.has_key?(updated.config["tracker"]["config"], "host")
      assert updated.config["tracker"]["config"]["project_key"] == "VR"
      assert updated.config["tracker"]["type"] == "jira"
    end

    test "unset of an absent path is a no-op" do
      {:ok, ws} = Ash.create(Workspace, %{name: "unset-absent", config: %{"foo" => 1}})

      {:ok, updated} =
        Ash.update(ws, %{unset_paths: ["nonexistent.key"]}, action: :patch_config)

      assert updated.config == %{"foo" => 1}
    end

    test "runs ValidateConfig on the merged result (rejects invalid tracker.type)" do
      {:ok, ws} = Ash.create(Workspace, %{name: "validates"})

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.update(ws, %{patch: %{"tracker" => %{"type" => "asana"}}},
                 action: :patch_config
               )

      assert err |> Exception.message() |> String.contains?("tracker.type must be one of")
    end

    test "patch + unset can be combined in one call" do
      initial = %{"a" => %{"b" => 1, "c" => 2}, "d" => 3}
      {:ok, ws} = Ash.create(Workspace, %{name: "combo", config: initial})

      {:ok, updated} =
        Ash.update(
          ws,
          %{patch: %{"a" => %{"e" => 4}}, unset_paths: ["a.b"]},
          action: :patch_config
        )

      assert updated.config == %{"a" => %{"c" => 2, "e" => 4}, "d" => 3}
    end

    test "lists replace (not append) — matches deep_merge contract" do
      {:ok, ws} =
        Ash.create(Workspace, %{name: "list-replace", config: %{"xs" => [1, 2, 3]}})

      {:ok, updated} =
        Ash.update(ws, %{patch: %{"xs" => [9]}}, action: :patch_config)

      assert updated.config["xs"] == [9]
    end
  end

  describe "valid_tracker_types/0" do
    test "returns the canonical set" do
      assert Workspace.valid_tracker_types() == ~w(none jira shortcut linear github)
    end
  end

  describe "valid_merger_strategies/0" do
    test "includes direct, gitlab, and github" do
      assert Workspace.valid_merger_strategies() == ~w(direct gitlab github)
    end
  end

  describe "merger_strategy/1" do
    test "reads config[merge][strategy] as an atom" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ms-direct",
          config: %{"merge" => %{"strategy" => "direct"}}
        })

      assert Workspace.merger_strategy(ws) == :direct
    end

    test "resolves :github" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ms-github",
          config: %{"merge" => %{"strategy" => "github"}}
        })

      assert Workspace.merger_strategy(ws) == :github
    end

    test "defaults to :direct when unset" do
      {:ok, ws} = Ash.create(Workspace, %{name: "ms-default"})
      assert Workspace.merger_strategy(ws) == :direct
    end
  end

  describe "auto_merge?/1" do
    test "true when config[merge][auto_merge] is boolean true" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "am-true",
          config: %{"merge" => %{"strategy" => "gitlab", "auto_merge" => true}}
        })

      assert Workspace.auto_merge?(ws) == true
    end

    test "true when stored as the string \"true\" (JSON round-trip)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "am-str",
          config: %{"merge" => %{"auto_merge" => "true"}}
        })

      assert Workspace.auto_merge?(ws) == true
    end

    test "defaults to false when unset or falsey" do
      {:ok, unset} = Ash.create(Workspace, %{name: "am-unset"})
      assert Workspace.auto_merge?(unset) == false

      {:ok, off} =
        Ash.create(Workspace, %{
          name: "am-off",
          config: %{"merge" => %{"auto_merge" => false}}
        })

      assert Workspace.auto_merge?(off) == false
    end
  end

  describe "warden_max_polls/1" do
    test "returns integer when set as integer" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "wmp-int",
          config: %{"merge" => %{"warden_max_polls" => 1440}}
        })

      assert Workspace.warden_max_polls(ws) == 1440
    end

    test "returns integer when set as string (JSON round-trip)" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "wmp-str",
          config: %{"merge" => %{"warden_max_polls" => "720"}}
        })

      assert Workspace.warden_max_polls(ws) == 720
    end

    test "returns :infinity when set to the string \"infinity\"" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "wmp-inf",
          config: %{"merge" => %{"warden_max_polls" => "infinity"}}
        })

      assert Workspace.warden_max_polls(ws) == :infinity
    end

    test "returns nil when unset" do
      {:ok, ws} = Ash.create(Workspace, %{name: "wmp-unset"})
      assert Workspace.warden_max_polls(ws) == nil
    end

    test "validate_config rejects invalid warden_max_polls" do
      assert {:error, _} =
               Ash.create(Workspace, %{
                 name: "wmp-bad",
                 config: %{"merge" => %{"warden_max_polls" => -5}}
               })

      assert {:error, _} =
               Ash.create(Workspace, %{
                 name: "wmp-bad2",
                 config: %{"merge" => %{"warden_max_polls" => "not-a-number"}}
               })
    end
  end
end
