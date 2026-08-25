defmodule ArbiterWeb.WorkspaceDetail.Rows do
  @moduledoc """
  The row vocabulary of the workspace config screen.

  Every section of `/workspaces/:id` is the same shape: a header naming the
  section, then a divided stack of settings. A setting is a name, a control,
  and — the rule this module exists to enforce — **one line saying what
  changing it does**. `setting_row/1` takes `consequence` as a required
  attribute precisely so a new setting cannot be added without one; a screen
  full of switches whose effect the operator has to guess is the failure mode
  this screen is designed against.

  The consequence is emitted as `data-consequence` as well as text so the test
  suite can assert the invariant structurally (see
  `ArbiterWeb.WorkspaceConfigScreenTest`) rather than by eyeballing copy.

  `toggle_row/1` is a setting row whose control is a switch. It deliberately
  does *not* use `ArbiterWeb.CoreComponents.Core.toggle/1`: that renders a
  `<button role="switch">`, which cannot carry a value into a form submit.
  These switches live inside section forms, so they render a real checkbox
  (plus the hidden `false` companion) wearing the same clothes.
  """
  use Phoenix.Component

  @doc """
  One section pane. Hidden unless the rail has `name` selected.

  Every pane stays in the DOM: section state (an open modal, a half-filled
  form, a pending security downgrade) belongs to the section's component and
  would be thrown away by unmounting it on every rail click.
  """
  attr :name, :string, required: true, doc: "this pane's section slug"
  attr :section, :string, required: true, doc: "the slug currently selected in the rail"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def pane(assigns) do
    ~H"""
    <div class={[pane_class(@name, @section), @class]} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  `pane/1`'s classes, for a section whose pane *is* the root element of its
  live component — LiveView requires that root to be a literal HTML tag, so
  those components cannot wrap themselves in `pane/1`.
  """
  def pane_class(name, section) do
    ["flex-col gap-4", if(name == section, do: "flex", else: "hidden")]
  end

  @doc """
  The header line of a section pane: what you are looking at, and which
  workspace it belongs to.
  """
  attr :name, :string, required: true, doc: "section slug, echoed for tests"
  attr :section, :string, required: true, doc: "the slug currently selected in the rail"
  attr :title, :string, required: true
  attr :context, :string, required: true, doc: "right-aligned mono note, e.g. `3 paths`"

  def section_header(assigns) do
    ~H"""
    <div class={[
      "items-baseline justify-between gap-4",
      if(@name == @section, do: "flex", else: "hidden")
    ]}>
      <h2 class="m-0 font-[family-name:var(--font-sans)] text-[13px] font-medium leading-[1.3] text-[var(--text-title)]">
        {@title}
      </h2>
      <span
        data-section-context={@name}
        class="font-[family-name:var(--font-mono)] text-[11px] leading-[1.3] text-[var(--text-label)] truncate"
      >
        {@context}
      </span>
    </div>
    """
  end

  @doc """
  A divided stack of `setting_row/1`s.
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def rows(assigns) do
    ~H"""
    <div class={[
      "flex flex-col divide-y divide-solid divide-[var(--border-default)] border-y border-solid border-[var(--border-default)]",
      @class
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One setting: name, consequence, control.

  `:control` sits right-aligned on the name line. `:below` is for settings
  whose control is a list or an editor too wide to sit inline — it renders
  full width underneath, still inside the row.
  """
  attr :name, :string, required: true
  attr :consequence, :string, required: true
  attr :class, :any, default: nil
  slot :control
  slot :below

  def setting_row(assigns) do
    ~H"""
    <div data-setting-row={@name} class={["flex flex-col gap-2 py-[10px]", @class]}>
      <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
        <div class="min-w-0">
          <div class="font-[family-name:var(--font-sans)] text-[12px] font-medium leading-[1.4] text-[var(--text-body)]">
            {@name}
          </div>
          <div
            data-consequence={@consequence}
            class="mt-[3px] font-[family-name:var(--font-mono)] text-[11px] leading-[1.45] text-[var(--text-label)]"
          >
            {@consequence}
          </div>
        </div>
        <div :if={@control != []} class="flex sm:flex-none items-center justify-end gap-2">
          {render_slot(@control)}
        </div>
      </div>
      <div :if={@below != []} class="min-w-0">{render_slot(@below)}</div>
    </div>
    """
  end

  @doc """
  The chip a list row pins its resolved value to — the right-hand end of a
  "this maps to that" entry, so the mapping reads at a glance.
  """
  def value_chip do
    "inline-flex flex-none items-center rounded-[var(--radius-chip)] border border-solid " <>
      "border-[var(--border-default)] px-[6px] py-[1px] " <>
      "font-[family-name:var(--font-mono)] text-[10.5px] text-[var(--text-secondary)]"
  end

  @doc """
  Classes for the `<ul>` of a list editor — repo overrides, routing rules,
  standing orders, secret names. They are lists of configured entries rather
  than settings, so they get the row treatment without the consequence line
  (their *container* is a `setting_row/1`, and that carries it).
  """
  def list_class, do: "m-0 flex list-none flex-col gap-1 p-0"

  @doc """
  One entry of a list editor.
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def list_row(assigns) do
    ~H"""
    <li
      class={[
        "flex items-center gap-2 rounded-[var(--radius-field)] border border-solid",
        "border-[var(--border-default)] bg-[var(--surface-card)] px-[10px] py-[6px]",
        "font-[family-name:var(--font-mono)] text-[11.5px] text-[var(--arb-text-body)]",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </li>
    """
  end

  @doc """
  The trash button that ends a list entry. `rest` carries the binding
  (`phx-click`, `phx-target`, `phx-value-*`) and `data-confirm`.
  """
  attr :label, :string, required: true, doc: "aria-label, e.g. `Remove rule D4`"
  attr :rest, :global

  def remove_button(assigns) do
    ~H"""
    <button type="button" class={icon_button(:danger)} aria-label={@label} {@rest}>
      <ArbiterWeb.CoreComponents.Core.icon name="hero-trash" size={13} />
    </button>
    """
  end

  @doc """
  The square, borderless button an inline list control sits in — reorder, remove,
  reveal. `:danger` colours it for the destructive one.
  """
  def icon_button(tone \\ :default) do
    [
      "inline-flex size-[20px] flex-none cursor-pointer items-center justify-center rounded-[var(--radius-chip)] " <>
        "disabled:cursor-not-allowed disabled:opacity-40",
      case tone do
        :danger ->
          "text-[var(--arb-fail-text)] hover:bg-[var(--arb-fail-wash)]"

        :default ->
          "text-[var(--text-label)] hover:bg-[var(--arb-raised)] hover:text-[var(--text-body)]"
      end
    ]
  end

  @doc """
  A setting row whose control is a switch.

  Pass `field` for a switch that submits with its section's form (the hidden
  companion input is what makes an *off* switch send `false` rather than
  nothing), or `click`/`target` for one that fires an event on its own.
  """
  attr :name, :string, required: true
  attr :consequence, :string, required: true
  attr :checked, :boolean, default: false
  attr :field, :string, default: nil, doc: "form input name, e.g. `config[merge_auto_merge]`"
  attr :click, :string, default: nil, doc: "event name, for a switch that fires on its own"
  attr :target, :any, default: nil
  attr :disabled, :boolean, default: false
  attr :rest, :global

  def toggle_row(assigns) do
    ~H"""
    <.setting_row name={@name} consequence={@consequence}>
      <:control>
        <input :if={@field} type="hidden" name={@field} value="false" />
        <label
          :if={@field}
          class={["cursor-pointer", @disabled && "cursor-not-allowed opacity-50"]}
          aria-label={@name}
        >
          <input
            type="checkbox"
            name={@field}
            value="true"
            checked={@checked}
            disabled={@disabled}
            class="peer sr-only"
            {@rest}
          />
          <span class={switch_track()}><span class={switch_knob()}></span></span>
        </label>
        <button
          :if={is_nil(@field)}
          type="button"
          role="switch"
          aria-checked={to_string(@checked)}
          aria-label={@name}
          phx-click={@click}
          phx-target={@target}
          disabled={@disabled}
          class={["cursor-pointer", @disabled && "cursor-not-allowed opacity-50"]}
          {@rest}
        >
          <span class={switch_track(@checked)}><span class={switch_knob(@checked)}></span></span>
        </button>
      </:control>
    </.setting_row>
    """
  end

  # The switch is two spans, not a daisyUI toggle: the checkbox form drives it
  # off `peer-checked` (reaching the knob through an arbitrary child variant,
  # since the knob is not itself the peer's sibling), the button form off the
  # flag, and both have to land on the same pixels.
  defp switch_track(checked \\ nil) do
    [
      "block h-[16px] w-[28px] rounded-full border border-solid transition-colors",
      case checked do
        nil ->
          "border-[var(--border-default)] bg-[var(--arb-raised)] " <>
            "peer-checked:border-[var(--accent-primary)] peer-checked:bg-[var(--accent-primary)] " <>
            "peer-checked:[&>span]:translate-x-[12px] peer-checked:[&>span]:bg-[var(--arb-chrome)]"

        true ->
          "border-[var(--accent-primary)] bg-[var(--accent-primary)]"

        false ->
          "border-[var(--border-default)] bg-[var(--arb-raised)]"
      end
    ]
  end

  defp switch_knob(checked \\ nil) do
    [
      "mt-[2px] ml-[2px] block size-[10px] rounded-full transition-transform",
      if(checked, do: "translate-x-[12px] bg-[var(--arb-chrome)]", else: "bg-[var(--text-label)]")
    ]
  end
end
