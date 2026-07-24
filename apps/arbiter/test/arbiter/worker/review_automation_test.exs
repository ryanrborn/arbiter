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

  describe "resolve — :report_only mode (bd-36qzgx)" do
    test "a repo_override of report_only resolves to :report_only regardless of author" do
      config = %{
        "review_automation" => %{
          "default" => "auto",
          "auto_authors" => ["alice"],
          "repo_overrides" => %{
            "atlas" => "report_only",
            "verus-infrastructure" => "report_only"
          }
        }
      }

      # Infra repos: never auto-post, even for a trusted (auto_authors) author.
      assert ReviewAutomation.resolve(config, "alice", "atlas") == :report_only
      assert ReviewAutomation.resolve(config, "coworker", "verus-infrastructure") == :report_only
      assert ReviewAutomation.resolve(config, nil, "atlas") == :report_only
    end

    test "a default of report_only applies when no repo_override / author match" do
      config = %{"review_automation" => %{"default" => "report_only"}}
      assert ReviewAutomation.resolve(config, "charlie", "backend") == :report_only
      assert ReviewAutomation.resolve(config, nil) == :report_only
    end

    test "the propose alias resolves to :report_only" do
      config = %{
        "review_automation" => %{
          "default" => "flag",
          "repo_overrides" => %{"atlas" => "propose"}
        }
      }

      assert ReviewAutomation.resolve(config, "alice", "atlas") == :report_only
    end
  end

  describe "repo_override_mode/2 (bd-3cpcw2)" do
    @config %{
      "review_automation" => %{
        "default" => "auto",
        "auto_authors" => ["alice"],
        "repo_overrides" => %{
          "voice_biometrics" => "report_only",
          "fast_lane" => "auto"
        }
      }
    }

    test "returns the configured override for a repo with one" do
      assert ReviewAutomation.repo_override_mode(@config, "voice_biometrics") == :report_only
      assert ReviewAutomation.repo_override_mode(@config, "fast_lane") == :auto
    end

    test "returns nil for a repo with no override, ignoring auto_authors/default" do
      assert ReviewAutomation.repo_override_mode(@config, "backend") == nil
    end

    test "returns nil for nil/blank rig_name" do
      assert ReviewAutomation.repo_override_mode(@config, nil) == nil
      assert ReviewAutomation.repo_override_mode(@config, "") == nil
    end

    test "returns nil for nil/empty config" do
      assert ReviewAutomation.repo_override_mode(nil, "voice_biometrics") == nil
      assert ReviewAutomation.repo_override_mode(%{}, "voice_biometrics") == nil
    end
  end

  describe "normalize/1" do
    test "recognizes the three modes and their aliases" do
      assert ReviewAutomation.normalize("auto") == :auto
      assert ReviewAutomation.normalize("report_only") == :report_only
      assert ReviewAutomation.normalize("propose") == :report_only
      assert ReviewAutomation.normalize("flag") == :flag
      assert ReviewAutomation.normalize("notify") == :flag
      assert ReviewAutomation.normalize(:report_only) == :report_only
    end

    test "returns nil for anything unrecognized" do
      assert ReviewAutomation.normalize(nil) == nil
      assert ReviewAutomation.normalize("nonsense") == nil
      assert ReviewAutomation.normalize(42) == nil
    end
  end
end
