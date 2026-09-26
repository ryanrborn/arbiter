defmodule ArbiterWeb.DemoteEntry do
  @moduledoc """
  The **Return to Backlog** (demote) action, shared by the board's Ready cards
  and the task detail page (bd-a1bmyx).

  Both surfaces call the same underlying `return_to_backlog` action through here
  for consistency.

  ## The button nests inside a clickable card, deliberately

  On the board, the Demote button sits inside a card whose own `phx-click`
  navigates to the issue. That is safe without any `stopPropagation`: LiveView
  binds clicks once on `window` and resolves the target with
  `closestPhxBinding/2`, so the **nearest** `phx-click` ancestor wins and the
  card's navigation never fires for a click on the button.
  """

  use Phoenix.Component

  import Phoenix.LiveView, only: [put_flash: 3]

  @doc """
  Whether `issue` should be offered a Return to Backlog action.

  Only offered on Ready (refined: true) tasks that are undispatched (status: :open).
  """
  @spec eligible?(any()) :: boolean()
  def eligible?(%{refined: true, status: :open}), do: true
  def eligible?(_), do: false

  @doc """
  The Return to Backlog button.

  `id` is required and differs per surface (`task-demote`,
  `board-demote-<id>`), because the same issue can be on screen in both at
  once and a duplicate DOM id would make either untestable and the second
  un-clickable.
  """
  attr :id, :string, required: true

  attr :issue_id, :string,
    default: nil,
    doc: "sent with the event; nil means the page's own issue"

  attr :label, :string, default: "Return to Backlog"
  attr :size, :string, default: "sm"
  attr :variant, :string, default: "ghost"
  attr :class, :any, default: nil
  attr :rest, :global

  def demote_button(assigns) do
    ~H"""
    <ArbiterWeb.CoreComponents.Core.button
      id={@id}
      size={@size}
      variant={@variant}
      class={@class}
      phx-click="return_to_backlog"
      phx-value-id={@issue_id}
      title="Send this task back to Backlog for further refinement"
      {@rest}
    >
      <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-arrow-uturn-left" /></:icon>
      {@label}
    </ArbiterWeb.CoreComponents.Core.button>
    """
  end
end
