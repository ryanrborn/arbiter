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

    test "fails when merge.strategy is not in the enum" do
      config = %{"merge" => %{"strategy" => "gitlab"}}

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

  describe "valid_tracker_types/0" do
    test "returns the canonical set" do
      assert Workspace.valid_tracker_types() == ~w(none jira shortcut linear github)
    end
  end

  describe "valid_merger_strategies/0" do
    test "starts as just direct" do
      assert Workspace.valid_merger_strategies() == ~w(direct)
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

    test "defaults to :direct when unset" do
      {:ok, ws} = Ash.create(Workspace, %{name: "ms-default"})
      assert Workspace.merger_strategy(ws) == :direct
    end
  end
end
