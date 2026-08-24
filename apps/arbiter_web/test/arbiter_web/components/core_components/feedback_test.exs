defmodule ArbiterWeb.CoreComponents.FeedbackTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Feedback

  describe "live_badge/1" do
    test "`live` is required — omitting it raises" do
      assert_raise FunctionClauseError, fn ->
        render_component(&live_badge/1, %{id: "lb"})
      end
    end

    test "live={true} renders the live state, pinging, wired to flip on a genuine disconnect" do
      html = render_component(&live_badge/1, %{id: "lb", live: true})

      assert html =~ "var(--arb-live)"
      assert html =~ "arb-ping"
      assert html =~ "stale"
      assert html =~ "phx-disconnected"
      refute html =~ "phx-connected"
      # Starts on the connected assumption: live visible, stale hidden.
      assert html =~ ~r/id="lb-stale"[^>]*\shidden/
    end

    test "live={false} statically renders the stale state" do
      html = render_component(&live_badge/1, %{id: "lb", live: false})

      assert html =~ "stale — refresh"
      assert html =~ "var(--arb-attention)"
      refute html =~ "arb-ping"
    end
  end

  describe "quota_bar/1" do
    test "renders provider, window, percentage, and reuses quota_pct/1 for the fill" do
      html =
        render_component(&quota_bar/1, %{
          provider: "anthropic",
          window: "5h",
          utilization: 0.683,
          reset_at: nil
        })

      assert html =~ "anthropic"
      assert html =~ "5h"
      # quota_pct(0.683) == 68
      assert html =~ "68%"
      assert html =~ "width: 68%;"
    end

    test "falls back to quota_reset_label/1 when there is no pace warning" do
      html =
        render_component(&quota_bar/1, %{
          window: "5h",
          utilization: nil,
          reset_at: nil
        })

      assert html =~ "—"
    end

    test "de-emphasizes a non-binding window via quota_binding_class/2" do
      html =
        render_component(&quota_bar/1, %{
          window: "7d",
          utilization: 0.1,
          reset_at: nil,
          representative_claim: "five_hour"
        })

      assert html =~ "opacity-50"
    end

    test "the binding window is not de-emphasized" do
      html =
        render_component(&quota_bar/1, %{
          window: "5h",
          utilization: 0.1,
          reset_at: nil,
          representative_claim: "five_hour"
        })

      refute html =~ "opacity-50"
    end
  end

  describe "worker_flow/1" do
    test "renders every step's label from StatusHelpers.worker_flow/0" do
      html = render_component(&worker_flow/1, %{status: :running})

      assert html =~ "Idle"
      assert html =~ "Running"
      assert html =~ "Awaiting review"
      assert html =~ "Completed"
    end

    test "colors the current step live, and marks earlier steps done" do
      html = render_component(&worker_flow/1, %{status: :awaiting})

      assert html =~ "var(--arb-attention)"
      assert html =~ "✓"
    end

    test "failed reds the current step instead of adding a fifth column" do
      html = render_component(&worker_flow/1, %{status: :running, failed: true})

      assert html =~ "var(--arb-fail)"
      refute html =~ "var(--arb-live)"
    end

    test "compact names the failed step instead of the fifth column" do
      html = render_component(&worker_flow/1, %{status: :running, failed: true, compact: true})

      assert html =~ "failed"
      assert html =~ "var(--arb-fail)"
    end

    test "compact renders a dot track with an n-of-4 counter" do
      html = render_component(&worker_flow/1, %{status: :awaiting, compact: true})

      assert html =~ "3 of 4"
    end
  end

  describe "toast/1" do
    test "info and error map to cyan and red" do
      info = render_component(&toast/1, %{inner_block: [%{inner_block: fn _, _ -> "hi" end}]})
      assert info =~ "var(--arb-info)"

      error =
        render_component(&toast/1, %{
          tone: "error",
          inner_block: [%{inner_block: fn _, _ -> "hi" end}]
        })

      assert error =~ "var(--arb-fail)"
    end

    test "attention and live tones are amber and lime" do
      attention =
        render_component(&toast/1, %{
          tone: "attention",
          inner_block: [%{inner_block: fn _, _ -> "hi" end}]
        })

      assert attention =~ "var(--arb-attention)"

      live =
        render_component(&toast/1, %{
          tone: "live",
          inner_block: [%{inner_block: fn _, _ -> "hi" end}]
        })

      assert live =~ "var(--arb-live)"
    end

    test "renders the action word and dismiss key hint" do
      html =
        render_component(&toast/1, %{
          action: "retry",
          inner_block: [%{inner_block: fn _, _ -> "failed" end}]
        })

      assert html =~ "retry"
      assert html =~ ~r/>\s*esc\s*</
    end

    test ~s(dismiss_key="" hides the key hint) do
      html =
        render_component(&toast/1, %{
          dismiss_key: "",
          inner_block: [%{inner_block: fn _, _ -> "failed" end}]
        })

      refute html =~ ~r/>\s*esc\s*</
    end
  end

  describe "toast_group/1" do
    test "renders info and error flash as toasts" do
      html = render_component(&toast_group/1, %{flash: %{"info" => "saved", "error" => "boom"}})

      assert html =~ "saved"
      assert html =~ "boom"
    end

    test "keeps the client-error/server-error reconnect toasts with the spinner" do
      html = render_component(&toast_group/1, %{flash: %{}})

      assert html =~ "toast-client-error"
      assert html =~ "toast-server-error"
      assert html =~ "hero-arrow-path"
      assert html =~ "animate-spin"
    end
  end

  describe "empty_state/1" do
    test "renders the message and an icon" do
      html =
        render_component(&empty_state/1, %{
          icon: "hero-inbox",
          inner_block: [%{inner_block: fn _, _ -> "No issues match this filter." end}]
        })

      assert html =~ "No issues match this filter."
      assert html =~ "hero-inbox"
      assert html =~ "border-dashed"
    end

    test "renders an optional detail line" do
      html =
        render_component(&empty_state/1, %{
          detail: "every open issue has an unclosed blocker",
          inner_block: [%{inner_block: fn _, _ -> "No issues are ready." end}]
        })

      assert html =~ "every open issue has an unclosed blocker"
    end
  end
end
