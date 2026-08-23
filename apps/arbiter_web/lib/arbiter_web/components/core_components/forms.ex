defmodule ArbiterWeb.CoreComponents.Forms do
  @moduledoc """
  Form primitives: Input, Select, Textarea, Checkbox.

  Styled wrappers for common form controls, using semantic design tokens from
  the operator-console design handoff (`--arb-*` and `--accent-*` in `assets/css/app.css`).
  """
  use Phoenix.Component

  @doc """
  Text input, password, email, and other single-line input types.

  ## Examples

      <.input type="text" name="username" id="user-input" />
      <.input type="email" name="email" id="email-input" placeholder="user@example.com" />
      <.input type="password" name="password" id="pwd-input" />
      <.input type="text" name="search" id="search-input" label="Search" hint="focus with /" key_hint="/" />
      <.input type="text" name="query" id="query-input" label="Query" error="Invalid syntax" />
  """
  attr :type, :string, default: "text", doc: "input type (text, email, password, number, etc.)"
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :value, :any, default: nil
  attr :label, :string, default: nil, doc: "field label"

  attr :hint, :string,
    default: nil,
    doc: "mono aside appended to the label, e.g. \"focus with /\""

  attr :key_hint, :string, default: nil, doc: "shortcut chip pinned inside the field's right edge"
  attr :placeholder, :string, default: nil
  attr :mono, :boolean, default: true, doc: "machine values are mono; prose is not"
  attr :error, :string, default: nil, doc: "inline error message; switches border to fail hue"
  attr :size, :string, values: ~w(sm md), default: "md"
  attr :icon, :any, default: nil, doc: "leading element inside the field, normally an icon"
  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(pattern title minlength maxlength step min max)

  def input(assigns) do
    ~H"""
    <label :if={@label || @hint || @error} class="flex flex-col gap-[6px]">
      <span :if={@label} class="font-medium text-[11.5px] text-[var(--arb-text-body)]">
        {@label}
        <span
          :if={@hint}
          class="font-normal text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
        >
          {" — "}{@hint}
        </span>
      </span>
      <span class={[
        "inline-flex items-center gap-[8px] w-full rounded-[var(--radius-field)] border border-solid",
        "bg-[var(--surface-field)] transition-[border-color] duration-[var(--dur-hover)]",
        @error && "border-[var(--arb-fail-edge)]",
        !@error &&
          "border-[var(--border-strong)] has-[:focus]:border-[var(--accent-primary)] has-[:focus]:shadow-[var(--ring-focus)]",
        @size == "sm" && "h-[var(--control-sm)] px-[10px]",
        @size == "md" && "h-[var(--control-md)] px-[10px]",
        @class
      ]}>
        <span :if={@icon} class="inline-flex flex-none">{@icon}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={@value}
          placeholder={@placeholder}
          disabled={@disabled}
          required={@required}
          class={[
            "flex-1 min-w-0 border-0 outline-none bg-transparent text-[12.5px] text-[var(--arb-text-body)]",
            @mono && "font-[family-name:var(--font-mono)]"
          ]}
          {@rest}
        />
        <ArbiterWeb.CoreComponents.Core.key_hint :if={@key_hint} class="flex-none">
          {@key_hint}
        </ArbiterWeb.CoreComponents.Core.key_hint>
      </span>
      <span :if={@error} class="font-normal text-[11.5px] text-[var(--arb-fail-text)]">
        {@error}
      </span>
    </label>
    <span
      :if={!@label && !@hint && !@error}
      class={[
        "inline-flex items-center gap-[8px] w-full rounded-[var(--radius-field)] border border-solid",
        "bg-[var(--surface-field)] transition-[border-color] duration-[var(--dur-hover)]",
        @error && "border-[var(--arb-fail-edge)]",
        !@error &&
          "border-[var(--border-strong)] has-[:focus]:border-[var(--accent-primary)] has-[:focus]:shadow-[var(--ring-focus)]",
        @size == "sm" && "h-[var(--control-sm)] px-[10px]",
        @size == "md" && "h-[var(--control-md)] px-[10px]",
        @class
      ]}
    >
      <span :if={@icon} class="inline-flex flex-none">{@icon}</span>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={@value}
        placeholder={@placeholder}
        disabled={@disabled}
        required={@required}
        class={[
          "flex-1 min-w-0 border-0 outline-none bg-transparent text-[12.5px] text-[var(--arb-text-body)]",
          @mono && "font-[family-name:var(--font-mono)]"
        ]}
        {@rest}
      />
      <ArbiterWeb.CoreComponents.Core.key_hint :if={@key_hint} class="flex-none">
        {@key_hint}
      </ArbiterWeb.CoreComponents.Core.key_hint>
    </span>
    """
  end

  @doc """
  Select dropdown with options.

  ## Examples

      <.select name="status" id="status-select" options={[{"Open", "open"}, {"Closed", "closed"}]} />
      <.select name="status" id="status-select" options={["Open", "Closed"]} />
      <.select name="status" id="status-select" options={[{"Open", "open"}]} prompt="Choose one..." />
      <.select name="priority" id="priority-select" label="Priority" options={[{"P1 — urgent", "1"}]} />
  """
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :options, :list, required: true, doc: "list of strings or {label, value} tuples"
  attr :label, :string, default: nil, doc: "field label"
  attr :value, :any, default: nil
  attr :prompt, :string, default: nil, doc: "placeholder option text"
  attr :size, :string, values: ~w(sm md), default: "md"
  attr :mono, :boolean, default: true, doc: "machine values are mono; prose is not"
  attr :error, :string, default: nil, doc: "inline error message; switches border to fail hue"
  attr :disabled, :boolean, default: false
  attr :multiple, :boolean, default: false
  attr :required, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def select(assigns) do
    ~H"""
    <label :if={@label || @error} class="flex flex-col gap-[6px]">
      <span :if={@label} class="font-medium text-[11.5px] text-[var(--arb-text-body)]">
        {@label}
      </span>
      <span class={[
        "relative inline-flex items-center w-full rounded-[var(--radius-field)] border border-solid",
        "bg-[var(--surface-card)]",
        @error && "border-[var(--arb-fail-edge)]",
        !@error && "border-[var(--border-strong)]",
        @size == "sm" && "h-[var(--control-sm)]",
        @size == "md" && "h-[var(--control-md)]",
        @class
      ]}>
        <select
          name={@name}
          id={@id}
          disabled={@disabled}
          multiple={@multiple}
          required={@required}
          class={[
            "appearance-none w-full h-full px-[10px] border-0 outline-none bg-transparent text-[12.5px] text-[var(--arb-text-body)] cursor-pointer",
            @mono && "font-[family-name:var(--font-mono)]"
          ]}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          <option
            :for={opt <- @options}
            value={option_value(opt)}
            selected={option_value(opt) == @value}
          >
            {option_label(opt)}
          </option>
        </select>
        <ArbiterWeb.CoreComponents.Core.icon
          name="hero-chevron-down-micro"
          size={11}
          color="var(--text-label)"
          class="absolute right-[9px] pointer-events-none"
        />
      </span>
      <span :if={@error} class="font-normal text-[11.5px] text-[var(--arb-fail-text)]">
        {@error}
      </span>
    </label>
    <span
      :if={!@label && !@error}
      class={[
        "relative inline-flex items-center w-full rounded-[var(--radius-field)] border border-solid",
        "bg-[var(--surface-card)] border-[var(--border-strong)]",
        @size == "sm" && "h-[var(--control-sm)]",
        @size == "md" && "h-[var(--control-md)]",
        @class
      ]}
    >
      <select
        name={@name}
        id={@id}
        disabled={@disabled}
        multiple={@multiple}
        required={@required}
        class={[
          "appearance-none w-full h-full px-[10px] border-0 outline-none bg-transparent text-[12.5px] text-[var(--arb-text-body)] cursor-pointer",
          @mono && "font-[family-name:var(--font-mono)]"
        ]}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        <option
          :for={opt <- @options}
          value={option_value(opt)}
          selected={option_value(opt) == @value}
        >
          {option_label(opt)}
        </option>
      </select>
      <ArbiterWeb.CoreComponents.Core.icon
        name="hero-chevron-down-micro"
        size={11}
        color="var(--text-label)"
        class="absolute right-[9px] pointer-events-none"
      />
    </span>
    """
  end

  defp option_label({label, _value}), do: label
  defp option_label(string), do: string

  defp option_value({_label, value}), do: value
  defp option_value(string), do: string

  @doc """
  Multi-line text input.

  ## Examples

      <.textarea name="description" id="desc-textarea" />
      <.textarea name="notes" id="notes-textarea" value="Initial text" />
      <.textarea name="acceptance" id="acceptance-textarea" label="Acceptance criteria (optional)" />
      <.textarea name="feedback" id="feedback-textarea" label="Feedback" error="Required field" />
  """
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :value, :any, default: nil
  attr :label, :string, default: nil, doc: "field label"
  attr :placeholder, :string, default: nil
  attr :error, :string, default: nil, doc: "inline error message; switches border to fail hue"
  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false
  attr :rows, :integer, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(minlength maxlength spellcheck)

  def textarea(assigns) do
    ~H"""
    <label :if={@label || @error} class="flex flex-col gap-[6px]">
      <span :if={@label} class="font-medium text-[11.5px] text-[var(--arb-text-body)]">{@label}</span>
      <textarea
        name={@name}
        id={@id}
        placeholder={@placeholder}
        disabled={@disabled}
        required={@required}
        rows={@rows}
        class={[
          "w-full p-[8px_10px] resize-vertical rounded-[var(--radius-field)] border border-solid bg-[var(--surface-field)] text-[12.5px] leading-[1.6] text-[var(--arb-text-body)]",
          "outline-none transition-[border-color] duration-[var(--dur-hover)]",
          "focus:ring-2 focus:ring-[var(--focus-ring)] focus:border-[var(--accent-primary)]",
          @error && "border-[var(--arb-fail-edge)]",
          !@error && "border-[var(--border-strong)]",
          @class
        ]}
        {@rest}
      >{@value}</textarea>
      <span :if={@error} class="font-normal text-[11.5px] text-[var(--arb-fail-text)]">
        {@error}
      </span>
    </label>
    <textarea
      :if={!@label && !@error}
      name={@name}
      id={@id}
      placeholder={@placeholder}
      disabled={@disabled}
      required={@required}
      rows={@rows}
      class={[
        "w-full p-[8px_10px] resize-vertical rounded-[var(--radius-field)] border border-solid bg-[var(--surface-field)] text-[12.5px] leading-[1.6] text-[var(--arb-text-body)]",
        "outline-none transition-[border-color] duration-[var(--dur-hover)]",
        "focus:ring-2 focus:ring-[var(--focus-ring)] focus:border-[var(--accent-primary)]",
        @error && "border-[var(--arb-fail-edge)]",
        !@error && "border-[var(--border-strong)]",
        @class
      ]}
      {@rest}
    >{@value}</textarea>
    """
  end

  @doc """
  Checkbox input with optional label.

  ## Examples

      <.checkbox name="agree" id="agree-checkbox" />
      <.checkbox name="agree" id="agree-checkbox" label="I agree to terms" />
      <.checkbox name="agree" id="agree-checkbox" label="I agree" checked={true} />
      <.checkbox name="criteria" id="criteria-checkbox" label="Acceptance criterion" align="start" />
  """
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :label, :string, default: nil, doc: "checkbox label"

  attr :align, :string,
    values: ~w(center start),
    default: "center",
    doc: "alignment for multi-line labels"

  attr :checked, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def checkbox(assigns) do
    ~H"""
    <label class={[
      "flex gap-[9px] font-normal text-[12.5px] leading-[1.5] text-[var(--arb-text-body)] cursor-pointer",
      @disabled && "cursor-not-allowed opacity-50",
      @align == "start" && "items-start",
      @align == "center" && "items-center",
      @class
    ]}>
      <input
        type="checkbox"
        name={@name}
        id={@id}
        checked={@checked}
        disabled={@disabled}
        required={@required}
        class="sr-only peer"
        {@rest}
      />
      <span class={[
        "flex-none inline-flex items-center justify-center w-[14px] h-[14px] rounded-[var(--radius-chip)] border border-solid transition-all",
        @align == "start" && "mt-[2px]",
        @checked && "bg-[var(--accent-primary)] border-[var(--accent-primary)]",
        !@checked && "bg-transparent border-[var(--border-strong)]",
        "peer-focus-visible:ring-2 peer-focus-visible:ring-[var(--ring-focus)] peer-focus-visible:ring-offset-2"
      ]}>
        <span
          :if={@checked}
          class="text-[9px] font-[600] text-[var(--accent-primary-ink)] font-[family-name:var(--font-mono)]"
        >
          ✓
        </span>
      </span>
      <span :if={@label}>{@label}</span>
    </label>
    """
  end
end
