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
end
