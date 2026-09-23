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
      assert html =~ ~r/id="lb-live"[^>]*phx-disconnected/
      refute html =~ ~r/id="lb-stale"[^>]*phx-disconnected/
      assert html =~ ~r/id="lb-live"[^>]*phx-connected/
      refute html =~ ~r/id="lb-stale"[^>]*phx-connected/
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

  # bd-gukyy1: the fill carries the provider's hue, and only a `:red` pace state
  # (which `in_overage` folds into) overrides it. The finer gradations live in
  # the note and the title.
  describe "quota_bar/1 provider hue and pace note" do
    # A 5h reset `minutes_left` minutes away: 150 leaves the window half elapsed,
    # 290 leaves it 10 minutes in — under the 15-minute sampling floor.
    defp reset_in(minutes_left),
      do: DateTime.add(DateTime.utc_now(), minutes_left * 60, :second)

    defp bar(attrs) do
      render_component(&quota_bar/1, Map.merge(%{window: "5h", reset_at: nil}, attrs))
      |> LazyHTML.from_fragment()
    end

    defp fill(doc),
      do: doc |> LazyHTML.query("[data-quota-fill]") |> LazyHTML.attribute("style") |> hd()

    defp note(doc), do: doc |> LazyHTML.query("[data-quota-note]")

    defp title(doc),
      do: doc |> LazyHTML.query("[data-quota-bar]") |> LazyHTML.attribute("title") |> hd()

    test "claude and antigravity map to distinct --arb-* hues, with a documented fallback" do
      claude = ArbiterWeb.QuotaHelpers.quota_provider_hue("claude")
      antigravity = ArbiterWeb.QuotaHelpers.quota_provider_hue("antigravity")
      fallback = ArbiterWeb.QuotaHelpers.quota_provider_hue("somebody_else")

      for hue <- [claude, antigravity, fallback], do: assert(hue =~ ~r/^var\(--arb-[a-z-]+\)$/)

      assert claude != antigravity
      assert ArbiterWeb.QuotaHelpers.quota_provider_hue(nil) == fallback
    end

    test "a claude bar at 20% and one at 60% carry the same provider fill" do
      hue = ArbiterWeb.QuotaHelpers.quota_provider_hue("claude")
      low = bar(%{provider: "claude", utilization: 0.2})
      high = bar(%{provider: "claude", utilization: 0.6})

      assert fill(low) =~ "background-color: #{hue};"
      assert fill(high) =~ "background-color: #{hue};"
    end

    test "an amber-state bar carries the same provider fill as a green one" do
      reset_at = reset_in(150)
      assert ArbiterWeb.QuotaHelpers.quota_pace_state_5h("claude", 0.6, reset_at, nil) == :amber
      assert ArbiterWeb.QuotaHelpers.quota_pace_state_5h("claude", 0.2, reset_at, nil) == :green

      amber = bar(%{provider: "claude", utilization: 0.6, reset_at: reset_at})
      green = bar(%{provider: "claude", utilization: 0.2, reset_at: reset_at})

      hue = ArbiterWeb.QuotaHelpers.quota_provider_hue("claude")
      assert fill(amber) =~ "background-color: #{hue};"
      assert fill(green) =~ "background-color: #{hue};"
    end

    test "a :red-state bar and an in_overage bar both carry the red fill" do
      reset_at = reset_in(150)
      assert ArbiterWeb.QuotaHelpers.quota_pace_state_5h("claude", 0.8, reset_at, nil) == :red

      red = bar(%{provider: "claude", utilization: 0.8, reset_at: reset_at})
      overage = bar(%{provider: "claude", utilization: 0.3, overage_status: "in_overage"})

      assert fill(red) =~ "background-color: var(--arb-fail);"
      assert fill(overage) =~ "background-color: var(--arb-fail);"
    end

    test "amber on pace: the note carries a warning glyph plus the pace label, coloured by state" do
      reset_at = reset_in(150)
      label = ArbiterWeb.QuotaHelpers.quota_pace_label_5h("claude", 0.6, reset_at, nil, :throttle)
      color = ArbiterWeb.QuotaHelpers.quota_color_5h("claude", 0.6, reset_at, nil)
      assert label

      doc =
        bar(%{provider: "claude", utilization: 0.6, reset_at: reset_at, on_exhaustion: :throttle})

      assert LazyHTML.text(note(doc)) =~ label
      assert note(doc) |> LazyHTML.query("[data-quota-glyph]") |> Enum.count() == 1
      assert note(doc) |> LazyHTML.attribute("style") |> hd() =~ "color: #{color};"
    end

    test "red on pace: the note carries the glyph and the red pace label" do
      reset_at = reset_in(150)
      label = ArbiterWeb.QuotaHelpers.quota_pace_label_5h("claude", 0.8, reset_at, nil, :throttle)
      color = ArbiterWeb.QuotaHelpers.quota_color_5h("claude", 0.8, reset_at, nil)

      doc =
        bar(%{provider: "claude", utilization: 0.8, reset_at: reset_at, on_exhaustion: :throttle})

      assert LazyHTML.text(note(doc)) =~ label
      assert note(doc) |> LazyHTML.query("[data-quota-glyph]") |> Enum.count() == 1
      assert note(doc) |> LazyHTML.attribute("style") |> hd() =~ "color: #{color};"
    end

    test "sampling: the note says sampling, without a warning glyph" do
      reset_at = reset_in(290)
      assert ArbiterWeb.QuotaHelpers.quota_pace_state_5h("claude", 0.3, reset_at, nil) == :grey

      doc = bar(%{provider: "claude", utilization: 0.3, reset_at: reset_at})

      assert LazyHTML.text(note(doc)) =~ "sampling"
      assert note(doc) |> LazyHTML.query("[data-quota-glyph]") |> Enum.count() == 0
      assert fill(doc) =~ ArbiterWeb.QuotaHelpers.quota_provider_hue("claude")
    end

    test "quiet: with no pace label the note is quota_reset_label/1" do
      reset_at = reset_in(150)
      doc = bar(%{provider: "claude", utilization: 0.2, reset_at: reset_at})

      assert LazyHTML.text(note(doc)) =~ ArbiterWeb.QuotaHelpers.quota_reset_label(reset_at)
      assert note(doc) |> LazyHTML.query("[data-quota-glyph]") |> Enum.count() == 0
    end

    test "an amber on-pace bar's title carries utilization, elapsed window, and the pace label" do
      reset_at = reset_in(150)
      label = ArbiterWeb.QuotaHelpers.quota_pace_label_5h("claude", 0.6, reset_at, nil, :throttle)

      doc =
        bar(%{provider: "claude", utilization: 0.6, reset_at: reset_at, on_exhaustion: :throttle})

      assert title(doc) =~ "60% quota used"
      assert title(doc) =~ "of window elapsed"
      assert title(doc) =~ label
    end

    test "the window label is caller-supplied, the window only picks the pace math" do
      doc = bar(%{provider: "antigravity", window: "7d", label: "weekly", utilization: 0.1})
      assert doc |> LazyHTML.query("[data-quota-label]") |> LazyHTML.text() == "weekly"

      doc = bar(%{provider: "claude", window: "7d", utilization: 0.1})
      assert doc |> LazyHTML.query("[data-quota-label]") |> LazyHTML.text() == "7d"
    end

    test "a stale reading is muted, says so, and carries the message in its title" do
      message = "Antigravity CLI (agy) is not installed on this host"

      doc =
        bar(%{
          provider: "antigravity",
          utilization: 0.95,
          reset_at: reset_in(150),
          stale_message: message
        })

      assert doc |> LazyHTML.query("[data-quota-bar][data-quota-stale]") |> Enum.count() == 1
      assert LazyHTML.text(note(doc)) =~ "stale"
      assert title(doc) =~ message
      refute fill(doc) =~ "var(--arb-fail)"
      refute fill(doc) =~ ArbiterWeb.QuotaHelpers.quota_provider_hue("antigravity")
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
