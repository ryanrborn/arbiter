defmodule ArbiterWeb.CoreComponents.Feedback do
  @moduledoc """
  Feedback primitives from the operator-console design handoff: LiveBadge,
  QuotaBar, WorkerFlow, Toast, EmptyState.

  Foundation and conventions match `ArbiterWeb.CoreComponents.Core`. `quota_bar/1`
  and `worker_flow/1` are thin markup wrappers over `ArbiterWeb.QuotaHelpers`
  and `ArbiterWeb.StatusHelpers` — the math and vocabulary stay in those
  modules unchanged.
  """
  use Phoenix.Component

  import ArbiterWeb.CoreComponents.Core, only: [icon: 1]

  alias Phoenix.LiveView.JS

  import ArbiterWeb.QuotaHelpers,
    only: [
      quota_pct: 1,
      quota_elapsed_pct_5h: 2,
      quota_elapsed_pct_7d: 2,
      quota_color_5h: 4,
      quota_color_7d: 4,
      quota_pace_label_5h: 5,
      quota_pace_label_7d: 5,
      quota_reset_label: 1,
      quota_binding_class: 2
    ]

  import ArbiterWeb.StatusHelpers,
    only: [worker_flow: 0, flow_state: 2, flow_step_label: 1]

  @doc """
  The "is this updating in real time?" indicator. Every live page carries one,
  in the same place.

  ## Examples

      <.live_badge id="dashboard-live" live={@live} />
      <.live_badge live={true} />
      <.live_badge live={false} />

  `live` is required and must be assign-driven — pass the `:live` assign
  every `live_session` mounts via `ArbiterWeb.LiveHooks.on_mount(:live, ...)`
  (`connected?(socket)` at mount/reconnect). It used to default to `nil` and
  render both states wired purely to `phx-connected`/`phx-disconnected`
  (mirroring `flash_group`'s toast pattern), auto-toggling with no server
  assign needed — that was the AppShell navbar badge's mechanism, and it was
  the root cause of bd-akygjy: the badge was permanently stuck on "stale —
  refresh". See the "Root cause" note below for what was and wasn't
  established about *why*, and why the fix is "stop depending on this
  direction of the DOM mechanism" rather than "patch it".

  Pass a literal `true`/`false` only for specimens, docs, or a badge that is
  known to never reconnect (e.g. a style-guide page). The ping animation is
  the only always-on animation in the system: it means a live socket,
  nothing else.

  ## Root cause (bd-akygjy)

  The AppShell instance (`layouts.ex`), and formerly `workspace_detail_live.ex`
  and `usage_live.ex`, used the bare `<.live_badge id="..." />` form (no
  `live` override) instead of the assign-driven form every other page used.
  That form started both spans in a `hidden`/visible pair and relied
  entirely on `phx-connected`/`phx-disconnected` special bindings to flip
  them — including on the *initial join*, which the assign-driven `:live`
  now owns instead. The bare form is not being replaced because
  `phx-connected`/`phx-disconnected` are unreliable in general — the
  disconnect toasts (`flash_group/1`, below) use the exact same pair
  reliably. It's replaced because relying on the join-direction firing
  correctly was never confirmed to work for this badge, and because
  LiveView's JS commands (`JS.show`/`JS.hide`/`JS.set_attribute`) are
  *sticky*: they get re-applied on every subsequent DOM patch
  (`DOM.applyStickyOperations`), so whichever direction's binding is
  omitted, that direction can never be undone by a fresh server render —
  only by the matching `phx-connected`/`phx-disconnected` firing again.
  That means *both* directions need their own binding to stay correct
  indefinitely, not just the one that runs on join.

  Reading the LiveView 1.1.33 client source
  (`deps/phoenix_live_view/assets/js/phoenix_live_view/view.js`) rules out
  several plausible explanations, but does not land on a single confirmed
  one — this needed live browser devtools (per the task's own difficulty
  note), which this fix round could not do:

    * `phx-connected`/`phx-disconnected` are not special-cased anywhere
      server-side (`grep -rn "phx-connected" deps/phoenix_live_view/lib`
      returns nothing) — they are plain attributes read entirely by the JS
      client, so nothing strips or rewrites them between the dead render and
      the connected patch.
    * The client fires the `connected` binding via `View.hideLoader()`,
      which runs from `applyJoinPatch` on *both* the initial join and every
      reconnect (`view.js:618-620`), and `execAll` scopes its
      `querySelectorAll("[phx-connected]")` to the view's own root element
      (`this.el`) — the AppShell badge is rendered via `<Layouts.app>` from
      inside each LiveView's own template (the app layout, not
      `put_root_layout`'s `Layouts.root`, which is the one rendered outside
      `this.el`), so on paper it is in scope.
    * No CSS in `app.css` overrides the `hidden` attribute (no `[hidden]`
      rule at all — Tailwind's preflight default has no `!important`), and
      the JS commands explicitly call `remove_attribute("hidden", ...)`
      alongside `JS.show`, so a specificity fight was ruled out.
    * The binding prefix is the framework default `"phx-"`
      (`live_socket.js:398`), matching the HEEx-emitted attribute names
      exactly — no prefix mismatch.

  None of that explains the reported "never once shown Live across an
  entire session" symptom, which is why this fix does not try to repair the
  DOM-only connect-direction mechanism and ship it as trustworthy again.
  Instead: `:live` is now assign-driven everywhere (`ArbiterWeb.LiveHooks`,
  `connected?(socket)`), the bare/default branch that depended on
  `phx-connected` firing on join is removed, and `live` is `required: true`
  so a future `<.live_badge id="x" />` call site cannot silently reproduce
  this bug. The DOM mechanism is still used in the `live={true}` branch, but
  now with *both* directions bound on the `-live` span:
  `phx-connected={show_live(@id)}` and `phx-disconnected={hide_live(@id)}`.
  The connected binding is not decorative — it is the only thing that undoes
  `hide_live/1`'s sticky ops after a real disconnect-then-rejoin; without it
  the badge would get stuck reading "stale — refresh" forever after the
  first outage, which is the same bug this fix was filed for, just moved
  from the join direction to the reconnect direction.

  A round-2 review caught that the `-stale` span used to *also* carry
  `phx-disconnected={show_live(@id)}` — the mirror-image command. LiveView's
  JS client runs every element matching `[phx-disconnected]` in document
  order with no visibility filter (`view.js` `execAll` /
  `dom.js`'s plain `querySelectorAll`), so both handlers fired on a genuine
  disconnect and the second one undid the first, leaving the badge reading
  "live" through an outage. That stale-span attribute has been deleted;
  `hide_live(@id)` on the `-live` span already toggles both spans, so nothing
  else needs to carry the binding.
  """
  attr :id, :string, default: "live-badge"
  attr :live, :boolean, required: true, doc: "assign-driven state; see moduledoc root cause note"
  attr :class, :any, default: nil

  def live_badge(%{live: true} = assigns) do
    ~H"""
    <span id={@id} class={@class}>
      <span id={"#{@id}-live"} phx-connected={show_live(@id)} phx-disconnected={hide_live(@id)}>
        {live_badge_live(%{})}
      </span>
      <span id={"#{@id}-stale"} hidden>
        {live_badge_stale(%{})}
      </span>
    </span>
    """
  end

  def live_badge(%{live: false} = assigns) do
    ~H"""
    <span id={@id} class={@class}>{live_badge_stale(%{})}</span>
    """
  end

  defp hide_live(id),
    do:
      JS.hide(to: "##{id}-live")
      |> JS.set_attribute({"hidden", ""}, to: "##{id}-live")
      |> JS.show(to: "##{id}-stale", display: "inline-flex")
      |> JS.remove_attribute("hidden", to: "##{id}-stale")

  defp show_live(id),
    do:
      JS.show(to: "##{id}-live", display: "inline-flex")
      |> JS.remove_attribute("hidden", to: "##{id}-live")
      |> JS.hide(to: "##{id}-stale")
      |> JS.set_attribute({"hidden", ""}, to: "##{id}-stale")

  defp live_badge_live(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-[7px] text-[11px] font-medium text-[var(--arb-live)] font-[family-name:var(--font-mono)]">
      <span class="relative inline-flex w-[6px] h-[6px]">
        <span class="absolute inset-0 rounded-full bg-[var(--arb-live)] motion-safe:animate-[arb-ping_var(--ping-period)_var(--arb-ease-out)_infinite]" />
        <span class="relative w-[6px] h-[6px] rounded-full bg-[var(--arb-live)]" />
      </span>live
    </span>
    """
  end

  defp live_badge_stale(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-[6px] text-[11px] font-medium text-[var(--arb-attention)] font-[family-name:var(--font-mono)]">
      <.icon name="hero-exclamation-triangle" size={12} />stale — refresh
    </span>
    """
  end

  @doc """
  The rate-limit widget from the product chrome: a fill, an elapsed hairline,
  a percentage. Pass the raw quota fields — `quota_pct/1`,
  `quota_elapsed_pct_5h/2` (or `_7d`), `quota_color_5h/4` (or `_7d`),
  `quota_pace_label_5h/5` (or `_7d`), `quota_reset_label/1`, and
  `quota_binding_class/2` do the math, unchanged from the existing topbar
  widget; only the markup here is new.

  ## Examples

      <.quota_bar provider="anthropic" window="5h" utilization={0.68} reset_at={reset_at} />
      <.quota_bar window="7d" utilization={0.21} reset_at={reset_at} overage_status="ok" representative_claim="five_hour" />

  The hairline is elapsed time — the fill crossing it is what turns the bar
  amber. The bar itself is the only pill-radius element besides the live dot.
  """
  attr :provider, :string, default: nil, doc: ~s(label above the bars, e.g. "anthropic")
  attr :window, :string, values: ~w(5h 7d), default: "5h"
  attr :utilization, :any, default: nil
  attr :reset_at, :any, default: nil
  attr :overage_status, :any, default: nil
  attr :on_exhaustion, :any, default: nil
  attr :representative_claim, :any, default: nil
  attr :width, :integer, default: 96
  attr :class, :any, default: nil

  attr :show_label, :boolean,
    default: true,
    doc:
      "set false to suppress the per-bar label — e.g. when a wrapper renders a single shared label above stacked 5h/7d bars"

  def quota_bar(assigns) do
    pct = quota_pct(assigns.utilization)
    elapsed_pct = quota_elapsed_pct(assigns)
    color = quota_color(assigns)
    note = quota_note(assigns)
    over = elapsed_pct != nil and pct > elapsed_pct
    binding_window = if assigns.window == "5h", do: "five_hour", else: "seven_day"

    assigns =
      assign(assigns,
        pct: pct,
        elapsed_pct: elapsed_pct,
        color: color,
        note: note,
        over: over,
        binding_class: quota_binding_class(assigns.representative_claim, binding_window)
      )

    ~H"""
    <div class={["flex flex-col gap-[3px]", @binding_class, @class]}>
      <span
        :if={@provider && @show_label}
        class="text-[9.5px] uppercase tracking-[0.08em] leading-none text-[var(--text-label)] font-[family-name:var(--font-mono)]"
      >
        {@provider}
      </span>
      <div class="flex items-center gap-[7px]">
        <span class="flex-none w-[14px] text-[9.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)]">
          {@window}
        </span>
        <span
          class="relative flex-none h-[5px] rounded-[var(--radius-pill)] bg-[var(--arb-done-wash)] overflow-hidden"
          style={"width: #{@width}px;"}
        >
          <span
            class="absolute inset-y-0 left-0 rounded-[var(--radius-pill)] transition-[width] duration-[var(--dur-bar)] ease-[var(--arb-ease-out)]"
            style={"width: #{@pct}%; background-color: #{@color};"}
          />
          <span
            :if={@elapsed_pct}
            class="absolute top-0 bottom-0 w-px bg-[var(--text-title)] opacity-55"
            style={"left: #{@elapsed_pct}%;"}
          />
        </span>
        <span class="flex-none min-w-[26px] text-right text-[9.5px] tabular-nums text-[var(--text-secondary)] font-[family-name:var(--font-mono)]">
          {@pct}%
        </span>
        <span
          :if={@note}
          class={[
            "text-[9.5px] font-[family-name:var(--font-mono)]",
            @over && "text-[var(--arb-attention)]",
            !@over && "text-[var(--text-label)]"
          ]}
        >
          {@note}
        </span>
      </div>
    </div>
    """
  end

  defp quota_elapsed_pct(%{window: "5h", provider: provider, reset_at: reset_at}),
    do: quota_elapsed_pct_5h(provider, reset_at)

  defp quota_elapsed_pct(%{window: "7d", provider: provider, reset_at: reset_at}),
    do: quota_elapsed_pct_7d(provider, reset_at)

  defp quota_color(%{window: "5h"} = a),
    do: quota_color_5h(a.provider, a.utilization, a.reset_at, a.overage_status)

  defp quota_color(%{window: "7d"} = a),
    do: quota_color_7d(a.provider, a.utilization, a.reset_at, a.overage_status)

  defp quota_note(%{window: "5h"} = a) do
    quota_pace_label_5h(a.provider, a.utilization, a.reset_at, a.overage_status, a.on_exhaustion) ||
      quota_reset_label(a.reset_at)
  end

  defp quota_note(%{window: "7d"} = a) do
    quota_pace_label_7d(a.provider, a.utilization, a.reset_at, a.overage_status, a.on_exhaustion) ||
      quota_reset_label(a.reset_at)
  end

  @doc """
  The worker lifecycle stepper — idle, running, awaiting review, completed —
  from `StatusHelpers.worker_flow/0`.

  ## Examples

      <.worker_flow status={:running} />
      <.worker_flow status={:awaiting} />
      <.worker_flow status={:running} failed />
      <.worker_flow status={:awaiting} compact />

  Done steps go grey with a tick, the current step takes the hue of its
  state, and `failed` reds the current step rather than adding a fifth
  column — pass the step the worker reached before failing (never `:failed`
  itself, which isn't a flow step).

  Four labels need roughly 340px. In anything narrower — the task-detail and
  worker-session rails — use `compact`: the track keeps its four nodes, and
  only the current step is named, with an "n of 4" counter. Never scale the
  full variant down to fit.
  """
  attr :status, :atom, required: true, doc: "must be one of StatusHelpers.worker_flow/0"
  attr :failed, :boolean, default: false, doc: "paint the current step red"
  attr :compact, :boolean, default: false
  attr :class, :any, default: nil

  def worker_flow(assigns) do
    steps = worker_flow()
    idx = Enum.find_index(steps, &(&1 == assigns.status))

    assigns = assign(assigns, steps: steps, idx: idx, hue: current_hue(assigns))

    ~H"""
    <div :if={@compact} class={["flex flex-col gap-[7px]", @class]}>
      <div class="flex items-center">
        <div :for={{step, i} <- Enum.with_index(@steps)} class="contents">
          <span
            class={[
              "flex-none w-[9px] h-[9px] rounded-full border-[length:var(--border-width)]",
              worker_flow_dot_class(flow_state(step, @status), @failed, i == @idx)
            ]}
            style={worker_flow_dot_style(flow_state(step, @status), @failed, i, @idx)}
          />
          <span
            :if={i < length(@steps) - 1}
            class={[
              "flex-1 h-px",
              i < (@idx || -1) && "bg-[var(--arb-done)]",
              i >= (@idx || -1) && "bg-[var(--border-strong)]"
            ]}
          />
        </div>
      </div>
      <div class="flex items-baseline justify-between gap-2">
        <span
          class="text-[11.5px] font-medium font-[family-name:var(--font-mono)]"
          style={"color: #{@hue};"}
        >
          {if @failed, do: "failed", else: flow_step_label(@status)}
        </span>
        <span class="text-[10px] tabular-nums text-[var(--text-label)] font-[family-name:var(--font-mono)]">
          {(@idx || 0) + 1} of {length(@steps)}
        </span>
      </div>
    </div>
    <div :if={!@compact} class={["flex items-center", @class]}>
      <div :for={{step, i} <- Enum.with_index(@steps)} class="contents">
        <span
          class={[
            "flex-none inline-flex items-center gap-[7px] whitespace-nowrap text-[11px] font-medium font-[family-name:var(--font-mono)]",
            worker_flow_label_class(flow_state(step, @status))
          ]}
          style={worker_flow_label_style(flow_state(step, @status), @failed, @hue)}
        >
          <span
            class="flex-none w-[14px] h-[14px] rounded-full flex items-center justify-center text-[8px] font-semibold text-[var(--arb-canvas)] font-[family-name:var(--font-mono)]"
            style={worker_flow_node_style(flow_state(step, @status), @failed, @hue)}
          >
            <span
              :if={flow_state(step, @status) == :current}
              class={[
                "w-[5px] h-[5px] rounded-full",
                !@failed &&
                  "motion-safe:animate-[arb-pulse_var(--pulse-period)_var(--arb-ease-in-out)_infinite]"
              ]}
              style={"background-color: #{@hue};"}
            />
            {if flow_state(step, @status) == :done, do: "✓"}
          </span>{flow_step_label(
            step
          )}
        </span>
        <span
          :if={i < length(@steps) - 1}
          class={[
            "flex-none w-[24px] h-px",
            i < (@idx || -1) && "bg-[var(--arb-done)]",
            i >= (@idx || -1) && "bg-[var(--border-strong)]"
          ]}
        />
      </div>
    </div>
    """
  end

  defp current_hue(%{failed: true}), do: "var(--arb-fail)"
  defp current_hue(%{status: :awaiting}), do: "var(--arb-attention)"
  defp current_hue(_), do: "var(--arb-live)"

  defp worker_flow_dot_class(:done, _failed, _current?),
    do: "bg-[var(--arb-done)] border-[var(--arb-done)]"

  defp worker_flow_dot_class(:todo, _failed, _current?),
    do: "bg-transparent border-[var(--border-strong)]"

  defp worker_flow_dot_class(:current, _failed, _current?), do: ""

  defp worker_flow_dot_style(:current, failed, i, idx) when i == idx do
    hue = if failed, do: "var(--arb-fail)", else: "var(--arb-live)"
    "background-color: #{hue}; border-color: #{hue};"
  end

  defp worker_flow_dot_style(_, _, _, _), do: nil

  defp worker_flow_label_class(:done), do: "text-[var(--text-secondary)]"
  defp worker_flow_label_class(:todo), do: "text-[var(--text-label)]"
  defp worker_flow_label_class(:current), do: ""

  defp worker_flow_label_style(:current, _failed, hue), do: "color: #{hue};"
  defp worker_flow_label_style(_, _, _), do: nil

  defp worker_flow_node_style(:done, _failed, _hue),
    do: "border: var(--border-width) solid var(--arb-done); background-color: var(--arb-done);"

  defp worker_flow_node_style(:todo, _failed, _hue),
    do: "border: var(--border-width) solid var(--border-strong); background-color: transparent;"

  defp worker_flow_node_style(:current, _failed, hue),
    do:
      "border: var(--border-width) solid #{hue}; background-color: color-mix(in oklch, #{hue} 20%, transparent);"

  @doc """
  A transient confirmation or failure notice. The one component allowed a
  drop shadow, because it floats over the page.

  ## Examples

      <.toast>Worker dispatched to <span class="font-mono">bd-3o8mq1</span></.toast>
      <.toast tone="error" action="retry">Upstream close failed — ticket VR-17585 still open</.toast>
      <.toast tone="attention" dismiss_key="">Quota pacing to exhaust before reset</.toast>
      <.toast tone="live">Socket reconnected</.toast>

  Left accent border carries the tone; the body text never does. `:info` and
  `:error` are `flash_group`'s two kinds (cyan / red); `attention` (amber)
  and `live` (lime) are new tones for call sites `flash_group` never had.
  """
  attr :id, :string, default: nil
  attr :tone, :string, values: ~w(info error attention live), default: "info"
  attr :action, :string, default: nil, doc: "one inline action word, e.g. retry or undo"
  attr :action_click, :any, default: nil, doc: "phx-click target bound to the action word only"
  attr :dismiss_key, :string, default: "esc", doc: "pass empty string to hide it"
  attr :rest, :global
  slot :inner_block, required: true

  def toast(assigns) do
    assigns = assign(assigns, :hue, toast_hue(assigns.tone))

    ~H"""
    <div
      id={@id}
      role="alert"
      class="flex items-center gap-[10px] px-[12px] py-[10px] rounded-[var(--radius-field)] bg-[var(--surface-card)] shadow-[var(--shadow-float)]"
      style={"border: var(--border-width) solid color-mix(in oklch, #{@hue} 38%, transparent); border-left: var(--border-accent-width) solid #{@hue};"}
      {@rest}
    >
      <span class="flex-1 text-[12.5px] text-[var(--arb-text-body)] font-[family-name:var(--font-sans)]">
        {render_slot(@inner_block)}
      </span>
      <span
        :if={@action}
        phx-click={@action_click}
        class="text-[10.5px] font-medium text-[var(--text-link)] cursor-pointer font-[family-name:var(--font-mono)]"
      >
        {@action}
      </span>
      <span
        :if={@dismiss_key != ""}
        class="text-[10.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
      >
        {@dismiss_key}
      </span>
    </div>
    """
  end

  defp toast_hue("info"), do: "var(--arb-info)"
  defp toast_hue("error"), do: "var(--arb-fail)"
  defp toast_hue("attention"), do: "var(--arb-attention)"
  defp toast_hue("live"), do: "var(--arb-live)"
  defp toast_hue(_other), do: "var(--arb-info)"

  @doc """
  Toast-based replacement for `flash_group/1`: standard `:info`/`:error`
  flash kinds plus the client-error/server-error reconnect notices, all
  rendered as `toast/1`.

  ## Examples

      <.toast_group flash={@flash} />
  """
  attr :id, :string, default: "toast-group"
  attr :flash, :map, required: true

  def toast_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="fixed top-4 right-4 z-50 flex flex-col gap-2 w-80 sm:w-96">
      <.toast
        :if={msg = Phoenix.Flash.get(@flash, :info)}
        id="toast-info"
        tone="info"
        phx-click={JS.push("lv:clear-flash", value: %{key: :info}) |> JS.hide(to: "#toast-info")}
      >
        {msg}
      </.toast>
      <.toast
        :if={msg = Phoenix.Flash.get(@flash, :error)}
        id="toast-error"
        tone="error"
        phx-click={JS.push("lv:clear-flash", value: %{key: :error}) |> JS.hide(to: "#toast-error")}
      >
        {msg}
      </.toast>

      <.toast
        id="toast-client-error"
        tone="error"
        dismiss_key=""
        hidden
        phx-disconnected={
          JS.show(to: "#toast-client-error")
          |> JS.remove_attribute("hidden", to: "#toast-client-error")
        }
        phx-connected={
          JS.hide(to: "#toast-client-error")
          |> JS.set_attribute({"hidden", ""}, to: "#toast-client-error")
        }
      >
        We can't find the internet — attempting to reconnect
        <.icon name="hero-arrow-path" size={12} class="ml-1 motion-safe:animate-spin" />
      </.toast>

      <.toast
        id="toast-server-error"
        tone="error"
        dismiss_key=""
        hidden
        phx-disconnected={
          JS.show(to: "#toast-server-error")
          |> JS.remove_attribute("hidden", to: "#toast-server-error")
        }
        phx-connected={
          JS.hide(to: "#toast-server-error")
          |> JS.set_attribute({"hidden", ""}, to: "#toast-server-error")
        }
      >
        Something went wrong — attempting to reconnect
        <.icon name="hero-arrow-path" size={12} class="ml-1 motion-safe:animate-spin" />
      </.toast>
    </div>
    """
  end

  @doc """
  The dashed panel a list shows when a filter matches nothing.

  ## Examples

      <.empty_state icon="hero-clipboard-document-list">No issues match this filter.</.empty_state>
      <.empty_state icon="hero-moon" detail="every open issue has an unclosed blocker">
        No issues are ready.
      </.empty_state>

  Says what is empty, and where possible why. Never a call to action dressed
  up as an error.
  """
  attr :icon, :any, default: "hero-inbox", doc: ~s(full Heroicon class, or nil to omit)
  attr :detail, :string, default: nil, doc: "mono second line explaining why it's empty"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def empty_state(assigns) do
    ~H"""
    <div class={[
      "text-center px-5 py-5 rounded-[var(--radius-field)] border-dashed",
      "border-[length:var(--border-width)] border-[var(--border-strong)]",
      @class
    ]}>
      <.icon :if={@icon} name={@icon} size={22} color="var(--text-label)" class="mb-2 mx-auto" />
      <span class="block text-[12.5px] text-[var(--text-secondary)] font-[family-name:var(--font-sans)]">
        {render_slot(@inner_block)}
      </span>
      <span
        :if={@detail}
        class="block mt-[6px] text-[11.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
      >
        {@detail}
      </span>
    </div>
    """
  end
end
