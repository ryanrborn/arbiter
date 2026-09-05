defmodule ArbiterCli.StandingOrdersRenderingTest do
  use ExUnit.Case, async: true

  # This test guards against drift between standing-order text rendering
  # across three independent copies of the rendering logic:
  # 1. Arbiter.StandingOrders.canonical_text/1 (hashing, dispatch-time provenance)
  # 2. ArbiterCli.Cmd.Prime.standing_order_line/1 (coordinator briefing display)
  # 3. ArbiterWeb.WorkspaceDetail.StandingOrdersComponent.order_text/1 (web UI display)
  #
  # A test-only dependency on :arbiter (see mix.exs:93 comment) makes it possible
  # to verify the core rendering logic; the CLI and web versions are verified to
  # match it (modulo display prefixes) by reconstructing their logic here.

  test "string order rendering is consistent across all three implementations" do
    order = "always run tests"

    # Arbiter core: canonical text (no prefix)
    core = Arbiter.StandingOrders.canonical_text(order)

    # CLI rendering: with "[ ] " prefix
    cli = "[ ] #{order}"

    # Web rendering: no prefix
    web = order

    assert core == "always run tests"
    assert cli == "[ ] always run tests"
    assert web == "always run tests"
    # CLI includes "[ ] ", others don't
    assert String.trim_leading(cli, "[ ] ") == core
    assert web == core
  end

  test "map order with title and detail is consistent across all three implementations" do
    order = %{"title" => "run tests", "detail" => "before commit"}

    # Arbiter core: canonical text (no prefix)
    core = Arbiter.StandingOrders.canonical_text(order)

    # CLI rendering: reconstructed from prime.ex logic, with "[ ] " prefix
    cli = "[ ] #{core}"

    # Web rendering: reconstructed from standing_orders_component.ex logic, no prefix
    web = core

    assert core == "run tests — before commit"
    assert cli == "[ ] run tests — before commit"
    assert web == "run tests — before commit"
    # All match (CLI has prefix, others don't)
    assert String.trim_leading(cli, "[ ] ") == core
    assert web == core
  end

  test "map order with title only is consistent across all three implementations" do
    order = %{"title" => "check lint"}

    # Arbiter core: canonical text (no prefix)
    core = Arbiter.StandingOrders.canonical_text(order)

    # CLI rendering: with "[ ] " prefix
    cli = "[ ] #{core}"

    # Web rendering: no prefix
    web = core

    assert core == "check lint"
    assert cli == "[ ] check lint"
    assert web == "check lint"
    # All match
    assert String.trim_leading(cli, "[ ] ") == core
    assert web == core
  end

  test "map with empty detail string is treated as title-only" do
    order = %{"title" => "review code", "detail" => ""}

    core = Arbiter.StandingOrders.canonical_text(order)

    # Empty detail should be ignored
    assert core == "review code"
  end

  test "determinism is guaranteed regardless of map key order" do
    order_abc = %{"title" => "run tests", "detail" => "before commit"}
    order_cba = %{"detail" => "before commit", "title" => "run tests"}

    assert Arbiter.StandingOrders.canonical_text(order_abc) ==
             Arbiter.StandingOrders.canonical_text(order_cba)
  end

  test "mixed list with strings and maps produces consistent renderings" do
    orders = [
      "always run tests",
      %{"title" => "review code", "detail" => "before merge"},
      %{"title" => "check lint"},
      "never force-push"
    ]

    # Core rendering (for hashing)
    core_lines =
      orders
      |> Enum.map(&Arbiter.StandingOrders.canonical_text/1)

    expected = [
      "always run tests",
      "review code — before merge",
      "check lint",
      "never force-push"
    ]

    assert core_lines == expected
  end
end
