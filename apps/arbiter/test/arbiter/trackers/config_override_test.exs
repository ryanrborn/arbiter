defmodule Arbiter.Trackers.ConfigOverrideTest do
  # async: false — these tests seed the per-process tracker config dictionary.
  use ExUnit.Case, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Trackers.ConfigOverride
  alias Arbiter.Trackers.GitHub

  @pdict_key {:config_override_test, :active}

  setup do
    on_exit(fn ->
      Process.delete(@pdict_key)
      GitHub.Config.clear()
    end)

    :ok
  end

  describe "ConfigOverride.apply/3" do
    test "merges the repo override over the seeded active config" do
      Process.put(@pdict_key, %{"owner" => "acme", "repo" => "core", "keep" => "me"})

      ws = %Workspace{
        config: %{
          "tracker" => %{
            "config" => %{
              "owner" => "acme",
              "repo" => "core",
              "repos" => %{"device" => %{"repo" => "device"}}
            }
          }
        }
      }

      assert :ok = ConfigOverride.apply(@pdict_key, ws, "device")

      active = Process.get(@pdict_key)
      # Override wins for `repo`; unset keys fall back to the workspace binding.
      assert active["repo"] == "device"
      assert active["owner"] == "acme"
      assert active["keep"] == "me"
    end

    test "no-op when repo is nil/blank" do
      Process.put(@pdict_key, %{"repo" => "core"})

      ws = %Workspace{
        config: %{"tracker" => %{"config" => %{"repos" => %{"d" => %{"repo" => "x"}}}}}
      }

      assert :ok = ConfigOverride.apply(@pdict_key, ws, nil)
      assert :ok = ConfigOverride.apply(@pdict_key, ws, "")
      assert Process.get(@pdict_key) == %{"repo" => "core"}
    end

    test "no-op when the workspace declares no override for the repo" do
      Process.put(@pdict_key, %{"repo" => "core"})
      ws = %Workspace{config: %{"tracker" => %{"config" => %{"repos" => %{"other" => %{}}}}}}

      assert :ok = ConfigOverride.apply(@pdict_key, ws, "device")
      assert Process.get(@pdict_key) == %{"repo" => "core"}
    end

    test "no-op for a nil workspace" do
      Process.put(@pdict_key, %{"repo" => "core"})
      assert :ok = ConfigOverride.apply(@pdict_key, nil, "device")
      assert Process.get(@pdict_key) == %{"repo" => "core"}
    end
  end

  describe "Trackers.prepare_with_repo/3 (GitHub)" do
    defp github_ws do
      %Workspace{
        config: %{
          "tracker" => %{
            "type" => "github",
            "config" => %{
              "owner" => "acme",
              "repo" => "core",
              "credentials_ref" => "env:CONFIG_OVERRIDE_TEST_GH",
              "repos" => %{
                "device" => %{"owner" => "acme", "repo" => "device"}
              }
            }
          }
        }
      }
    end

    test "applies the per-repo tracker binding for the overridden repo" do
      issue = %Issue{tracker_type: :github}
      :ok = Trackers.prepare_with_repo(issue, github_ws(), "device")
      assert GitHub.Config.active_repo_slug() == "acme/device"
    end

    test "falls back to the workspace-wide binding for a non-overridden repo" do
      issue = %Issue{tracker_type: :github}
      :ok = Trackers.prepare_with_repo(issue, github_ws(), "server")
      assert GitHub.Config.active_repo_slug() == "acme/core"
    end

    test "nil repo behaves like prepare/2 (workspace-wide binding)" do
      issue = %Issue{tracker_type: :github}
      :ok = Trackers.prepare_with_repo(issue, github_ws(), nil)
      assert GitHub.Config.active_repo_slug() == "acme/core"
    end
  end
end
