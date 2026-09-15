defmodule ArbiterWeb.ParentLink do
  @moduledoc """
  One `parent_of` edge, rendered at two sizes.

  Design bd-2s901b §4/§5/§7 (ticket bd-38of5i). Epics are gone from every
  board column, so the two places a child still announces its container are:

    * **`compact`** — the `↳ bd-cv1inp` chip on a board card. Id only; the
      parent's title and progress ride in the tooltip, because a card has no
      room for a second title. This is the board's entire replacement for the
      epic cards it no longer shows.
    * **`full`** — the banner under a child issue's title:
      `↳ Part of bd-cv1inp — Browser coordinator sessions • 9/14 closed`.

  They are one component on purpose. Two surfaces that mean the same thing and
  are written twice drift on the first edge case, and this edge has four of
  them:

    * **multiple parents** — legal, if unusual. `parent_links/1` stacks them,
      most recently updated first, rather than picking one arbitrarily. (The
      board card, which has room for one chip, takes that same first parent.)
    * **a non-epic parent** — a plain task with subtasks. Same banner shape,
      none of the epic chrome: `↳ Child of bd-x — …`, no progress, no bar.
    * **a closed epic** — still true, so it still renders: muted, and
      `14/14 closed ✓` instead of a partway bar.
    * **a cross-workspace parent** — a workspace tag and the same `⧉` marker
      the relationships panel uses for a cross-workspace edge.

  ## The parent map

  Both modes read a plain map, not an `%Issue{}`, so the board (which derives
  its refs in `Arbiter.Board.Snapshot`, with no repo access) and the detail
  page (which builds them from `Arbiter.Tasks.ParentRefs`) can feed the same
  component. Only `:id` is required:

      %{
        id: "bd-cv1inp",
        title: "Browser coordinator sessions",
        issue_type: :epic,
        status: :open,
        child_total: 14,
        child_closed: 9,
        # set only when the parent is in another workspace
        workspace_name: nil,
        # `{index, total}`, set only when the sibling order is unambiguous
        position: nil
      }
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ArbiterWeb.Endpoint,
    router: ArbiterWeb.Router,
    statics: ArbiterWeb.static_paths()

  @doc """
  A stack of `full` banners, one per parent, in the order given.

  Renders nothing when the list is empty, so a caller can drop it in
  unconditionally.
  """
  attr :parents, :list, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def parent_links(assigns) do
    ~H"""
    <div :if={@parents != []} id={@id} class={["flex flex-col gap-1", @class]}>
      <.parent_link :for={parent <- @parents} parent={parent} mode="full" />
    </div>
    """
  end

  @doc """
  One parent edge.

  ## Examples

      <.parent_link parent={@parent} mode="compact" />
      <.parent_link parent={@parent} />
  """
  attr :parent, :map, required: true

  attr :mode, :string,
    values: ~w(full compact),
    default: "full",
    doc: ~s(`"full"` on a detail page, `"compact"` as a chip on a board card)

  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def parent_link(assigns) do
    parent = assigns.parent
    epic? = Map.get(parent, :issue_type) == :epic
    total = Map.get(parent, :child_total) || 0
    closed_count = Map.get(parent, :child_closed) || 0
    closed? = Map.get(parent, :status) == :closed

    assigns =
      assigns
      |> assign(:title, present(Map.get(parent, :title)))
      |> assign(:closed?, closed?)
      # Progress is epic chrome: a plain parent task has a child count, but
      # "3/8 closed" on it reads as a project-management rollup it never was.
      |> assign(:progress?, epic? and total > 0)
      |> assign(:progress_text, progress_text(closed_count, total, closed?))
      |> assign(:progress_pct, percent(closed_count, total))
      |> assign(:lead, if(epic?, do: "Part of", else: "Child of"))
      |> assign(:workspace_name, present(Map.get(parent, :workspace_name)))
      |> assign(:position, Map.get(parent, :position))

    assigns = assign(assigns, :tooltip, tooltip(assigns))

    render_mode(assigns)
  end

  defp render_mode(%{mode: "compact"} = assigns) do
    ~H"""
    <.link
      navigate={~p"/tasks/#{@parent.id}"}
      id={@id}
      data-role="parent-chip"
      data-parent={@parent.id}
      title={@tooltip}
      class={[
        "inline-flex items-center gap-0.5 self-start max-w-full",
        "px-1.5 py-[1px] rounded-[var(--radius-chip)] border border-solid border-[var(--border-default)]",
        "text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)] truncate",
        "transition-colors duration-[var(--dur-hover)] ease-[var(--arb-ease-out)]",
        "hover:text-[var(--text-link)] hover:border-[var(--border-strong)]",
        @class
      ]}
    >
      <span aria-hidden="true">↳</span>{@parent.id}
    </.link>
    """
  end

  defp render_mode(assigns) do
    ~H"""
    <div
      id={@id}
      data-role="parent-banner"
      data-parent={@parent.id}
      data-closed={@closed? && "true"}
      class={[
        "flex flex-wrap items-center gap-x-1.5 gap-y-1 text-[12px] leading-[1.5]",
        if(@closed?, do: "text-[var(--text-label)]", else: "text-[var(--text-secondary)]"),
        @class
      ]}
    >
      <span aria-hidden="true">↳</span>
      <span>{@lead}</span>

      <.link
        navigate={~p"/tasks/#{@parent.id}"}
        class="inline-flex items-center gap-1.5 min-w-0 text-[var(--text-link)] hover:underline"
      >
        <code class="text-[11px] font-[family-name:var(--font-mono)]">{@parent.id}</code>
        <span :if={@title} class="truncate" title={@title}>— {@title}</span>
      </.link>

      <span :if={@progress?} data-role="parent-progress" class="inline-flex items-center gap-1.5">
        <span aria-hidden="true">•</span>
        <%!-- The bar is the one piece of epic-only chrome: it says "partway"
             at a glance, which a fraction alone does not. A finished epic
             gets the ✓ instead — there is nothing left to be partway through. --%>
        <span
          :if={!@closed?}
          data-role="parent-progress-bar"
          aria-hidden="true"
          class="inline-block w-12 h-[3px] rounded-full bg-[var(--arb-line)] overflow-hidden"
        >
          <span
            class="block h-full rounded-full bg-[var(--arb-done-edge)]"
            style={"width: #{@progress_pct}%"}
          />
        </span>
        <span class="font-[family-name:var(--font-mono)] text-[11px] tabular-nums">
          {@progress_text}
        </span>
      </span>

      <%!-- Design §7: a position is only shown when it is a fact. See
           `Arbiter.Tasks.ParentRefs.chain_position/3` — anything short of a
           single unambiguous `depends_on` chain resolves to nil and this
           disappears rather than inventing a number. --%>
      <span
        :if={@position}
        data-role="parent-position"
        class="font-[family-name:var(--font-mono)] text-[11px] tabular-nums text-[var(--text-label)]"
      >
        · {position_text(@position)}
      </span>

      <span
        :if={@workspace_name}
        data-role="cross-workspace-marker"
        title="the parent lives in another workspace"
        class={[
          "inline-flex items-center gap-1 px-1.5 py-[1px] rounded-[var(--radius-chip)]",
          "border border-solid border-[var(--border-default)]",
          "text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
        ]}
      >
        <span aria-hidden="true">⧉</span>workspace: {@workspace_name}
      </span>
    </div>
    """
  end

  # The chip is an id and nothing else, so everything the banner says out loud
  # has to survive in the tooltip.
  defp tooltip(%{progress?: true} = assigns),
    do: "#{assigns.title || assigns.parent.id} — #{assigns.progress_text}"

  defp tooltip(assigns), do: assigns.title || assigns.parent.id

  defp progress_text(closed_count, total, true), do: "#{closed_count}/#{total} closed ✓"
  defp progress_text(closed_count, total, _closed?), do: "#{closed_count}/#{total} closed"

  defp position_text({index, total}), do: "#{index} of #{total}"

  defp percent(_closed_count, 0), do: 0
  defp percent(closed_count, total), do: round(closed_count / total * 100)

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil
end
