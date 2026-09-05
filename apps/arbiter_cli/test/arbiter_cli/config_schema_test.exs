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
                  review_automation quota conductor loop standing_orders repo_paths
                  pr_patrol review_patrol) do
      assert text =~ key
    end
  end

  # bd-6edc0u: the only kill switch for Arbiter's one autonomous-write path.
  # `arb config --help` is where an operator goes looking for it, so the
  # reference has to name it and say which way is off.
  test "render/0 documents the Stage 3 autonomy flag and its sample-size floor" do
    text = ConfigSchema.render()

    assert text =~ "autonomous_routing_enabled"
    assert text =~ "canary_min_dispatches"
    assert text =~ "canary_regression_tolerance"

    assert text =~ ~r/autonomous_routing_enabled\s+bool — OFF/,
           "the reference must be explicit that autonomous routing is off by default"

    assert Arbiter.Loop.Canary.min_dispatches() == 20,
           "the documented >= 20 floor must match the server's own constant"

    assert Arbiter.Loop.Canary.max_regression_tolerance() == 0.5,
           "the documented 0..0.5 tolerance range must match the server's own ceiling"
  end

  # bd-77cbif: standing_orders reaches arb prime (the coordinator's briefing)
  # and nothing else — no worker ever sees it. The reference used to claim
  # otherwise ("surfaced high in every worker's arb prime briefing"), which
  # is wrong on both counts: arb prime is not worker-facing, and there is no
  # worker briefing for it to be surfaced in.
  test "render/0 does not claim standing_orders reaches a worker briefing" do
    text = ConfigSchema.render()

    refute text =~ ~r/worker's `arb prime`/,
           "arb prime is a coordinator command, not a per-worker briefing"

    refute text =~ ~r/every worker/i,
           "standing_orders is never injected into a worker prompt"
  end

  # `arb workspace --help` prints this moduledoc immediately followed by
  # ConfigSchema.render() (see ArbiterCli.Cmd.Workspace.print_help/0) — if this
  # doc site regresses back to the false claim, the two would contradict each
  # other on the same screen.
  test "ArbiterCli.Cmd.Workspace moduledoc does not claim standing_orders reaches a worker briefing" do
    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
      Code.fetch_docs(ArbiterCli.Cmd.Workspace)

    refute moduledoc =~ ~r/worker's `arb prime`/,
           "arb prime is a coordinator command, not a per-worker briefing"

    refute moduledoc =~ ~r/every worker/i,
           "standing_orders is never injected into a worker prompt"
  end
end
