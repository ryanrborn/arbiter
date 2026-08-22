defmodule ArbiterWeb.CoreComponents.Domain do
  @moduledoc """
  Domain primitives from the operator-console design handoff: TaskCard,
  RunRow, LogStream, StatCard, IndexHeader.

  These are the components that know what Arbiter *is* — an issue on the
  board, one run against it, that run's transcript. They compose the core
  (`ArbiterWeb.CoreComponents.Core`) and data
  (`ArbiterWeb.CoreComponents.Data`) primitives rather than restating them.

  Colors, spacing and motion come from the `--arb-*`/semantic tokens in
  `assets/css/app.css` via Tailwind arbitrary values, matching the handoff's
  reference implementation token-for-token.

  ## Name collision

  `index_header/1` collides with the older `ArbiterWeb.ListComponents.index_header/1`,
  which is imported unqualified across the app. `ArbiterWeb.html_helpers/0`
  therefore imports this module with `except: [index_header: 1]` — reach this
  one as `ArbiterWeb.CoreComponents.Domain.index_header/1` until the migration
  ticket retires the old one.
  """
  use Phoenix.Component

  import ArbiterWeb.CoreComponents.Data,
    only: [priority_tag: 1, type_tag: 1, difficulty_meter: 1, status_chip: 1]

  @doc """
  A dashboard counter: an uppercase mono eyebrow, one big tabular number,
  and an optional mono note beneath it.

  ## Examples

      <.stat_card label="Open issues" value={84} tone="live" />
      <.stat_card label="Active workers" value={4} tone="info" note="2 slots free" />
      <.stat_card label="Workspaces" value={3} />

  Most stats stay grey. A `tone` means "this number is asking for something",
  so use one only when the count implies an action.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, values: ~w(default live info attention fail), default: "default"
  attr :note, :string, default: nil, doc: ~s(mono sub-line, e.g. "2 slots free")
  attr :class, :any, default: nil
  attr :rest, :global

  def stat_card(assigns) do
    ~H"""
    <div
      class={[
        "flex flex-col gap-[6px] px-[16px] py-[14px] min-w-0",
        "bg-[var(--surface-panel)] border border-[var(--border-default)] rounded-[var(--radius-panel)]",
        @class
      ]}
      {@rest}
    >
      <span class="font-medium text-[10.5px] tracking-[var(--tracking-eyebrow)] uppercase text-[var(--text-label)] font-[family-name:var(--font-mono)]">
        {@label}
      </span>
      <span class={[
        "font-semibold text-[26px] leading-none tracking-[-0.02em] tabular-nums",
        stat_card_tone_class(@tone)
      ]}>
        {@value}
      </span>
      <span
        :if={@note}
        class="arb-stat-note text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
      >
        {@note}
      </span>
    </div>
    """
  end

  defp stat_card_tone_class("live"), do: "text-[var(--arb-live)]"
  defp stat_card_tone_class("info"), do: "text-[var(--arb-info)]"
  defp stat_card_tone_class("attention"), do: "text-[var(--arb-attention)]"
  defp stat_card_tone_class("fail"), do: "text-[var(--arb-fail-text)]"
  defp stat_card_tone_class(_), do: "text-[var(--text-title)]"

  @doc """
  The header every index page shares, so they read as one family: an icon,
  the title, the live total in parentheses, a one-sentence subtitle, and an
  actions slot on the right.

  ## Examples

      <ArbiterWeb.CoreComponents.Domain.index_header
        icon="hero-clipboard-document-list"
        title="Issues"
        count={84}
        subtitle="Every issue, filterable and paged. The dashboard shows only the current ones."
      >
        <:actions>
          <.live_badge live />
          <ArbiterWeb.CoreComponents.Core.button variant="primary" size="sm" key_hint="C">
            New issue
          </ArbiterWeb.CoreComponents.Core.button>
        </:actions>
      </ArbiterWeb.CoreComponents.Domain.index_header>

  The subtitle says what this page lists and how it differs from the
  dashboard's slice — not what the page is called a second time.

  Call this fully-qualified: the unqualified `<.index_header>` still resolves
  to `ArbiterWeb.ListComponents.index_header/1` (see the module doc).
  """
  attr :icon, :string,
    default: nil,
    doc:
      ~s(full Heroicon class, e.g. "hero-clipboard-document-list" — same contract as Core.icon/1)

  attr :title, :string, required: true
  attr :count, :integer, default: nil, doc: "live total, rendered in parentheses"
  attr :subtitle, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  slot :actions, doc: ~s(right side — normally a live badge plus one primary button)

  def index_header(assigns) do
    ~H"""
    <div class={["flex items-start justify-between gap-4", @class]} {@rest}>
      <div class="min-w-0">
        <h1 class="flex items-center gap-[9px] m-0 font-semibold text-[24px] leading-[1.2] tracking-[var(--tracking-section)] text-[var(--text-title)]">
          <ArbiterWeb.CoreComponents.Core.icon
            :if={@icon}
            name={@icon}
            size={20}
            color="var(--text-secondary)"
          />
          {@title}
          <span
            :if={@count != nil}
            class="text-[20px] font-normal text-[var(--text-label)] tabular-nums font-[family-name:var(--font-mono)]"
          >
            ({@count})
          </span>
        </h1>
        <p
          :if={@subtitle}
          class="mt-[6px] mb-0 text-[12.5px] leading-[1.55] text-[var(--text-secondary)] max-w-[var(--measure-prose)]"
        >
          {@subtitle}
        </p>
      </div>
      <div :if={@actions != []} class="flex items-center gap-2 flex-none">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  The unit of the board and of every dashboard issue list.

  ## Examples

      <.task_card
        id="bd-3o8mq1"
        title="Collapse duplicate status helpers"
        accent="live"
        priority={2}
        type="chore"
        activity="edit · status_helpers.ex"
        footer="w-14 · sonnet"
      >
        <:status><.status_chip status={:running} /></:status>
      </.task_card>

      <.task_card id="bd-2wilou" title="Default close_upstream to true" muted footer="merged 09:41 · 2 rounds" />

  One line of live tool activity beats any progress bar: `activity` carries
  the single most recent machine event, not a history. Closed work goes
  `muted` — no fill, no accent rule, text one step back — so finished cards
  recede instead of competing with the live ones.

  `accent` is the state that owns the card *right now*, and it is the only
  color on it. `done` is deliberately not a hue.
  """
  attr :id, :string, required: true, doc: ~s(issue id, e.g. "bd-3o8mq1" — always mono)
  attr :title, :string, required: true

  attr :accent, :string,
    values: [nil | ~w(live attention fail info proposal done)],
    default: nil,
    doc: "left accent rule: the state that owns this card right now"

  attr :priority, :integer, default: nil
  attr :type, :any, default: nil

  attr :difficulty, :any,
    default: :unset,
    doc: "omit for no meter at all; pass nil for an explicitly-empty meter"

  attr :activity, :string,
    default: nil,
    doc: ~s(one mono line of what the agent is doing right now, e.g. "edit · status_helpers.ex")

  attr :footer, :string, default: nil, doc: ~s(right-aligned mono footer, e.g. "w-14 · sonnet")
  attr :muted, :boolean, default: false, doc: "closed/merged treatment"
  attr :class, :any, default: nil
  attr :rest, :global

  slot :status, doc: "top-right slot — normally a status chip or an elapsed/waiting time"
  slot :actions, doc: "row of inline action chips"

  def task_card(assigns) do
    assigns = assign(assigns, :hue, task_card_hue(assigns.accent))

    ~H"""
    <article
      class={[
        "flex flex-col gap-2 px-[11px] py-[10px] rounded-[var(--radius-field)] border border-solid",
        "transition-[background] duration-[var(--dur-hover)] ease-[var(--arb-ease-out)]",
        task_card_surface_class(@muted, @hue),
        task_card_border_class(@accent, @muted),
        task_card_rule_class(@accent, @muted),
        @class
      ]}
      {@rest}
    >
      <div class="flex items-center justify-between gap-2">
        <span class={[
          "font-medium text-[10.5px] font-[family-name:var(--font-mono)]",
          @muted && "text-[var(--text-label)]",
          !@muted && "text-[var(--text-secondary)]"
        ]}>
          {@id}
        </span>
        {render_slot(@status)}
      </div>

      <span class={[
        "text-[12.5px] leading-[1.4]",
        @muted && "font-normal text-[var(--text-secondary)]",
        !@muted && "font-medium text-[var(--text-title)]"
      ]}>
        {@title}
      </span>

      <span
        :if={@activity}
        class={[
          "text-[10.5px] leading-[1.5] font-[family-name:var(--font-mono)]",
          task_card_activity_class(@accent)
        ]}
      >
        {@activity}
      </span>

      <div
        :if={task_card_meta?(assigns)}
        class="arb-card-meta flex items-center gap-1.5 flex-wrap"
      >
        <.priority_tag :if={@priority != nil} priority={@priority} />
        <.type_tag :if={@type} type={@type} />
        <.difficulty_meter :if={@difficulty != :unset} difficulty={@difficulty} />
        <span
          :if={@footer}
          class="ml-auto text-[10px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
        >
          {@footer}
        </span>
      </div>

      <div :if={@actions != []} class="flex gap-1.5">{render_slot(@actions)}</div>
    </article>
    """
  end

  defp task_card_meta?(assigns) do
    assigns.priority != nil or assigns.type != nil or assigns.difficulty != :unset or
      assigns.footer != nil
  end

  defp task_card_hue("live"), do: "--arb-live"
  defp task_card_hue("attention"), do: "--arb-attention"
  defp task_card_hue("fail"), do: "--arb-fail"
  defp task_card_hue("info"), do: "--arb-info"
  defp task_card_hue("proposal"), do: "--arb-proposal"
  defp task_card_hue(_), do: nil

  defp task_card_surface_class(true, _hue), do: "bg-transparent"

  defp task_card_surface_class(false, nil),
    do: "bg-[var(--arb-panel-alt)] hover:bg-[var(--arb-raised-hover)]"

  defp task_card_surface_class(false, _hue),
    do: "bg-[var(--surface-card)] hover:bg-[var(--arb-raised-hover)]"

  defp task_card_border_class(_accent, true), do: "border-[var(--arb-line-soft)]"

  defp task_card_border_class("attention", _muted),
    do: "border-[color-mix(in_oklch,var(--arb-attention)_35%,transparent)]"

  defp task_card_border_class("proposal", _muted),
    do: "border-[color-mix(in_oklch,var(--arb-proposal)_35%,transparent)]"

  defp task_card_border_class(_accent, _muted), do: "border-[var(--arb-line-strong)]"

  @accent_rule "border-l-[length:var(--border-accent-width)]"

  defp task_card_rule_class(_accent, true), do: nil
  defp task_card_rule_class("live", _), do: [@accent_rule, "border-l-[color:var(--arb-live)]"]

  defp task_card_rule_class("attention", _),
    do: [@accent_rule, "border-l-[color:var(--arb-attention)]"]

  defp task_card_rule_class("fail", _), do: [@accent_rule, "border-l-[color:var(--arb-fail)]"]
  defp task_card_rule_class("info", _), do: [@accent_rule, "border-l-[color:var(--arb-info)]"]

  defp task_card_rule_class("proposal", _),
    do: [@accent_rule, "border-l-[color:var(--arb-proposal)]"]

  defp task_card_rule_class(_accent, _muted), do: nil

  defp task_card_activity_class("fail"), do: "text-[var(--arb-fail-text)]"
  defp task_card_activity_class(_), do: "text-[var(--text-secondary)]"

  @doc """
  One run against an issue. An issue accumulates many — a `main` dispatch,
  `review` passes, `impl` and `fix_pass` follow-ups, a `conflict` resolver —
  so this is a roster row, not a card.

  ## Examples

      <.run_row
        role="impl"
        worker="w-11"
        status="running"
        round={3}
        outcome="edit · loop_queue.ex"
        duration="12m"
        cost="$0.42"
        selected
        expanded
        phx-click="select_run"
      />
      <.run_row role="review" worker="w-19" status="awaiting review" round={2} outcome="1 finding open" duration="41m" />
      <.run_row role="fix_pass" worker="w-16" status="failed" outcome="exit 1 · mix test" duration="6m" />

  `role` is one of Arbiter's real `worker_type` values from
  `Arbiter.Workers.Run` — `main`, `review`, `impl`, `fix_pass`, `conflict`.
  Don't invent others; PRPatrol and Watchdog are pollers, not run types, and
  show up here as the `main`/`impl` runs they dispatch.

  Role is a kind, not a state, so it renders as an outline type tag: the
  status chip and the 2px left rule carry the row's only color.

  `model` and `tokens` are accepted for completeness but deliberately **not
  rendered** — at roster width they crowd out the outcome, which is the
  column an operator actually scans. Put them in the expanded transcript
  header instead.
  """
  attr :role, :string,
    required: true,
    doc: ~s(worker_type: main, review, impl, fix_pass, conflict)

  attr :worker, :string, required: true, doc: ~s(worker id, e.g. "w-14")
  attr :status, :any, required: true, doc: "carries the row's only color"
  attr :round, :integer, default: nil, doc: "review round, when part of a gated loop"

  attr :outcome, :string,
    default: nil,
    doc: ~s(what the run produced: "+214 −38 · 4 files", "3 findings", "exit 1 · mix test")

  attr :model, :string, default: nil, doc: "accepted but NOT rendered — see the expanded header"
  attr :tokens, :string, default: nil, doc: "accepted but NOT rendered — see the expanded header"
  attr :duration, :string, default: nil
  attr :cost, :string, default: nil
  attr :selected, :boolean, default: false
  attr :expanded, :boolean, default: false, doc: "rotates the chevron upright"
  attr :class, :any, default: nil
  attr :rest, :global

  def run_row(assigns) do
    assigns =
      assign(assigns,
        live: run_row_live?(assigns.status),
        meta: [assigns.duration, assigns.cost] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
      )

    ~H"""
    <div
      class={
        [
          # Only the chevron, the worker cell and the role tag are rigid; the
          # outcome takes the slack. The status track is a minmax, not a fixed
          # 92px:
          # "awaiting review" is 115px with its dot and overruns a fixed track
          # straight into the metrics cell.
          "grid grid-cols-[84px_48px_minmax(120px,1fr)_minmax(92px,max-content)_minmax(0,max-content)_14px]",
          "gap-[10px] items-center min-h-[var(--row-control)] px-3",
          "rounded-[var(--radius-field)] border border-solid",
          "border-l-[length:var(--border-accent-width)]",
          run_row_rule_class(@status),
          @selected && "bg-[var(--surface-card)] border-[var(--border-strong)]",
          !@selected && "bg-[var(--arb-panel-alt)] border-[var(--border-default)]",
          @class
        ]
      }
      {@rest}
    >
      <.type_tag type={run_row_role_label(@role)} class="justify-self-start" />

      <span class="font-medium text-[11px] text-[var(--text-secondary)] whitespace-nowrap font-[family-name:var(--font-mono)]">
        {@worker}
      </span>

      <span class="flex items-baseline gap-2 min-w-0">
        <span
          :if={@round != nil}
          class="text-[10.5px] text-[var(--text-label)] flex-none font-[family-name:var(--font-mono)]"
        >
          rd {@round}
        </span>
        <span class={[
          "text-[11.5px] overflow-hidden text-ellipsis whitespace-nowrap font-[family-name:var(--font-mono)]",
          run_row_outcome_class(@status)
        ]}>
          {@outcome}
        </span>
      </span>

      <.status_chip
        status={@status}
        class={[
          "px-1.5 py-px text-[10px] justify-self-start",
          @live && "animate-[arb-pulse_var(--pulse-period)_var(--arb-ease-in-out)_infinite]"
        ]}
      />

      <span class="text-[10.5px] text-[var(--text-label)] text-right whitespace-nowrap tabular-nums overflow-hidden text-ellipsis font-[family-name:var(--font-mono)]">
        {@meta}
      </span>

      <ArbiterWeb.CoreComponents.Core.icon
        name="hero-chevron-down-micro"
        size={11}
        color={if @selected, do: "var(--text-title)", else: "var(--text-label)"}
        class={[
          "transition-transform duration-[var(--dur-hover)] ease-[var(--arb-ease-out)]",
          !@expanded && "-rotate-90"
        ]}
      />
    </div>
    """
  end

  @role_labels %{
    "main" => "main",
    "review" => "review",
    "impl" => "impl",
    "fix_pass" => "fix pass",
    "conflict" => "conflict"
  }

  defp run_row_role_label(role), do: Map.get(@role_labels, to_string(role), to_string(role))

  # Arbiter writes statuses both ways — the handoff's spaced labels
  # ("awaiting review") and the schema's snake_case atoms
  # (:awaiting_review_gate). Normalize so both land on the same rule.
  defp run_row_state(status) do
    status |> to_string() |> String.replace("_", " ")
  end

  defp run_row_live?(status), do: run_row_state(status) == "running"

  defp run_row_rule_class(status) do
    case run_row_state(status) do
      "running" -> "border-l-[color:var(--arb-live)]"
      "awaiting review" <> _ -> "border-l-[color:var(--arb-attention)]"
      "failed" -> "border-l-[color:var(--arb-fail)]"
      _ -> "border-l-[color:transparent]"
    end
  end

  defp run_row_outcome_class(status) do
    case run_row_state(status) do
      "failed" -> "text-[var(--arb-fail-text)]"
      _ -> "text-[var(--text-secondary)]"
    end
  end

  @doc """
  Agent transcript and activity history — three fixed columns so the eye can
  drop down the role gutter and find the failure.

  ## Examples

      <.log_stream
        id="run-transcript"
        live={@run.status == :running}
        lines={[
          %{time: "14:02:11", role: "system", text: "worktree ready · feat/status-helpers @ 4f2a9c1"},
          %{time: "14:02:14", role: "agent", text: "Reading status_helpers.ex", emphasis: true},
          %{time: "14:02:26", role: "tool", text: "edit · status_helpers.ex +41 −63"},
          %{time: "14:03:02", role: "test", text: "2 failures — status_helpers_test.exs:41"}
        ]}
      />

  Roles carry color; payload text never does. Tool calls get a one-step
  surface tint instead of a hue. New lines fade in over `--dur-instant`, and
  while `live` the pane sticks to the bottom — unless the operator has
  scrolled up to read, in which case it stays where they left it.
  """
  attr :id, :string, required: true, doc: "needed by the stick-to-bottom hook"

  attr :lines, :list,
    default: [],
    doc: ~s(maps of `%{time:, role:, text:, emphasis: false}`)

  attr :live, :boolean, default: false, doc: "stick to the bottom as new lines arrive"
  attr :time_width, :integer, default: 66
  attr :role_width, :integer, default: 76
  attr :max_height, :string, default: nil, doc: ~s(CSS length, e.g. "28rem"; scrolls past it)
  attr :bare, :boolean, default: false, doc: "full-bleed: no border, no radius, no fill"
  attr :class, :any, default: nil
  attr :rest, :global

  def log_stream(assigns) do
    assigns =
      assign(assigns,
        line_style:
          "grid-template-columns: #{assigns.time_width}px #{assigns.role_width}px minmax(0, 1fr)",
        pane_style: assigns.max_height && "max-height: #{assigns.max_height}"
      )

    ~H"""
    <div
      id={@id}
      phx-hook=".LogStreamStick"
      data-live={to_string(@live)}
      style={@pane_style}
      class={[
        "text-[11.5px] leading-[var(--leading-log)] font-normal font-[family-name:var(--font-mono)]",
        !@bare &&
          "bg-[var(--surface-field)] border border-[var(--border-default)] rounded-[var(--radius-field)]",
        @max_height && "overflow-x-hidden overflow-y-auto",
        is_nil(@max_height) && "overflow-hidden",
        @class
      ]}
      {@rest}
    >
      <div
        :for={{line, i} <- Enum.with_index(@lines)}
        id={"#{@id}-line-#{i}"}
        style={@line_style}
        class={[
          "grid gap-3 px-3 py-1 min-h-[var(--row-log)] items-center",
          "border-b border-[var(--arb-line-soft)] last:border-b-0",
          "animate-[arb-fade-in_var(--dur-instant)_var(--arb-ease-out)]",
          to_string(line.role) == "tool" && "bg-[var(--arb-panel)]"
        ]}
      >
        <span class="text-[var(--arb-text-ghost)] tabular-nums">{line.time}</span>
        <span class={log_stream_role_class(line.role)}>{line.role}</span>
        <span
          title={line.text}
          class={[
            "overflow-hidden text-ellipsis whitespace-nowrap",
            if(Map.get(line, :emphasis, false),
              do: "text-[var(--arb-text-body)]",
              else: "text-[var(--text-secondary)]"
            )
          ]}
        >
          {line.text}
        </span>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LogStreamStick">
      export default {
        mounted() {
          this.stick = true
          this.el.addEventListener("scroll", () => {
            const gap = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
            this.stick = gap < 24
          })
          this.pin()
        },
        updated() { this.pin() },
        pin() {
          if (this.el.dataset.live !== "true" || !this.stick) return
          this.el.scrollTop = this.el.scrollHeight
        }
      }
    </script>
    """
  end

  defp log_stream_role_class(role) do
    case to_string(role) do
      r when r in ~w(system status created) -> "text-[var(--arb-info)]"
      r when r in ~w(agent worker) -> "text-[var(--arb-live)]"
      "tool" -> "text-[var(--arb-proposal)]"
      r when r in ~w(test error) -> "text-[var(--arb-fail-text)]"
      r when r in ~w(gate review) -> "text-[var(--arb-attention)]"
      _ -> "text-[var(--text-secondary)]"
    end
  end
end
