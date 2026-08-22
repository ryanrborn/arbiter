defmodule ArbiterWeb.CoreComponents.Core do
  @moduledoc """
  Core primitives from the operator-console design handoff: Button, Icon,
  KeyHint, Toggle, Panel.

  Colors and spacing are drawn from the `--arb-*`/semantic design tokens in
  `assets/css/app.css` via Tailwind arbitrary values (`bg-[var(--...)]`)
  rather than daisyUI's theme slots, matching the handoff's reference
  implementation token-for-token.
  """
  use Phoenix.Component

  @doc """
  The console's button; every action that changes machine state is one of these.

  ## Examples

      <.button variant="primary" key_hint="C">
        <:icon><.icon name="plus" size={13} /></:icon>
        New issue
      </.button>
      <.button>Edit</.button>
      <.button variant="ghost" size="sm">Log</.button>
      <.button variant="danger" size="sm">Stop</.button>

  One primary per screen region. `attention` is reserved for the button that
  clears an amber "needs you" state (Open review, Answer). `danger` is a
  wash-and-outline treatment, never a solid red fill.
  """
  attr :variant, :string,
    values: ~w(primary secondary attention danger ghost),
    default: "secondary"

  attr :size, :string, values: ~w(sm md lg), default: "md"
  attr :key_hint, :string, default: nil, doc: ~s(keyboard shortcut, e.g. "C")
  attr :disabled, :boolean, default: false

  attr :focused, :boolean,
    default: false,
    doc: "render the 2px focus ring statically (for specimens and docs)"

  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(form name value type)

  slot :icon, doc: "leading element, normally an <.icon />"
  slot :inner_block

  def button(assigns) do
    ~H"""
    <button
      disabled={@disabled}
      class={[
        "inline-flex items-center gap-[7px] rounded-[var(--radius-field)] border border-solid font-medium",
        "transition-[background,border-color] duration-[var(--dur-hover)] ease-[var(--arb-ease-out)]",
        "cursor-pointer disabled:cursor-not-allowed disabled:hover:brightness-100",
        "disabled:bg-[var(--arb-panel-alt)] disabled:border-[var(--border-default)] disabled:text-[var(--arb-text-ghost)]",
        button_variant_class(@variant),
        button_size_class(@size),
        @focused && "shadow-[var(--ring-focus)]",
        @class
      ]}
      {@rest}
    >
      <span :if={@icon != []} class="inline-flex">{render_slot(@icon)}</span>
      {render_slot(@inner_block)}
      <.key_hint :if={@key_hint} class="ml-px">{@key_hint}</.key_hint>
    </button>
    """
  end

  defp button_variant_class("primary") do
    "bg-[var(--accent-primary)] border-[var(--accent-primary)] text-[var(--accent-primary-ink)] hover:brightness-[1.06]"
  end

  defp button_variant_class("attention") do
    "bg-[var(--arb-attention)] border-[var(--arb-attention)] text-[var(--arb-attention-ink)] hover:brightness-[1.06]"
  end

  defp button_variant_class("secondary") do
    "bg-[var(--surface-card)] border-[var(--border-strong)] text-[var(--arb-text-body)] hover:bg-[var(--arb-raised-hover)]"
  end

  defp button_variant_class("ghost") do
    "bg-transparent border-transparent text-[var(--text-secondary)] hover:bg-[var(--surface-card)] hover:text-[var(--text-title)]"
  end

  defp button_variant_class("danger") do
    "bg-[var(--arb-fail-wash)] border-[var(--arb-fail-edge)] text-[var(--arb-fail-text)] hover:bg-[oklch(70%_0.19_22_/_0.2)]"
  end

  defp button_size_class("sm"), do: "h-[var(--control-sm)] px-[10px] text-[11.5px]"
  defp button_size_class("md"), do: "h-[var(--control-md)] px-[14px] text-[12.5px]"
  defp button_size_class("lg"), do: "h-[var(--control-lg)] px-[18px] text-[13px]"

  @doc """
  A Heroicon rendered as a currentColor mask — the only icon primitive in
  Arbiter; never hand-draw an SVG.

  Backed by the `hero-*` Tailwind classes the app already vendors from
  `deps/heroicons` (see `assets/vendor/heroicons.js`), so unlike the design
  handoff's CDN-fallback reference implementation, every Heroicon name works
  offline.

  ## Examples

      <.icon name="hero-plus" size={14} />
      <.icon name="cpu-chip" />
      <.icon name="check-circle" variant="micro" color="var(--arb-live)" />

  Sets: `outline` (default, 16px), `solid`, `mini` (14px), `micro` (12px). A
  `-solid`/`-mini`/`-micro` suffix on `name` wins over `variant`.
  """
  attr :name, :string, required: true, doc: ~s(Heroicon slug, e.g. "plus" or "hero-cpu-chip")
  attr :variant, :string, values: ~w(outline solid mini micro), default: "outline"
  attr :size, :integer, default: nil, doc: "pixel size; defaults per variant"
  attr :color, :string, default: nil, doc: "mask fill; defaults to currentColor"
  attr :class, :any, default: nil
  attr :rest, :global

  def icon(assigns) do
    %{hero_class: hero_class, size: px} = icon_info(assigns.name, assigns.variant, assigns.size)

    assigns =
      assigns
      |> assign(:hero_class, hero_class)
      |> assign(:icon_style, icon_style(px, assigns.color))

    ~H"""
    <span aria-hidden="true" class={[@hero_class, @class]} style={@icon_style} {@rest} />
    """
  end

  @icon_default_size %{"outline" => 16, "solid" => 16, "mini" => 14, "micro" => 12}

  defp icon_info(name, variant, size) do
    raw = to_string(name)
    suffix = Regex.run(~r/-(solid|mini|micro)$/, raw) |> icon_suffix()
    set = suffix || to_string(variant)

    slug =
      raw |> String.replace_prefix("hero-", "") |> String.replace(~r/-(solid|mini|micro)$/, "")

    class_suffix = if set in ~w(solid mini micro), do: "-#{set}", else: ""

    %{
      hero_class: "hero-#{slug}#{class_suffix}",
      size: size || Map.get(@icon_default_size, set, 16)
    }
  end

  defp icon_suffix([_, s]), do: s
  defp icon_suffix(nil), do: nil

  defp icon_style(px, nil), do: "width: #{px}px; height: #{px}px;"
  defp icon_style(px, color), do: "width: #{px}px; height: #{px}px; background-color: #{color};"

  @doc """
  A keyboard shortcut chip. Keyboard is the primary input, so every action
  that has a key shows it.

  ## Examples

      <.key_hint>C</.key_hint>
      <span>Search <.key_hint>/</.key_hint></span>

  Lowercase for named keys (`esc`, `tab`), uppercase for letters. Inside a
  `<.button>`, pass `key_hint` instead of nesting this by hand.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def key_hint(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center px-[4px] py-[1px] border rounded-[var(--radius-chip)]",
        "border-[var(--border-strong)] text-[var(--text-label)] font-medium text-[10px] leading-[1.4]",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  A settings switch. Used on workspace config, where every toggle states its
  consequence rather than hiding it in a tooltip.

  ## Examples

      <.toggle checked label="Pause on quota exhaustion" hint="stop dispatching at 100% of the 5h window" phx-click="toggle-pause" />
      <.toggle checked={false} />

  Lime when on. Only destructive or budget-affecting settings get a colored
  control. With a `label`, the toggle renders as a full settings row.
  """
  attr :checked, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :label, :string, default: nil, doc: "setting name; renders a full settings row"
  attr :hint, :string, default: nil, doc: "one-line consequence of turning this on"
  attr :class, :any, default: nil
  attr :rest, :global

  def toggle(assigns) do
    ~H"""
    <div :if={@label} class={["flex items-center justify-between gap-3", @class]}>
      <span class="flex flex-col gap-0.5">
        <span class="font-medium text-[12px] text-[var(--arb-text-body)]">{@label}</span>
        <span
          :if={@hint}
          class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
        >
          {@hint}
        </span>
      </span>
      <.toggle_switch checked={@checked} disabled={@disabled} {@rest} />
    </div>
    <.toggle_switch :if={!@label} checked={@checked} disabled={@disabled} class={@class} {@rest} />
    """
  end

  attr :checked, :boolean, required: true
  attr :disabled, :boolean, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  defp toggle_switch(assigns) do
    ~H"""
    <span
      role="switch"
      aria-checked={to_string(@checked)}
      class={[not @disabled && "cursor-pointer", @disabled && "cursor-not-allowed opacity-50", @class]}
      {@rest}
    >
      <span class={[
        "inline-flex w-[34px] h-[19px] p-0.5 rounded-[var(--radius-pill)] border flex-none",
        "transition-[background] duration-[var(--dur-hover)] ease-[var(--arb-ease-out)]",
        @checked && "justify-end bg-[var(--accent-primary)] border-[var(--accent-primary)]",
        !@checked && "justify-start bg-[var(--arb-done-wash)] border-[var(--border-strong)]"
      ]}>
        <span class={[
          "w-[13px] h-[13px] rounded-full",
          @checked && "bg-[var(--accent-primary-ink)]",
          !@checked && "bg-[var(--text-secondary)]"
        ]} />
      </span>
    </span>
    """
  end

  @doc """
  The bordered container everything else sits in — depth comes from this 1px
  line and the surface ramp, never a shadow.

  ## Examples

      <.panel title="Active workers" meta="4 running">
        <:actions><.link navigate={~p"/workers"}>See all</.link></:actions>
        …rows…
      </.panel>
      <.panel padded={false}><LogStream lines={lines} /></.panel>

  One step of separation is enough: a card on a panel is `--surface-card`,
  and you never stack three surfaces.
  """
  attr :title, :string, default: nil

  attr :meta, :string,
    default: nil,
    doc: ~s(mono sub-label in the header, e.g. "28px sm · 34px default")

  attr :padded, :boolean, default: true, doc: "set false when the body is a flush table or log"
  attr :surface, :string, values: ~w(panel chrome sunken), default: "panel"
  attr :class, :any, default: nil
  attr :body_class, :any, default: nil

  slot :actions, doc: "right-aligned header controls"
  slot :inner_block

  def panel(assigns) do
    ~H"""
    <section class={[
      "border rounded-[var(--radius-panel)] border-[var(--border-default)] overflow-hidden",
      panel_surface_class(@surface),
      @class
    ]}>
      <header
        :if={@title || @actions != []}
        class="flex items-center justify-between gap-3 px-[18px] py-[12px] border-b border-[var(--border-default)]"
      >
        <span class="flex items-baseline gap-[10px] min-w-0">
          <span class="font-medium text-[13px] text-[var(--text-title)]">{@title}</span>
          <span
            :if={@meta}
            class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
          >
            {@meta}
          </span>
        </span>
        {render_slot(@actions)}
      </header>
      <div class={[@padded && "px-[18px] py-[var(--space-4)]", @body_class]}>
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  defp panel_surface_class("panel"), do: "bg-[var(--surface-panel)]"
  defp panel_surface_class("chrome"), do: "bg-[var(--surface-chrome)]"
  defp panel_surface_class("sunken"), do: "bg-[var(--arb-canvas-sunken)]"
end
