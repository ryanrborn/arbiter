defmodule Arbiter.Worker.ReviewAutomationTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.ReviewAutomation

  describe "resolve/2" do
    test "returns :flag when no workspace config" do
      assert ReviewAutomation.resolve(nil, "alice") == :flag
      assert ReviewAutomation.resolve(%{}, "alice") == :flag
    end

    test "returns :flag when review_automation block is absent" do
      config = %{"tracker" => %{"type" => "github"}}
      assert ReviewAutomation.resolve(config, "alice") == :flag
    end

    test "returns :auto when author is in auto_authors" do
      config = %{
        "review_automation" => %{
          "default" => "flag",
          "auto_authors" => ["alice", "bob"]
        }
      }

      assert ReviewAutomation.resolve(config, "alice") == :auto
      assert ReviewAutomation.resolve(config, "bob") == :auto
    end

    test "returns default when author is not in auto_authors" do
      config = %{
        "review_automation" => %{
          "default" => "flag",
          "auto_authors" => ["alice"]
        }
      }

      assert ReviewAutomation.resolve(config, "charlie") == :flag
    end

    test "returns :auto default when author not in auto_authors and default is auto" do
      config = %{
        "review_automation" => %{
          "default" => "auto",
          "auto_authors" => ["alice"]
        }
      }

      assert ReviewAutomation.resolve(config, "charlie") == :auto
    end

    test "returns :flag when pr_author is nil and default is flag" do
      config = %{
        "review_automation" => %{
          "default" => "flag",
          "auto_authors" => ["alice"]
        }
      }

      assert ReviewAutomation.resolve(config, nil) == :flag
    end

    test "returns configured default when pr_author is nil" do
      config = %{"review_automation" => %{"default" => "auto"}}
      assert ReviewAutomation.resolve(config, nil) == :auto
    end

    test "returns :flag when default is missing from block" do
      config = %{"review_automation" => %{"auto_authors" => ["alice"]}}
      assert ReviewAutomation.resolve(config, "charlie") == :flag
    end

    test "returns :flag when missing config and no author" do
      assert ReviewAutomation.resolve(nil, nil) == :flag
    end
  end

  describe "resolve/3 — repo_overrides" do
    @config %{
      "review_automation" => %{
        "default" => "flag",
        "auto_authors" => ["alice"],
        "repo_overrides" => %{
          "atlas" => "flag",
          "fast_lane" => "auto"
        }
      }
    }

    test "repo_override flag beats auto_authors membership" do
      # alice is in auto_authors, but atlas is hard-flagged
      assert ReviewAutomation.resolve(@config, "alice", "atlas") == :flag
    end

    test "repo_override auto beats non-member author + flag default" do
      # charlie is not in auto_authors, but fast_lane is hard-auto
      assert ReviewAutomation.resolve(@config, "charlie", "fast_lane") == :auto
    end

    test "repo_override auto beats nil author" do
      assert ReviewAutomation.resolve(@config, nil, "fast_lane") == :auto
    end

    test "repo_override flag beats nil author" do
      assert ReviewAutomation.resolve(@config, nil, "atlas") == :flag
    end

    test "author-in-auto_authors wins when no repo_override for that rig" do
      # alice is in auto_authors; "backend" has no override
      assert ReviewAutomation.resolve(@config, "alice", "backend") == :auto
    end

    test "default applies when no repo_override and author not in auto_authors" do
      assert ReviewAutomation.resolve(@config, "charlie", "backend") == :flag
    end

    test "nil rig_name falls through to author resolution" do
      assert ReviewAutomation.resolve(@config, "alice", nil) == :auto
      assert ReviewAutomation.resolve(@config, "charlie", nil) == :flag
    end

    test "repo_override ignored when no repo_overrides key in block" do
      config = %{"review_automation" => %{"default" => "flag", "auto_authors" => ["alice"]}}
      assert ReviewAutomation.resolve(config, "alice", "atlas") == :auto
      assert ReviewAutomation.resolve(config, "charlie", "atlas") == :flag
    end

    test "unknown rig falls through to author resolution" do
      assert ReviewAutomation.resolve(@config, "alice", "unknown_repo") == :auto
    end

    test "returns :flag for nil config regardless of rig" do
      assert ReviewAutomation.resolve(nil, "alice", "atlas") == :flag
    end
  end
end
