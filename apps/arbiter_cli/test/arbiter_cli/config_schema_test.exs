defmodule ArbiterCli.ConfigSchemaTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.ConfigSchema

  # ArbiterCli has no runtime dependency on the arbiter core app (see
  # config_schema.ex moduledoc), so ConfigSchema's enum lists are literal
  # copies. This test is the drift guard: it pulls in `arbiter` as a
  # test-only dep and asserts every list here is byte-for-byte equal to the
  # server-side source of truth.

  test "tracker types match Arbiter.Tasks.Workspace.valid_tracker_types/0" do
    assert ConfigSchema.tracker_types() == Arbiter.Tasks.Workspace.valid_tracker_types()
  end

  test "merger strategies match Arbiter.Tasks.Workspace.valid_merger_strategies/0" do
    assert ConfigSchema.merger_strategies() == Arbiter.Tasks.Workspace.valid_merger_strategies()
  end

  test "agent types match Arbiter.Agents.valid_agent_types/0" do
    assert ConfigSchema.agent_types() == Arbiter.Agents.valid_agent_types()
  end

  test "routing policies match Arbiter.Agents.Routing.valid_policies/0" do
    assert ConfigSchema.routing_policies() == Arbiter.Agents.Routing.valid_policies()
  end

  test "security modes match Arbiter.Agents.SecurityPolicy.valid_modes/0" do
    assert ConfigSchema.security_modes() ==
             Enum.map(Arbiter.Agents.SecurityPolicy.valid_modes(), &Atom.to_string/1)
  end

  test "sandbox filesystems match Arbiter.Agents.SecurityPolicy.valid_filesystems/0" do
    assert ConfigSchema.sandbox_filesystems() ==
             Enum.map(Arbiter.Agents.SecurityPolicy.valid_filesystems(), &Atom.to_string/1)
  end

  test "safe-default categories match Arbiter.Agents.SecurityPolicy.safe_default_categories/0" do
    assert ConfigSchema.safe_default_categories() ==
             Enum.map(Arbiter.Agents.SecurityPolicy.safe_default_categories(), &Atom.to_string/1)
  end

  test "review_automation modes match Arbiter.Tasks.Workspace.Changes.ValidateConfig.valid_review_automation_modes/0" do
    assert ConfigSchema.review_automation_modes() ==
             Arbiter.Tasks.Workspace.Changes.ValidateConfig.valid_review_automation_modes()
  end

  test "quota modes match Arbiter.Tasks.Workspace.Changes.ValidateConfig.valid_quota_modes/0" do
    assert ConfigSchema.quota_modes() ==
             Arbiter.Tasks.Workspace.Changes.ValidateConfig.valid_quota_modes()
  end

  test "render/0 mentions every top-level config key" do
    text = ConfigSchema.render()

    for key <- ~w(tracker merge agent review_agent security routing review_gate
                  review_automation quota conductor standing_orders repo_paths
                  pr_patrol review_patrol) do
      assert text =~ key
    end
  end
end
