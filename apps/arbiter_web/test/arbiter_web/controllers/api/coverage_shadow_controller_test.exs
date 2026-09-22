defmodule ArbiterWeb.Api.CoverageShadowControllerTest do
  @moduledoc """
  `GET /api/coverage_shadow/preflip_gate` (bd-cy2mmu): the operator surface
  for `Arbiter.Reviews.CoverageShadow.preflip_gate/0`, which previously had no
  caller outside tests.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Events

  defp seed(result, old, new, overrides \\ %{}) do
    Events.broadcast(
      Ecto.UUID.generate(),
      "coverage_shadow",
      Map.merge(
        %{
          result: result,
          authoritative: "old",
          site: "watchdog",
          task_id: "bd-cy2mmu",
          mr_ref: "ryanrborn/arbiter#1900",
          head: Base.encode16(:crypto.strong_rand_bytes(20), case: :lower),
          old: old,
          old_detail: "",
          new: new,
          new_reason: ""
        },
        overrides
      )
    )
  end

  test "reports pass/fail with a reason, and the transition breakdown", %{conn: conn} do
    for _ <- 1..20, do: seed("agree", "covered", "covered")

    resp = conn |> get("/api/coverage_shadow/preflip_gate") |> json_response(200)
    data = resp["data"]

    assert data["merges"] == 20
    assert data["blocking"] == %{}
    assert data["pass?"] == true
    assert is_binary(data["reason"])
    assert data["min_merges"] == 20
  end

  test "surfaces blocking disagreements with occurred_at, so an operator sees the time distribution",
       %{conn: conn} do
    for _ <- 1..20, do: seed("agree", "covered", "covered")
    seed("disagree", "unknown", "uncovered")

    resp = conn |> get("/api/coverage_shadow/preflip_gate") |> json_response(200)
    data = resp["data"]

    assert data["pass?"] == false
    assert data["blocking"] == %{"unknown->uncovered" => 1}
    assert [obs] = data["blocking_observations"]
    assert is_binary(obs["occurred_at"])
  end
end
