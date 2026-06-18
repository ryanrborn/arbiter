defmodule Arbiter.Agents.Claude.SecurityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Claude.Security
  alias Arbiter.Agents.SecurityPolicy

  defp policy(overrides \\ %{}), do: SecurityPolicy.merge(SecurityPolicy.base(), overrides)

  describe "permission_argv/1" do
    test "auto -> --permission-mode auto" do
      assert Security.permission_argv(policy(%{"permissions" => %{"mode" => "auto"}})) ==
               ["--permission-mode", "auto"]
    end

    test "strict -> --permission-mode default" do
      assert Security.permission_argv(policy(%{"permissions" => %{"mode" => "strict"}})) ==
               ["--permission-mode", "default"]
    end

    test "bypass -> --dangerously-skip-permissions" do
      assert Security.permission_argv(policy(%{"permissions" => %{"mode" => "bypass"}})) ==
               ["--dangerously-skip-permissions"]
    end
  end

  describe "settings_argv/1" do
    test "emits a --settings JSON document for bypass (default)" do
      assert ["--settings", json] = Security.settings_argv(policy())
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["permissions"]["defaultMode"] == "bypassPermissions"
      assert is_list(decoded["permissions"]["deny"])
      assert decoded["permissions"]["deny"] != []
    end

    test "emits a --settings JSON document for auto mode" do
      assert ["--settings", json] =
               Security.settings_argv(policy(%{"permissions" => %{"mode" => "auto"}}))

      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["permissions"]["defaultMode"] == "auto"
      assert is_list(decoded["permissions"]["deny"])
      assert decoded["permissions"]["deny"] != []
    end

    test "emits --settings for bypass: deny list is enforced even though interactive classifier is skipped" do
      p = policy(%{"permissions" => %{"mode" => "bypass"}})
      assert ["--settings", json] = Security.settings_argv(p)
      assert {:ok, decoded} = Jason.decode(json)
      assert is_list(decoded["permissions"]["deny"])
      assert decoded["permissions"]["deny"] != []
    end
  end

  describe "deny_rules/1" do
    test "the safe-default baseline is non-empty even in bypass mode" do
      rules = Security.deny_rules(policy())
      assert Enum.any?(rules, &(&1 =~ "rm -rf"))
      assert Enum.any?(rules, &(&1 =~ "git push --force"))
      assert Enum.any?(rules, &(&1 =~ ".env"))
    end

    test "operator deny rules are folded in and deduped" do
      rules =
        Security.deny_rules(
          policy(%{"permissions" => %{"deny" => ["Bash(docker:*)", "Bash(rm -rf:*)"]}})
        )

      assert "Bash(docker:*)" in rules
      assert Enum.count(rules, &(&1 == "Bash(rm -rf:*)")) == 1
    end

    test "network: false adds network-egress denies" do
      rules = Security.deny_rules(policy(%{"sandbox" => %{"network" => false}}))
      assert "WebFetch" in rules
      assert "WebSearch" in rules
      assert Enum.any?(rules, &(&1 =~ "curl"))
    end

    test "network: true (default) adds no network denies" do
      rules = Security.deny_rules(policy())
      refute "WebFetch" in rules
    end

    test "opting out of safe_defaults empties the baseline" do
      rules = Security.deny_rules(policy(%{"permissions" => %{"safe_defaults" => []}}))
      refute Enum.any?(rules, &(&1 =~ "rm -rf"))
    end

    # bd-53xrmi: the Refinery owns PR creation; a worker must not open its own
    # PR (it lands a duplicate on the wrong base). The no_pr_create category is
    # in the safe-default baseline, so it's denied by default.
    test "the no_pr_create baseline denies gh pr create / glab mr create" do
      rules = Security.deny_rules(policy())
      assert "Bash(gh pr create:*)" in rules
      assert "Bash(glab mr create:*)" in rules
    end

    test "opting out of safe_defaults also drops the PR-create deny" do
      rules = Security.deny_rules(policy(%{"permissions" => %{"safe_defaults" => []}}))
      refute Enum.any?(rules, &(&1 =~ "gh pr create"))
    end
  end
end
