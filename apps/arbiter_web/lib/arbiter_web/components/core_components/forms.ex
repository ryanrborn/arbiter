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
  """
  attr :type, :string, default: "text", doc: "input type (text, email, password, number, etc.)"
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(pattern title minlength maxlength step min max)

  def input(assigns) do
    ~H"""
    <input
      type={@type}
      name={@name}
      id={@id}
      value={@value}
      placeholder={@placeholder}
      disabled={@disabled}
      required={@required}
      class={[@class || "input"]}
      {@rest}
    />
    """
  end

  @doc """
  Select dropdown with options.

  ## Examples

      <.select name="status" id="status-select" options={[{"Open", "open"}, {"Closed", "closed"}]} />
      <.select name="status" id="status-select" options={[{"Open", "open"}]} prompt="Choose one..." />
  """
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :options, :list, required: true, doc: "list of {label, value} tuples"
  attr :value, :any, default: nil
  attr :prompt, :string, default: nil, doc: "placeholder option text"
  attr :disabled, :boolean, default: false
  attr :multiple, :boolean, default: false
  attr :required, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def select(assigns) do
    ~H"""
    <select
      name={@name}
      id={@id}
      disabled={@disabled}
      multiple={@multiple}
      required={@required}
      class={[@class || "select"]}
      {@rest}
    >
      <option :if={@prompt} value="">{@prompt}</option>
      <option :for={{label, opt_value} <- @options} value={opt_value} selected={opt_value == @value}>
        {label}
      </option>
    </select>
    """
  end

  @doc """
  Multi-line text input.

  ## Examples

      <.textarea name="description" id="desc-textarea" />
      <.textarea name="notes" id="notes-textarea" value="Initial text" />
  """
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false
  attr :rows, :integer, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(minlength maxlength spellcheck)

  def textarea(assigns) do
    ~H"""
    <textarea
      name={@name}
      id={@id}
      placeholder={@placeholder}
      disabled={@disabled}
      required={@required}
      rows={@rows}
      class={[@class || "textarea"]}
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
  """
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :label, :string, default: nil
  attr :checked, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :required, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global

  def checkbox(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <input
        type="checkbox"
        name={@name}
        id={@id}
        checked={@checked}
        disabled={@disabled}
        required={@required}
        class={[@class || "checkbox"]}
        {@rest}
      />
      <label :if={@label} for={@id}>{@label}</label>
    </div>
    """
  end
end
