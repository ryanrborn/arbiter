defmodule ArbiterWeb.RefineEntry do
  @moduledoc """
  The **Refine** action, shared by the two surfaces that offer it: the issue
  detail page's toolbar and the board's Backlog cards (bd-1lszsc).

  Both do exactly one thing — `Arbiter.Sessions.Refine.open/2`, then ask the
  dock to put the result on screen — so both do it through here rather than
  twice. A second implementation of "launch or reopen" is a second chance to
  get the "never two sessions for one issue" half wrong.

  ## Why the dock is reached by broadcast

  The dock is a sticky nested LiveView with its own process; a page holds no
  reference to it and `send_update/2` is for LiveComponents. So `open/2` calls
  `Arbiter.Sessions.request_open/1`, which the dock is already listening for.
  See that function's docs for why a broadcast is the right shape on a
  loopback, single-operator dashboard.

  ## The button nests inside a clickable card, deliberately

  On the board, the Refine button sits inside a card whose own `phx-click`
  navigates to the issue. That is safe without any `stopPropagation`: LiveView
  binds clicks once on `window` and resolves the target with
  `closestPhxBinding/2`, so the **nearest** `phx-click` ancestor wins and the
  card's navigation never fires for a click on the button.
  """

  use Phoenix.Component

  alias Arbiter.Sessions
  alias Arbiter.Sessions.Refine
  alias Arbiter.Tasks.Issue

  import Phoenix.LiveView, only: [put_flash: 3]

  @doc """
  Whether `issue` should be offered a Refine action.

  A thin pass-through to `Arbiter.Sessions.Refine.eligible?/1` so both
  templates read the same predicate the server enforces — a button that can
  appear where `open/2` would refuse is a button that lies.
  """
  @spec eligible?(Issue.t() | nil) :: boolean()
  defdelegate eligible?(issue), to: Refine

  @doc """
  Handle a Refine click for `issue`: launch or reopen its bound session, ask
  the dock to open it, and tell the operator which of the two happened.

  Returns the socket with a flash set either way — this is an operator action
  with no other visible result on the page it was clicked from (the session
  appears in the dock, which is a different LiveView), so silence would read
  as a dead button.
  """
  @spec open(Phoenix.LiveView.Socket.t(), Issue.t() | String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def open(socket, %Issue{} = issue), do: do_open(socket, issue)

  # The board holds snapshot cards, not issues, so its click carries an id.
  # `Arbiter.Sessions.Refine.open/2` resolves it and refuses one that has since
  # gone, which is the same answer the operator should get either way.
  def open(socket, issue_id) when is_binary(issue_id) and issue_id != "",
    do: do_open(socket, issue_id)

  def open(socket, _issue), do: socket

  defp do_open(socket, issue) do
    case Refine.open(issue) do
      {:ok, %{session: session, reopened?: reopened?}} ->
        _ = Sessions.request_open(session.id)
        put_flash(socket, :info, opened_message(reopened?))

      {:error, reason} ->
        put_flash(socket, :error, describe(reason))
    end
  end

  @doc """
  The Refine button.

  `id` is required and differs per surface (`task-refine`,
  `board-refine-<id>`), because the same issue can be on screen in both at
  once and a duplicate DOM id would make either untestable and the second
  un-clickable.
  """
  attr :id, :string, required: true

  attr :issue_id, :string,
    default: nil,
    doc: "sent with the event; nil means the page's own issue"

  attr :label, :string, default: "Refine"
  attr :size, :string, default: "sm"
  attr :variant, :string, default: "secondary"
  attr :class, :any, default: nil
  attr :rest, :global

  def refine_button(assigns) do
    ~H"""
    <ArbiterWeb.CoreComponents.Core.button
      id={@id}
      size={@size}
      variant={@variant}
      class={@class}
      phx-click="refine"
      phx-value-id={@issue_id}
      title="Open an agent session bound to this issue and shape it into a dispatchable ticket"
      {@rest}
    >
      <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-sparkles-mini" /></:icon>
      {@label}
    </ArbiterWeb.CoreComponents.Core.button>
    """
  end

  defp opened_message(true), do: "Reopened this issue's refine session in the dock."
  defp opened_message(false), do: "Launched a refine session for this issue — see the dock."

  defp describe(:not_refinable),
    do: "That issue is no longer in Backlog, so there is nothing to refine."

  defp describe(:no_workspace),
    do: "That issue belongs to no workspace, and a refine session has to be bound to one."

  defp describe(:issue_not_found), do: "That issue no longer exists."

  defp describe(%{__exception__: true} = error),
    do: "Could not open a refine session: #{Exception.message(error)}"

  defp describe(reason), do: "Could not open a refine session: #{inspect(reason)}"
end
