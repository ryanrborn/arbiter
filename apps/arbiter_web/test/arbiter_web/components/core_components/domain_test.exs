defmodule ArbiterWeb.CoreComponents.DomainTest do
  use ExUnit.Case, async: true

  use Phoenix.Component
  import Phoenix.LiveViewTest
  import ArbiterWeb.CoreComponents.Domain

  describe "stat_card/1" do
    test "renders the label, the value and an optional note" do
      html =
        render_component(&stat_card/1, label: "Active workers", value: 4, note: "2 slots free")

      assert html =~ "Active workers"
      assert html =~ "4"
      assert html =~ "2 slots free"
    end

    test "omits the note line entirely when there is none" do
      html = render_component(&stat_card/1, label: "Workspaces", value: 3)

      refute html =~ "arb-stat-note"
    end

    test "defaults to the grey title tone — most stats stay grey" do
      html = render_component(&stat_card/1, label: "Workspaces", value: 3)

      assert html =~ "text-[var(--text-title)]"
    end

    test "a tone colors the number, not the label" do
      assert render_component(&stat_card/1, label: "Open", value: 84, tone: "live") =~
               "text-[var(--arb-live)]"

      assert render_component(&stat_card/1, label: "Inbox", value: 3, tone: "attention") =~
               "text-[var(--arb-attention)]"

      assert render_component(&stat_card/1, label: "Workers", value: 4, tone: "info") =~
               "text-[var(--arb-info)]"

      assert render_component(&stat_card/1, label: "Failures", value: 1, tone: "fail") =~
               "text-[var(--arb-fail-text)]"
    end

    test "the value is tabular so a column of stat cards lines up" do
      html = render_component(&stat_card/1, label: "Open", value: 84)

      assert html =~ "tabular-nums"
    end
  end

  describe "index_header/1" do
    test "renders title, count in parens and subtitle" do
      html =
        render_component(&index_header/1,
          title: "Issues",
          count: 84,
          subtitle: "Every issue, filterable and paged."
        )

      assert html =~ "Issues"
      assert html =~ "(84)"
      assert html =~ "Every issue, filterable and paged."
    end

    test "a zero count still renders — only a nil count is omitted" do
      assert render_component(&index_header/1, title: "Issues", count: 0) =~ "(0)"
      refute render_component(&index_header/1, title: "Issues") =~ ~r/\(\d+\)/
    end

    test "renders the icon as a fully-qualified hero-* class" do
      html =
        render_component(&index_header/1, title: "Issues", icon: "hero-clipboard-document-list")

      assert html =~ "hero-clipboard-document-list"
    end

    test "renders the actions slot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ArbiterWeb.CoreComponents.Domain.index_header title="Issues">
          <:actions><button>New issue</button></:actions>
        </ArbiterWeb.CoreComponents.Domain.index_header>
        """)

      assert html =~ "New issue"
    end

    test "the subtitle is capped at the prose measure so it stays readable" do
      html = render_component(&index_header/1, title: "Issues", subtitle: "a sentence")

      assert html =~ "max-w-[var(--measure-prose)]"
    end
  end

  describe "task_card/1" do
    test "renders the id verbatim in mono and the title" do
      html =
        render_component(&task_card/1,
          id: "bd-3o8mq1",
          title: "Collapse duplicate status helpers"
        )

      assert html =~ "bd-3o8mq1"
      assert html =~ "Collapse duplicate status helpers"
      assert html =~ "var(--font-mono)"
    end

    test "each of the five accents paints a 2px left rule in its own hue" do
      for {accent, hue} <- [
            {"live", "--arb-live"},
            {"attention", "--arb-attention"},
            {"fail", "--arb-fail"},
            {"proposal", "--arb-proposal"},
            {"info", "--arb-info"}
          ] do
        html = render_component(&task_card/1, id: "bd-1", title: "t", accent: accent)

        assert html =~ "border-l-[color:var(#{hue})]",
               "accent #{accent} should paint a #{hue} left rule"

        assert html =~ "border-l-[length:var(--border-accent-width)]",
               "accent #{accent} should use the 2px accent rule width"
      end
    end

    test "accent=done and no accent paint no left rule — done is not a hue" do
      refute render_component(&task_card/1, id: "bd-1", title: "t", accent: "done") =~
               "border-l-["

      refute render_component(&task_card/1, id: "bd-1", title: "t") =~ "border-l-["
    end

    test "an accented card sits on the card surface; an unaccented one on panel-alt" do
      assert render_component(&task_card/1, id: "bd-1", title: "t", accent: "live") =~
               "bg-[var(--surface-card)]"

      assert render_component(&task_card/1, id: "bd-1", title: "t") =~ "bg-[var(--arb-panel-alt)]"
    end

    test "muted drops the fill and the accent rule — closed work recedes" do
      html =
        render_component(&task_card/1,
          id: "bd-2wilou",
          title: "Default close_upstream",
          muted: true,
          accent: "live"
        )

      assert html =~ "bg-transparent"
      refute html =~ "border-l-["
      assert html =~ "border-[var(--arb-line-soft)]"
      assert html =~ "text-[var(--text-secondary)]"
    end

    test "attention and proposal soften their border into the accent hue" do
      assert render_component(&task_card/1, id: "bd-1", title: "t", accent: "attention") =~
               "border-[color-mix(in_oklch,var(--arb-attention)_35%,transparent)]"

      assert render_component(&task_card/1, id: "bd-1", title: "t", accent: "proposal") =~
               "border-[color-mix(in_oklch,var(--arb-proposal)_35%,transparent)]"
    end

    test "the activity line reds out on a failing card" do
      assert render_component(&task_card/1,
               id: "bd-1",
               title: "t",
               accent: "fail",
               activity: "exit 1"
             ) =~
               "text-[var(--arb-fail-text)]"

      html =
        render_component(&task_card/1,
          id: "bd-1",
          title: "t",
          accent: "live",
          activity: "edit · x.ex"
        )

      assert html =~ "edit · x.ex"
      refute html =~ "text-[var(--arb-fail-text)]"
    end

    test "renders priority, type and difficulty through the data primitives" do
      html =
        render_component(&task_card/1,
          id: "bd-1",
          title: "t",
          priority: 2,
          type: "chore",
          difficulty: 3
        )

      assert html =~ "P2"
      assert html =~ "chore"
      # DifficultyMeter: D3 fills 4 of 5 bars.
      assert html =~ ~s(aria-label="Difficulty D3")
    end

    test "an omitted difficulty renders no meter; an explicit nil renders an empty one" do
      refute render_component(&task_card/1, id: "bd-1", title: "t") =~ "difficulty-bar-empty"

      assert render_component(&task_card/1, id: "bd-1", title: "t", difficulty: nil) =~
               "difficulty-bar-empty"
    end

    test "the meta row is skipped entirely when there is nothing to put in it" do
      refute render_component(&task_card/1, id: "bd-1", title: "t") =~ "arb-card-meta"
    end

    test "the footer right-aligns in the meta row" do
      html = render_component(&task_card/1, id: "bd-1", title: "t", footer: "w-14 · sonnet")

      assert html =~ "w-14 · sonnet"
      assert html =~ "ml-auto"
    end

    test "renders the status and actions slots" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ArbiterWeb.CoreComponents.Domain.task_card id="bd-1" title="t">
          <:status><span>12m</span></:status>
          <:actions><button>Open</button></:actions>
        </ArbiterWeb.CoreComponents.Domain.task_card>
        """)

      assert html =~ "12m"
      assert html =~ "Open"
    end
  end

  describe "run_row/1" do
    defp run(overrides \\ []) do
      render_component(
        &run_row/1,
        Keyword.merge([role: "impl", worker: "w-11", status: "running"], overrides)
      )
    end

    test "the status track is a minmax, never a fixed 92px" do
      html = run()

      # A fixed 92px track cannot hold "awaiting review" (115px with its dot);
      # the label overruns into the metrics cell. Regression guard.
      assert html =~ "minmax(92px,max-content)"
      refute html =~ "_92px_"
    end

    test "lays the row out on the handoff's six-track grid" do
      assert run() =~
               "grid-cols-[84px_48px_minmax(120px,1fr)_minmax(92px,max-content)_minmax(0,max-content)_14px]"
    end

    test "renders the worker id and the outcome" do
      html = run(outcome: "edit · loop_queue.ex")

      assert html =~ "w-11"
      assert html =~ "edit · loop_queue.ex"
    end

    test "renders the round marker only when the run belongs to a gated loop" do
      assert run(round: 3) =~ "rd 3"
      refute run() =~ "rd "
    end

    test "role renders as an outline type tag, with fix_pass humanized to 'fix pass'" do
      assert run(role: "fix_pass") =~ "fix pass"
      assert run(role: "review") =~ "review"
      assert run(role: "conflict") =~ "conflict"
      assert run(role: "main") =~ "main"
    end

    test "an unknown role falls through verbatim rather than blanking the cell" do
      assert run(role: "custom_thing") =~ "custom_thing"
    end

    test "the left rule carries the status: lime running, amber awaiting, red failed" do
      assert run(status: "running") =~ "border-l-[color:var(--arb-live)]"
      assert run(status: "awaiting review") =~ "border-l-[color:var(--arb-attention)]"
      assert run(status: "failed") =~ "border-l-[color:var(--arb-fail)]"
      assert run(status: "completed") =~ "border-l-[color:transparent]"
    end

    test "Arbiter's snake_case statuses hit the same rules as the spaced labels" do
      assert run(status: "awaiting_review") =~ "border-l-[color:var(--arb-attention)]"
      assert run(status: "awaiting_review_gate") =~ "border-l-[color:var(--arb-attention)]"
      assert run(status: :running) =~ "border-l-[color:var(--arb-live)]"
    end

    test "a running row pulses its status chip; a finished one does not" do
      assert run(status: "running") =~ "arb-pulse"
      refute run(status: "completed") =~ "arb-pulse"
    end

    test "shows duration and cost joined, and only what it was given" do
      assert run(duration: "12m", cost: "$0.42") =~ "12m · $0.42"
      assert run(duration: "41m") =~ "41m"
      refute run(duration: "41m") =~ "41m ·"
    end

    test "model and tokens are accepted but never rendered — the row has no width for them" do
      html = run(model: "sonnet", tokens: "38.4k", outcome: "edit · loop_queue.ex")

      refute html =~ "sonnet"
      refute html =~ "38.4k"
    end

    test "selected swaps the surface and strengthens the border" do
      assert run(selected: true) =~ "bg-[var(--surface-card)]"
      assert run(selected: true) =~ "border-[var(--border-strong)]"
      assert run() =~ "bg-[var(--arb-panel-alt)]"
      assert run() =~ "border-[var(--border-default)]"
    end

    test "the chevron rotates -90 when collapsed and sits upright when expanded" do
      assert run() =~ "-rotate-90"
      refute run(expanded: true) =~ "-rotate-90"
      assert run() =~ "hero-chevron-down-micro"
    end

    test "the failed row reds its outcome text" do
      assert run(status: "failed", outcome: "exit 1 · mix test") =~ "text-[var(--arb-fail-text)]"

      refute run(status: "completed", outcome: "no response needed") =~
               "text-[var(--arb-fail-text)]"
    end

    test "accepts a click handler through the global rest" do
      assert run(selected: false, "phx-click": "select_run") =~ ~s(phx-click="select_run")
    end
  end

  describe "log_stream/1" do
    @lines [
      %{time: "14:02:11", role: "system", text: "worktree ready · feat/x @ 4f2a9c1"},
      %{time: "14:02:14", role: "agent", text: "Reading status_helpers.ex", emphasis: true},
      %{time: "14:02:26", role: "tool", text: "edit · status_helpers.ex +41 −63"},
      %{time: "14:03:02", role: "test", text: "2 failures — status_helpers_test.exs:41"}
    ]

    test "renders every line's time, role and text" do
      html = render_component(&log_stream/1, id: "log", lines: @lines)

      assert html =~ "14:02:11"
      assert html =~ "system"
      assert html =~ "worktree ready · feat/x @ 4f2a9c1"
      assert html =~ "2 failures — status_helpers_test.exs:41"
    end

    test "lays each line out in three columns at the default widths" do
      html = render_component(&log_stream/1, id: "log", lines: @lines)

      assert html =~ "grid-template-columns: 66px 76px minmax(0, 1fr)"
    end

    test "the column widths are configurable" do
      html =
        render_component(&log_stream/1, id: "log", lines: @lines, time_width: 90, role_width: 40)

      assert html =~ "grid-template-columns: 90px 40px minmax(0, 1fr)"
    end

    test "roles are the only colored column" do
      hue = fn role ->
        render_component(&log_stream/1, id: "log", lines: [%{time: "t", role: role, text: "x"}])
      end

      assert hue.("system") =~ "text-[var(--arb-info)]"
      assert hue.("status") =~ "text-[var(--arb-info)]"
      assert hue.("created") =~ "text-[var(--arb-info)]"
      assert hue.("agent") =~ "text-[var(--arb-live)]"
      assert hue.("worker") =~ "text-[var(--arb-live)]"
      assert hue.("tool") =~ "text-[var(--arb-proposal)]"
      assert hue.("test") =~ "text-[var(--arb-fail-text)]"
      assert hue.("error") =~ "text-[var(--arb-fail-text)]"
      assert hue.("gate") =~ "text-[var(--arb-attention)]"
      assert hue.("review") =~ "text-[var(--arb-attention)]"
    end

    test "an unmapped role stays neutral rather than crashing" do
      html =
        render_component(&log_stream/1,
          id: "log",
          lines: [%{time: "t", role: "weird", text: "x"}]
        )

      assert html =~ "weird"
      assert html =~ "text-[var(--text-secondary)]"
    end

    test "tool lines get a one-step surface tint instead of a row hue" do
      html =
        render_component(&log_stream/1, id: "log", lines: [%{time: "t", role: "tool", text: "x"}])

      assert html =~ "bg-[var(--arb-panel)]"
    end

    test "an atom tool role gets the same tint as the string one" do
      html =
        render_component(&log_stream/1, id: "log", lines: [%{time: "t", role: :tool, text: "x"}])

      assert html =~ "bg-[var(--arb-panel)]"
      assert html =~ "text-[var(--arb-proposal)]"
    end

    test "emphasis brightens the payload to body text" do
      html = render_component(&log_stream/1, id: "log", lines: @lines)

      assert html =~ "text-[var(--arb-text-body)]"
    end

    test "new lines fade in over --dur-instant" do
      html = render_component(&log_stream/1, id: "log", lines: @lines)

      assert html =~ "animate-[arb-fade-in_var(--dur-instant)_var(--arb-ease-out)]"
    end

    test "a live stream sticks to the bottom; a static one does not" do
      live =
        render_component(&log_stream/1, id: "log", lines: @lines, live: true, max_height: "28rem")

      static = render_component(&log_stream/1, id: "log", lines: @lines, max_height: "28rem")

      assert live =~ ~s(data-live="true")
      assert live =~ "phx-hook"
      assert live =~ "overflow-y-auto"
      assert static =~ ~s(data-live="false")
    end

    test "a capped pane scrolls even when the run is no longer live" do
      capped = render_component(&log_stream/1, id: "log", lines: @lines, max_height: "28rem")
      uncapped = render_component(&log_stream/1, id: "log", lines: @lines)

      assert capped =~ "max-height: 28rem"
      assert capped =~ "overflow-y-auto"
      # the pane itself never scrolls uncapped (the line text keeps its own
      # overflow-hidden, so assert on the scroll axis rather than the clip)
      refute uncapped =~ "overflow-y-auto"
    end

    test "bare drops the frame for a full-bleed pane" do
      bare = render_component(&log_stream/1, id: "log", lines: @lines, bare: true)
      framed = render_component(&log_stream/1, id: "log", lines: @lines)

      refute bare =~ "bg-[var(--surface-field)]"
      assert framed =~ "bg-[var(--surface-field)]"
    end

    test "renders an empty frame rather than crashing on no lines" do
      html = render_component(&log_stream/1, id: "log", lines: [])

      assert html =~ "bg-[var(--surface-field)]"
    end

    test "lines carry a stable dom id so LiveView patches append instead of rewriting" do
      html = render_component(&log_stream/1, id: "run-log", lines: @lines)

      assert html =~ ~s(id="run-log-line-0")
      assert html =~ ~s(id="run-log-line-3")
    end
  end
end
