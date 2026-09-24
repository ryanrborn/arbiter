defmodule ArbiterWeb.QuotaHelpersTest do
  use ExUnit.Case, async: true

  import ArbiterWeb.QuotaHelpers

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot

  describe "quota_provider_label/1" do
    test "maps known provider codes to display names" do
      assert quota_provider_label("claude") == "Claude"
      assert quota_provider_label("codex") == "Codex"
      assert quota_provider_label("gemini_cli") == "Gemini CLI"
      assert quota_provider_label("antigravity") == "Antigravity"
    end

    test "title-cases unknown provider codes as a fallback" do
      assert quota_provider_label("some_new_provider") == "Some New Provider"
    end
  end

  describe "quota_elapsed_pct_5h/2" do
    test "nil reset_at yields no marker" do
      assert quota_elapsed_pct_5h("claude", nil) == nil
    end

    test "midpoint of the 5h window is 50% elapsed" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_elapsed_pct_5h("claude", reset_at) == 50
    end

    test "clamps to 0 when the window hasn't opened yet" do
      reset_at = DateTime.add(DateTime.utc_now(), 10 * 60 * 60, :second)
      assert quota_elapsed_pct_5h("claude", reset_at) == 0
    end

    test "clamps to 100 when the window is overdue to reset" do
      reset_at = DateTime.add(DateTime.utc_now(), -60, :second)
      assert quota_elapsed_pct_5h("claude", reset_at) == 100
    end

    test "providers without a fixed window get no marker, even with a reset_at present" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_elapsed_pct_5h("codex", reset_at) == nil
      assert quota_elapsed_pct_5h("gemini_cli", reset_at) == nil
      assert quota_elapsed_pct_5h("someday_cli", reset_at) == nil
    end

    test "antigravity gets a marker identical to claude's, same fixed 5h window" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_elapsed_pct_5h("antigravity", reset_at) == 50

      assert quota_elapsed_pct_5h("antigravity", reset_at) ==
               quota_elapsed_pct_5h("claude", reset_at)
    end
  end

  describe "quota_elapsed_pct_7d/2" do
    test "nil reset_at yields no marker" do
      assert quota_elapsed_pct_7d("claude", nil) == nil
    end

    test "a third of the way through a 7d window" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_elapsed_pct_7d("claude", reset_at) == 33
    end

    test "providers without a fixed window get no marker" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_elapsed_pct_7d("codex", reset_at) == nil
      assert quota_elapsed_pct_7d("gemini_cli", reset_at) == nil
      assert quota_elapsed_pct_7d("someday_cli", reset_at) == nil
    end

    test "antigravity gets a marker identical to claude's, same fixed 7d window" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_elapsed_pct_7d("antigravity", reset_at) == 33

      assert quota_elapsed_pct_7d("antigravity", reset_at) ==
               quota_elapsed_pct_7d("claude", reset_at)
    end
  end

  describe "quota_tooltip_5h/3" do
    test "nil reset_at yields no tooltip" do
      assert quota_tooltip_5h("claude", 0.62, nil) == nil
    end

    test "states both usage and elapsed numbers in words" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)

      assert quota_tooltip_5h("claude", 0.62, reset_at) ==
               "62% quota used · 50% of window elapsed (2.5h into 5h)"
    end

    test "falls back to a neutral phrase when utilization is unknown" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)

      assert quota_tooltip_5h("claude", nil, reset_at) ==
               "no usage data · 50% of window elapsed (2.5h into 5h)"
    end

    test "providers without a fixed window get no tooltip" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_tooltip_5h("codex", 0.62, reset_at) == nil
      assert quota_tooltip_5h("gemini_cli", 0.62, reset_at) == nil
      assert quota_tooltip_5h("someday_cli", 0.62, reset_at) == nil
    end

    test "antigravity gets a tooltip identical to claude's" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)

      assert quota_tooltip_5h("antigravity", 0.62, reset_at) ==
               "62% quota used · 50% of window elapsed (2.5h into 5h)"
    end
  end

  # ---- colour from the gate's pace verdict (bd-clzkvp) -------------------
  #
  # Every case pins `@now` and names its gate policy outright, so the verdict
  # depends only on the numbers in the test.

  @now ~U[2026-09-23 12:00:00Z]
  @five_hours 18_000
  @seven_days 604_800

  defp account(config), do: %ProviderAccount{provider: :claude, quota_config: config}
  defp paced(extra \\ %{}), do: account(Map.merge(%{"threshold_mode" => "paced"}, extra))
  defp flat, do: account(%{})
  defp gate_policy(account, enforcing?), do: %{policy: {account, nil}, enforcing?: enforcing?}

  defp reset_after(elapsed, seconds),
    do: DateTime.add(@now, round((1 - elapsed) * seconds), :second)

  defp bar(provider, window, u, elapsed, extra \\ %{}) do
    seconds = if window == "5h", do: @five_hours, else: @seven_days

    Map.merge(
      %{
        provider: provider,
        window: window,
        label: window,
        utilization: u,
        reset_at: reset_after(elapsed, seconds),
        overage_status: nil
      },
      extra
    )
  end

  defp pace(bar, account, enforcing? \\ true),
    do: quota_pace(bar, gate_policy(account, enforcing?), @now)

  defp state(bar, account \\ paced()), do: pace(bar, account).state

  describe "quota_pace/3 — state is the gate's verdict" do
    test "ok → green, approaching → amber, holding → red, sampling → grey" do
      # 5h, paced floor 0.35 until 35% elapsed; amber from 10 points under it.
      assert state(bar("claude", "5h", 0.36, 0.1)) == :red
      assert state(bar("claude", "5h", 0.30, 0.1)) == :amber
      assert state(bar("claude", "5h", 0.20, 0.3)) == :green
      assert state(bar("claude", "5h", 0.10, 0.02)) == :grey
    end

    test "regression: 7d at 35% used / 29% elapsed is red only where the gate holds" do
      # The deficit-minute colours called this red for every account. At the
      # default 0.20 weekly floor the paced gate does hold it (1.2x pace)…
      assert state(bar("claude", "7d", 0.35, 0.29)) == :red

      assert Gate.gating_window(snapshot("7d", 0.35, 0.29), paced(), now: @now) != nil

      # …but with a 0.40 weekly floor the gate dispatches, so it is not red.
      loose = paced(%{"weekly_paced_floor" => 0.4})
      assert state(bar("claude", "7d", 0.35, 0.29), loose) == :amber
      assert Gate.gating_window(snapshot("7d", 0.35, 0.29), loose, now: @now) == nil
    end

    test "under pace near reset is amber at worst — the 21:45Z/0.89 false-alarm case" do
      assert state(bar("claude", "5h", 0.89, 0.98)) == :amber
      assert state(bar("claude", "5h", 0.70, 0.98)) == :green
    end

    test "the paced floor holds however early the window is" do
      assert state(bar("claude", "5h", 0.5, 0.005)) == :red
    end

    test "in_overage forces red regardless of pace" do
      assert state(bar("claude", "5h", 0.2, 0.5, %{overage_status: "in_overage"})) == :red
    end

    test "nil utilization is green (no usage data, distinct from sampling)" do
      assert state(bar("claude", "5h", nil, 0.5)) == :green
    end

    test "a window with no fixed length uses the gate's flat fallback" do
      # Codex "session" / Gemini CLI "used" have no length, so paced falls
      # back to the 0.85 flat ceiling — as the gate does.
      for {provider, label} <- [{"codex", "session"}, {"gemini_cli", "used"}] do
        assert state(bar(provider, "5h", 0.35, 0.5, %{label: label})) == :green
        assert state(bar(provider, "5h", 0.80, 0.5, %{label: label})) == :amber
        assert state(bar(provider, "5h", 0.90, 0.5, %{label: label})) == :red
      end
    end

    test "a nil reset_at uses the flat fallback too" do
      assert state(bar("claude", "5h", 0.95, 0.5, %{reset_at: nil})) == :red
      assert state(bar("claude", "5h", 0.35, 0.5, %{reset_at: nil})) == :green
    end

    test "antigravity (5h / weekly) is paced exactly like claude" do
      assert state(bar("antigravity", "5h", 0.36, 0.1)) == :red
      assert state(bar("antigravity", "7d", 0.35, 0.29, %{label: "weekly"})) == :red
    end

    test "the account's floors move the colour" do
      assert state(bar("claude", "5h", 0.4, 0.1)) == :red
      assert state(bar("claude", "5h", 0.4, 0.1), paced(%{"paced_floor" => 0.6})) == :green
    end
  end

  describe "quota_pace/3 — would hold vs holding" do
    test "a paced, enforcing account is holding" do
      assert %{state: :red, holding: :enforcing, mode: :paced, ceiling: 0.35} =
               pace(bar("claude", "5h", 0.4, 0.1), paced())
    end

    test "a flat account is coloured by the paced thresholds, but only would hold" do
      assert %{state: :red, holding: :not_enforcing, mode: :paced} =
               pace(bar("claude", "5h", 0.4, 0.1), flat())
    end

    test "a :continue workspace never holds, so a paced red only would hold" do
      assert %{state: :red, holding: :not_enforcing} =
               pace(bar("claude", "5h", 0.4, 0.1), paced(), false)
    end

    test "a flat gate that holds is red and holding even where pacing would not" do
      # 90% at 99% elapsed: under the paced ceiling, over the flat 0.85.
      assert %{state: :red, holding: :enforcing, mode: :flat, ceiling: 0.85} =
               pace(bar("claude", "5h", 0.9, 0.99), flat())
    end

    test "no holding flag below the ceiling" do
      assert %{holding: nil} = pace(bar("claude", "5h", 0.3, 0.1), paced())
    end

    test "nil gate_policy resolves the install default" do
      assert %{state: :red, holding: :not_enforcing} =
               quota_pace(bar("claude", "5h", 0.4, 0.1), nil, @now)
    end

    test "quota_hold_text/2 tells the operator which it is" do
      u = 0.4
      b = bar("claude", "5h", u, 0.1)

      assert quota_hold_text(pace(b, paced()), u) ==
               "holding dispatch — 40% used ≥ paced ceiling 35%"

      assert quota_hold_text(pace(b, flat()), u) ==
               "would hold — 40% used ≥ paced ceiling 35% (gate not enforcing)"

      assert quota_hold_text(pace(bar("claude", "5h", 0.3, 0.1), paced()), 0.3) ==
               "approaching paced ceiling 35%"

      assert quota_hold_text(pace(bar("claude", "5h", 0.9, 0.99), flat()), 0.9) ==
               "holding dispatch — 90% used ≥ ceiling 85%"

      assert quota_hold_text(pace(bar("claude", "5h", 0.1, 0.3), paced()), 0.1) == nil
    end
  end

  # AC4: a red bar always means the gate holds (or, for an account that is
  # not paced, that the paced gate would), and an enforcing gate that holds
  # is always red. Both sides run over the same inputs.
  describe "red ⇔ the gate holds, over a grid of inputs" do
    @utilizations [0.0, 0.04, 0.1, 0.19, 0.2, 0.25, 0.3, 0.34, 0.35, 0.36, 0.5] ++
                    [0.6, 0.75, 0.84, 0.85, 0.9, 0.99, 1.0]
    @elapsed [0.001, 0.04, 0.1, 0.2, 0.29, 0.35, 0.5, 0.6, 0.9, 0.99]

    for window <- ["5h", "7d"],
        {name, account} <- [
          paced: quote(do: paced()),
          flat: quote(do: flat()),
          loose_floors: quote(do: paced(%{"paced_floor" => 0.6, "weekly_paced_floor" => 0.45})),
          tight_flat:
            quote(do: account(%{"throttle_threshold" => 0.5, "weekly_threshold" => 0.4}))
        ] do
      test "#{window}, #{name} account" do
        account = unquote(account)
        window = unquote(window)

        for u <- @utilizations, e <- @elapsed do
          pace = pace(bar("claude", window, u, e), account)
          holds? = gate_holds?(window, u, e, account)
          paced_holds? = gate_holds?(window, u, e, Gate.paced_policy(account))
          where = "u=#{u} elapsed=#{e}: #{inspect(pace)}"

          if pace.state == :red do
            case pace.holding do
              :enforcing -> assert holds?, where
              :not_enforcing -> assert paced_holds? and not holds?, where
            end
          end

          if holds?, do: assert(pace.state == :red and pace.holding == :enforcing, where)
        end
      end
    end
  end

  defp snapshot(window, u, elapsed) do
    {primary, long} =
      if window == "5h", do: {{u, elapsed}, {0.0, 0.5}}, else: {{0.0, 0.5}, {u, elapsed}}

    %Snapshot{
      provider: "claude",
      utilization: elem(primary, 0),
      status: "allowed",
      reset_at: reset_after(elem(primary, 1), @five_hours),
      captured_at: @now,
      window_label: "5h",
      secondary_utilization: elem(long, 0),
      secondary_status: "allowed",
      secondary_reset_at: reset_after(elem(long, 1), @seven_days),
      secondary_window_label: "7d"
    }
  end

  defp gate_holds?(window, u, elapsed, policy) do
    case Gate.gating_window(snapshot(window, u, elapsed), policy, now: @now) do
      %{window: ^window, signal: :utilization} -> true
      _ -> false
    end
  end

  describe "quota_pace_label/3 — on_exhaustion-aware label text" do
    defp label(bar, on_exhaustion, account \\ paced()),
      do: quota_pace_label(bar, pace(bar, account), on_exhaustion)

    test "labels the throttle mode as \"stalls in Nm\"" do
      assert label(bar("claude", "5h", 0.35, 0.1), :throttle) =~ ~r/^stalls in \d+m$/
    end

    test "projects the burn: 35% in 30 minutes leaves 65% for ~55 minutes" do
      assert label(bar("claude", "5h", 0.35, 0.1), :throttle) == "stalls in 55m"
    end

    test "labels the continue mode as \"starts billing overage in Nm\"" do
      assert label(bar("claude", "5h", 0.35, 0.1), :continue) =~
               ~r/^starts billing overage in \d+m$/
    end

    test "labels amber too" do
      assert label(bar("claude", "5h", 0.30, 0.1), :throttle) =~ ~r/^stalls in /
    end

    test "no label when the bar is green or sampling" do
      assert label(bar("claude", "5h", 0.2, 0.5), :throttle) == nil
      assert label(bar("claude", "5h", 0.1, 0.02), :throttle) == nil
    end

    test "antigravity always says \"stalls in Nm\", never overage billing, even under :continue" do
      assert label(bar("antigravity", "5h", 0.35, 0.1), :continue) =~ ~r/^stalls in \d+m$/

      assert label(bar("antigravity", "7d", 0.35, 0.1, %{label: "weekly"}), :continue) =~
               ~r/^stalls in /
    end

    test "nil for providers without a fixed window, even when red" do
      for provider <- ["codex", "gemini_cli", "someday_cli"] do
        b = bar(provider, "5h", 0.95, 0.1, %{label: "session"})
        assert pace(b, paced()).state == :red
        assert label(b, :continue) == nil
      end
    end
  end

  describe "quota_pace_ratio/2 — pace ratio exposed for tooltip text" do
    defp ratio(bar), do: quota_pace_ratio(bar, pace(bar, paced()))

    test "reports how many times faster than on-pace the current burn is" do
      assert ratio(bar("claude", "5h", 0.35, 0.1)) == "3.5x pace"
      assert ratio(bar("claude", "7d", 0.35, 0.1)) == "3.5x pace"
    end

    test "reports sampling when the verdict is sampling" do
      assert ratio(bar("claude", "5h", 0.1, 0.02)) =~ "sampling"
    end

    test "nil for providers without a fixed window" do
      for provider <- ["codex", "gemini_cli", "someday_cli"] do
        assert ratio(bar(provider, "5h", 0.5, 0.5)) == nil
      end
    end

    test "antigravity reports the same pace ratio as claude" do
      assert ratio(bar("antigravity", "5h", 0.35, 0.1)) == ratio(bar("claude", "5h", 0.35, 0.1))
    end
  end

  describe "quota_binding_class/2 — de-emphasize the non-binding window" do
    test "no emphasis class when this window is the binding one" do
      assert quota_binding_class("five_hour", "five_hour") == nil
    end

    test "de-emphasis class when this window isn't the binding one" do
      assert quota_binding_class("five_hour", "seven_day") == "opacity-50"
    end

    test "no emphasis class when representative_claim is unknown" do
      assert quota_binding_class(nil, "five_hour") == nil
    end
  end

  describe "quota_binding_title/2 — explain the non-binding window" do
    test "no explanation title when this window is the binding one" do
      assert quota_binding_title("five_hour", "five_hour") == nil
      assert quota_binding_title("seven_day", "seven_day") == nil
    end

    test "explanation title names it as not the binding window and names the binding window" do
      assert quota_binding_title("seven_day", "five_hour") ==
               "not the binding window — Anthropic is currently limiting on 7d"

      assert quota_binding_title("five_hour", "seven_day") ==
               "not the binding window — Anthropic is currently limiting on 5h"
    end

    test "no explanation title when representative_claim is unknown" do
      assert quota_binding_title(nil, "five_hour") == nil
    end
  end

  describe "quota_note_color/2 — note/countdown colour derived from pace state" do
    test "amber pace state maps to --arb-attention" do
      assert quota_note_color(:amber, false) == "var(--arb-attention)"
    end

    test "red pace state maps to --arb-fail" do
      assert quota_note_color(:red, false) == "var(--arb-fail)"
    end

    test "grey/sampling and green pace states map to nil (neutral)" do
      assert quota_note_color(:grey, false) == nil
      assert quota_note_color(:green, false) == nil
    end

    test "stale reading maps to nil (neutral)" do
      assert quota_note_color(:red, true) == nil
      assert quota_note_color(:amber, true) == nil
      assert quota_note_color(:grey, true) == nil
      assert quota_note_color(:green, true) == nil
    end
  end

  describe "quota_tooltip_7d/3" do
    test "renders window durations in days" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)

      assert quota_tooltip_7d("claude", 0.45, reset_at) ==
               "45% quota used · 33% of window elapsed (2.3d into 7d)"
    end

    test "providers without a fixed window get no tooltip" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_tooltip_7d("codex", 0.45, reset_at) == nil
      assert quota_tooltip_7d("gemini_cli", 0.45, reset_at) == nil
      assert quota_tooltip_7d("someday_cli", 0.45, reset_at) == nil
    end

    test "antigravity gets a tooltip identical to claude's" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)

      assert quota_tooltip_7d("antigravity", 0.45, reset_at) ==
               "45% quota used · 33% of window elapsed (2.3d into 7d)"
    end
  end
end
