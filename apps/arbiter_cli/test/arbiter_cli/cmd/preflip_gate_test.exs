defmodule ArbiterCli.Cmd.PreflipGateTest do
  @moduledoc """
  `arb preflip-gate` (bd-cy2mmu): the CLI surface for
  `Arbiter.Reviews.CoverageShadow.preflip_gate/0`.
  """
  use ArbiterCli.CliCase, async: false

  @pass_data %{
    "merges" => 66,
    "agreements" => 66,
    "blocking" => %{},
    "blocking_observations" => [],
    "deferred" => %{},
    "deferred_observations" => [],
    "min_merges" => 20,
    "truncated?" => false,
    "pass?" => true,
    "reason" => "pass: 66 merges, zero blocking disagreements"
  }

  @fail_data %{
    "merges" => 104,
    "agreements" => 100,
    "blocking" => %{"unknown->uncovered" => 3, "covered->uncovered" => 1},
    "blocking_observations" => [
      %{
        "site" => "watchdog",
        "task_id" => "bd-2jkrqu",
        "mr_ref" => "ryanrborn/arbiter#1709",
        "head" => "abc123",
        "old" => "unknown",
        "new" => "uncovered",
        "new_reason" => "no_coverage",
        "occurred_at" => "2026-09-15T10:00:00.000000Z"
      }
    ],
    "deferred" => %{},
    "deferred_observations" => [],
    "min_merges" => 20,
    "truncated?" => false,
    "pass?" => false,
    "reason" =>
      "4 blocking disagreement(s) (covered->uncovered, unknown->uncovered) over 104 merges (need >= 20 with none blocking)"
  }

  test "renders a clean pass" do
    stub_get("/api/coverage_shadow/preflip_gate", %{"data" => @pass_data})

    {out, _err, code} = capture(fn -> ArbiterCli.Cmd.PreflipGate.run([]) end)

    assert code == 0
    assert out =~ "PASS"
    assert out =~ "merges: 66"
    assert out =~ "pass: 66 merges, zero blocking disagreements"
  end

  test "renders blocking disagreements with their occurred_at timestamps" do
    stub_get("/api/coverage_shadow/preflip_gate", %{"data" => @fail_data})

    {out, _err, code} = capture(fn -> ArbiterCli.Cmd.PreflipGate.run([]) end)

    assert code == 0
    assert out =~ "FAIL"
    assert out =~ "unknown->uncovered"
    assert out =~ "2026-09-15"
    assert out =~ "4 blocking disagreement(s)"
  end

  test "--json emits the raw gate payload" do
    stub_get("/api/coverage_shadow/preflip_gate", %{"data" => @pass_data})

    {out, _err, code} =
      capture(fn -> ArbiterCli.Cmd.PreflipGate.run(["--json"]) end)

    assert code == 0
    assert Jason.decode!(out) == @pass_data
  end
end
