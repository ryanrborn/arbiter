defmodule Arbiter.Trackers.ConfigOverrideTest do
  # async: false — these tests seed the per-process tracker config dictionary.
  use ExUnit.Case, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers
  alias Arbiter.Trackers.ConfigOverride
  alias Arbiter.Trackers.GitHub
  alias Arbiter.Trackers.Jira

  @pdict_key {:config_override_test, :active}

  setup do
    on_exit(fn ->
      Process.delete(@pdict_key)
      GitHub.Config.clear()
      Jira.Config.clear()
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

    test "matches a forge-qualified slug against a bare repos key (bd-36p5rh)" do
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

      # Caller passes forge-qualified slug; config is keyed by bare name
      assert :ok = ConfigOverride.apply(@pdict_key, ws, "acme/device")

      active = Process.get(@pdict_key)
      # Override should still be found and applied
      assert active["repo"] == "device"
      assert active["owner"] == "acme"
      assert active["keep"] == "me"
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

    test "forge-qualified slug matches bare repos key (bd-36p5rh)" do
      issue = %Issue{tracker_type: :github}
      # Caller has forge-qualified slug; config is keyed by bare name
      :ok = Trackers.prepare_with_repo(issue, github_ws(), "acme/device")
      # Should resolve to the overridden config for device, not fall back to core
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

  describe "Trackers.prepare_with_repo/3 (Jira)" do
    defp jira_ws do
      %Workspace{
        config: %{
          "tracker" => %{
            "type" => "jira",
            "config" => %{
              "host" => "acme.atlassian.net",
              "project_key" => "CORE",
              "credentials_ref" => "env:CONFIG_OVERRIDE_TEST_JIRA",
              "repos" => %{
                "device" => %{"project_key" => "DEV"}
              }
            }
          }
        }
      }
    end

    test "forge-qualified slug matches bare repos key for Jira (bd-36p5rh)" do
      issue = %Issue{tracker_type: :jira}
      # Caller has forge-qualified slug; config is keyed by bare name
      :ok = Trackers.prepare_with_repo(issue, jira_ws(), "acme/device")
      # Should resolve to the overridden config for device, not fall back to CORE
      assert Jira.Config.active_project_key() == "DEV"
    end
  end
end
