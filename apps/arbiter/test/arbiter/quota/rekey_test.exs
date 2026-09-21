defmodule Arbiter.Quota.RekeyTest do
  @moduledoc """
  P5 (`docs/provider-account-design.md` §6) — the duplicate collapse the
  re-key migration performs once several workspaces' rows land on one
  provider account.

  The subtlety §6 names: `anthropic_quotas` is written by two actions with
  **disjoint** `upsert_fields`, so the header block and the oauth block carry
  two independent timestamps. A newest-row-wins collapse silently discards a
  fresher oauth block. These tests use deliberately disjoint `captured_at` /
  `oauth_captured_at` orderings so a per-row collapse cannot pass them.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Quota.Rekey

  defp ts(iso), do: elem(DateTime.from_iso8601(iso), 1)

  describe "collapse_anthropic/1" do
    test "takes header columns from the newest captured_at and oauth columns from the newest oauth_captured_at" do
      # Row A has the fresher header block; row B the fresher oauth block.
      row_a = %{
        id: "a",
        provider: "claude",
        provider_account_id: "acct",
        utilization_5h: 0.9,
        status_5h: "allowed",
        reset_5h_at: ts("2026-09-20T12:00:00Z"),
        utilization_7d: 0.5,
        status_7d: "allowed",
        reset_7d_at: nil,
        representative_claim: "five_hour",
        overage_status: "rejected",
        capture_source: "oauth_poll",
        captured_at: ts("2026-09-20T10:00:00Z"),
        per_model_utilization: %{"sonnet" => 0.1},
        extra_usage: %{},
        oauth_utilization_5h: 0.11,
        oauth_utilization_7d: 0.12,
        oauth_captured_at: ts("2026-09-19T01:00:00Z")
      }

      row_b = %{
        row_a
        | id: "b",
          utilization_5h: 0.1,
          status_5h: "stale",
          capture_source: "headers",
          captured_at: ts("2026-09-19T10:00:00Z"),
          per_model_utilization: %{"opus" => 0.77},
          extra_usage: %{"amount_usd" => 4.25},
          oauth_utilization_5h: 0.71,
          oauth_utilization_7d: 0.72,
          oauth_captured_at: ts("2026-09-20T23:00:00Z")
      }

      collapsed = Rekey.collapse_anthropic([row_a, row_b])

      # Header group: row A (newest captured_at).
      assert collapsed.utilization_5h == 0.9
      assert collapsed.status_5h == "allowed"
      assert collapsed.capture_source == "oauth_poll"
      assert collapsed.captured_at == ts("2026-09-20T10:00:00Z")
      assert collapsed.representative_claim == "five_hour"

      # Oauth group: row B (newest oauth_captured_at) — the block a naive
      # newest-row-wins collapse would have thrown away.
      assert collapsed.per_model_utilization == %{"opus" => 0.77}
      assert collapsed.extra_usage == %{"amount_usd" => 4.25}
      assert collapsed.oauth_utilization_5h == 0.71
      assert collapsed.oauth_utilization_7d == 0.72
      assert collapsed.oauth_captured_at == ts("2026-09-20T23:00:00Z")
    end

    test "keeps the oauth block of the only row that has one" do
      base = %{
        id: "a",
        provider: "claude",
        provider_account_id: "acct",
        utilization_5h: 0.1,
        status_5h: nil,
        reset_5h_at: nil,
        utilization_7d: nil,
        status_7d: nil,
        reset_7d_at: nil,
        representative_claim: nil,
        overage_status: nil,
        capture_source: "headers",
        captured_at: ts("2026-09-20T10:00:00Z"),
        per_model_utilization: %{},
        extra_usage: %{},
        oauth_utilization_5h: nil,
        oauth_utilization_7d: nil,
        oauth_captured_at: nil
      }

      with_oauth = %{
        base
        | id: "b",
          captured_at: ts("2026-09-18T10:00:00Z"),
          per_model_utilization: %{"sonnet" => 0.4},
          oauth_utilization_5h: 0.44,
          oauth_captured_at: ts("2026-09-18T11:00:00Z")
      }

      collapsed = Rekey.collapse_anthropic([base, with_oauth])

      assert collapsed.captured_at == ts("2026-09-20T10:00:00Z")
      assert collapsed.per_model_utilization == %{"sonnet" => 0.4}
      assert collapsed.oauth_utilization_5h == 0.44
    end

    test "a single row collapses to itself" do
      row = %{
        id: "a",
        provider: "claude",
        provider_account_id: "acct",
        utilization_5h: 0.3,
        captured_at: ts("2026-09-20T10:00:00Z"),
        oauth_captured_at: nil,
        per_model_utilization: %{}
      }

      assert Rekey.collapse_anthropic([row]) == row
    end

    test "compares ISO-8601 strings, as the raw SQL read hands them back" do
      a = %{id: "a", captured_at: "2026-09-20 10:00:00", oauth_captured_at: nil, status_5h: "new"}
      b = %{id: "b", captured_at: "2026-09-19 10:00:00", oauth_captured_at: "2026-09-21 10:00:00", status_5h: "old", oauth_utilization_5h: 0.5}

      collapsed = Rekey.collapse_anthropic([a, b])

      assert collapsed.status_5h == "new"
      assert collapsed.oauth_utilization_5h == 0.5
      assert collapsed.oauth_captured_at == "2026-09-21 10:00:00"
    end
  end

  describe "collapse_newest/1" do
    test "single-writer tables take the whole newest-captured_at row" do
      old = %{id: "a", captured_at: ts("2026-09-19T10:00:00Z"), plan: "plus"}
      new = %{id: "b", captured_at: ts("2026-09-20T10:00:00Z"), plan: "pro"}

      assert Rekey.collapse_newest([old, new]) == new
      assert Rekey.collapse_newest([new, old]) == new
    end

    test "a nil captured_at never beats a real one" do
      nil_row = %{id: "a", captured_at: nil, plan: "plus"}
      real = %{id: "b", captured_at: ts("2026-09-19T10:00:00Z"), plan: "pro"}

      assert Rekey.collapse_newest([nil_row, real]) == real
    end
  end
end
