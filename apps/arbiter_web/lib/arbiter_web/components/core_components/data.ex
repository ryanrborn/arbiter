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
  defp status_chip_class("proposed"), do: "badge-warning"
  defp status_chip_class("hypothesis"), do: "badge-ghost"
  defp status_chip_class("applied"), do: "badge-success"
  defp status_chip_class("rejected"), do: "badge-error"
  defp status_chip_class("superseded"), do: "badge-neutral"
  # Worktree state on the workspace config screen: a dirty checkout is not an
  # error, it is the one thing an operator has to deal with before a worker can
  # take the repo — so it warns rather than fails.
  defp status_chip_class("clean"), do: "badge-success"
  defp status_chip_class("dirty"), do: "badge-warning"
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
  attr :rest, :global

  def type_tag(assigns) do
    ~H"""
    <span class={["badge badge-ghost", @dashed && "border-dashed", @class]} {@rest}>{@type}</span>
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

  Columns without `width` share the remaining space equally (`minmax(0,1fr)`);
  give the one free-text column (e.g. `title`) no width so it absorbs the rest.
  Cells truncate to a single ellipsised line by default — pass `wrap` on a
  `:col` slot for text that should wrap instead (e.g. a detail column).

  ## Examples

      <.data_table id="tasks" rows={@tasks}>
        <:col :let={task} label="task" width="84px">{task.id}</:col>
        <:col :let={task} label="title" mono={false}>{task.title}</:col>
        <:col :let={task} label="spend" width="60px" align="right">{task.cost}</:col>
      </.data_table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :class, :any, default: nil

  slot :col, required: true do
    attr :label, :string
    attr :width, :string, doc: ~s(CSS width, e.g. "84px" — omit for the flexible column)
    attr :align, :string, doc: ~s(pass "right" for numeric columns; defaults left)
    attr :mono, :boolean, doc: "defaults true — pass false for prose columns like title"

    attr :wrap, :boolean,
      doc: "defaults false (truncate + ellipsis) — pass true to wrap long text instead"
  end

  def data_table(assigns) do
    assigns =
      assign(assigns,
        template_columns: Enum.map_join(assigns.col, " ", &(&1[:width] || "minmax(0,1fr)")),
        last_index: length(assigns.rows) - 1
      )

    ~H"""
    <div id={@id} class={["w-full", @class]} role="table">
      <div
        class="grid items-center gap-3 h-[30px] px-[14px] bg-[var(--arb-chrome)]"
        style={"grid-template-columns: #{@template_columns};"}
        role="row"
      >
        <span
          :for={col <- @col}
          class={[
            "text-[10.5px] uppercase tracking-[0.06em] font-[family-name:var(--font-mono)] text-[var(--text-label)]",
            data_table_align_class(col)
          ]}
          role="columnheader"
        >
          {col[:label]}
        </span>
      </div>
      <div
        :for={{row, index} <- Enum.with_index(@rows)}
        class={[
          "grid items-center gap-3 min-h-[34px] px-[14px] hover:bg-[var(--arb-raised-hover)]",
          index != @last_index && "border-b border-[var(--arb-line-soft)]"
        ]}
        style={"grid-template-columns: #{@template_columns};"}
        role="row"
      >
        <span
          :for={col <- @col}
          class={[
            "text-[11.5px]",
            if(col[:wrap], do: "break-words", else: "truncate"),
            data_table_mono?(col) && "font-[family-name:var(--font-mono)] tabular-nums",
            !data_table_mono?(col) && "text-[var(--text-body)]",
            data_table_align_class(col)
          ]}
          role="cell"
        >
          {render_slot(col, row)}
        </span>
      </div>
    </div>
    """
  end

  defp data_table_align_class(col), do: if(col[:align] == "right", do: "text-right")
  defp data_table_mono?(col), do: col[:mono] != false
end
