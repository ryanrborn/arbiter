defmodule ArbiterWeb.CoreComponents.Data do
  @moduledoc """
  Data-display primitives: status/priority/type tags, a difficulty meter,
  and generic list/table wrappers.

  Foundation and conventions match `ArbiterWeb.CoreComponents`.
  """
  use Phoenix.Component

  @doc """
  Renders a status as a colored badge, using the LITERAL status value
  verbatim — never prettified or humanized. Downstream tooling and
  operators match on the raw status atom/string (e.g. `awaiting_review_gate`),
  so this component must not reformat it.

  ## Examples

      <.status_chip status={:completed} />
      <.status_chip status={:awaiting_review_gate} />
  """
  attr :status, :any, required: true
  attr :class, :any, default: nil

  def status_chip(assigns) do
    ~H"""
    <span class={["badge", status_chip_class(@status), @class]}>{@status}</span>
    """
  end

  defp status_chip_class(status) when is_atom(status),
    do: status_chip_class(Atom.to_string(status))

  defp status_chip_class("idle"), do: "badge-ghost"
  defp status_chip_class("running"), do: "badge-info"
  defp status_chip_class("resuming"), do: "badge-info"
  defp status_chip_class("awaiting"), do: "badge-warning"
  # The design handoff writes some statuses with spaces where the schema uses
  # underscores ("awaiting review" on a RunRow). Same state, same badge.
  defp status_chip_class("awaiting review"), do: "badge-warning"
  defp status_chip_class("awaiting_review"), do: "badge-warning"
  defp status_chip_class("awaiting_review_gate"), do: "badge-warning"
  defp status_chip_class("completed"), do: "badge-success"
  defp status_chip_class("failed"), do: "badge-error"
  defp status_chip_class("open"), do: "badge-success"
  defp status_chip_class("in_progress"), do: "badge-info"
  defp status_chip_class("closed"), do: "badge-ghost"
  defp status_chip_class(_), do: "badge-ghost"

  @doc """
  Renders a priority (P0-P4) as a colored badge. P0/P1 are red (most
  urgent), P2 is neutral, P3/P4 are ghost (low priority, de-emphasized).

  ## Examples

      <.priority_tag priority={0} />
      <.priority_tag priority={3} />
  """
  attr :priority, :integer, default: nil
  attr :class, :any, default: nil

  def priority_tag(assigns) do
    ~H"""
    <span class={["badge", priority_tag_class(@priority), @class]}>
      {if @priority, do: "P#{@priority}", else: "—"}
    </span>
    """
  end

  defp priority_tag_class(p) when p in [0, 1], do: "badge-error"
  defp priority_tag_class(2), do: "badge-neutral"
  defp priority_tag_class(p) when p in [3, 4], do: "badge-ghost"
  defp priority_tag_class(_), do: "badge-ghost"

  @doc """
  Renders a difficulty (D0-D4) as a 5-bar meter. For D{n}, n+1 bars are
  filled — D0 fills one bar, D4 fills all five. Only D4 tints its filled
  bars red; every other difficulty uses the neutral fill color. `nil`
  renders all five bars empty.

  ## Examples

      <.difficulty_meter difficulty={0} />
      <.difficulty_meter difficulty={4} />
      <.difficulty_meter difficulty={nil} />
  """
  attr :difficulty, :integer, default: nil
  attr :class, :any, default: nil

  def difficulty_meter(assigns) do
    filled_count =
      if is_integer(assigns.difficulty) and assigns.difficulty in 0..4,
        do: assigns.difficulty + 1,
        else: 0

    assigns =
      assign(assigns,
        filled_count: filled_count,
        label: difficulty_meter_label(assigns.difficulty)
      )

    ~H"""
    <span class={["inline-flex items-center gap-0.5", @class]} role="img" aria-label={@label}>
      <span
        :for={i <- 1..5}
        class={[
          "h-3 w-1.5 rounded-sm",
          if(i <= @filled_count,
            do: ["difficulty-bar-filled", difficulty_fill_class(@difficulty)],
            else: ["difficulty-bar-empty", "bg-base-content/10"]
          )
        ]}
      />
    </span>
    """
  end

  defp difficulty_fill_class(4), do: "bg-error"
  defp difficulty_fill_class(_), do: "bg-primary"

  defp difficulty_meter_label(nil), do: "Difficulty: not set"
  defp difficulty_meter_label(d) when d in 0..4, do: "Difficulty D#{d}"
  defp difficulty_meter_label(_), do: "Difficulty: not set"

  @doc """
  Renders an issue/task type as a badge, using the literal type value
  verbatim (same rule as `status_chip/1` — no humanizing).

  ## Examples

      <.type_tag type={:bug_fix} />
      <.type_tag type="spike" />
      <.type_tag type="never invoked" dashed />

  `dashed` marks an add affordance or a dead-state flag (e.g. a skill that
  has never been invoked) rather than a real category.
  """
  attr :type, :any, required: true
  attr :dashed, :boolean, default: false
  attr :class, :any, default: nil

  def type_tag(assigns) do
    ~H"""
    <span class={["badge badge-ghost", @dashed && "border-dashed", @class]}>{@type}</span>
    """
  end

  @doc """
  Renders a definition-list style key/value grid.

  ## Examples

      <.data_list>
        <:item label="Priority">P1</:item>
        <:item label="Status">running</:item>
      </.data_list>
  """
  attr :class, :any, default: nil

  slot :item, required: true do
    attr :label, :string, required: true
  end

  def data_list(assigns) do
    ~H"""
    <dl class={["grid grid-cols-[auto_1fr] gap-x-4 gap-y-1", @class]}>
      <%= for item <- @item do %>
        <dt class="font-medium text-base-content/60">{item.label}</dt>
        <dd>{render_slot(item)}</dd>
      <% end %>
    </dl>
    """
  end

  @doc """
  Renders a generic data table from a list of rows and `:col` slots.

  ## Examples

      <.data_table id="tasks" rows={@tasks}>
        <:col :let={task} label="Title">{task.title}</:col>
      </.data_table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :class, :any, default: nil

  slot :col, required: true do
    attr :label, :string
  end

  def data_table(assigns) do
    ~H"""
    <table id={@id} class={["table table-zebra", @class]}>
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @rows}>
          <td :for={col <- @col}>{render_slot(col, row)}</td>
        </tr>
      </tbody>
    </table>
    """
  end
end
