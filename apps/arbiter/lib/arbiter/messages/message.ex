defmodule Arbiter.Messages.Message do
  @moduledoc """
  A single entry in the inter-agent message queue.

  One table holds four kinds, distinguished by `:kind`:

    * `:notification` — broadcast event, no specific recipient (`to_ref` nil).
      Acolyte completion, progress milestones, system events. Feeds the
      Admiral's live dashboard. Never "consumed" — `read_at` stays nil.
    * `:mailbox` — targeted at a specific bead (`to_ref`). Requires read
      acknowledgement (`mark_read`).
    * `:direction` — user-authored instruction sent from the LiveView to a
      running acolyte. A subtype of mailbox; distinguished for display.
    * `:flag` — acolyte-to-acolyte signal (e.g. Varek telling Soren the API
      shape changed). A subtype of mailbox.

  `:mailbox`, `:direction`, and `:flag` together are the "mailbox family":
  addressed messages that show up in `arb inbox <bead-id>` and are marked
  read on fetch. See `mailbox_kinds/0`.

  ## PubSub

  On create, the message is broadcast on `"messages:<workspace_id>"` as
  `{:new_message, message}`. The dashboard subscribes per workspace; the
  notification feed and mailbox views update in real time.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Messages,
    data_layer: AshPostgres.DataLayer

  require Ash.Query

  @kinds ~w(notification mailbox direction flag)a
  @mailbox_kinds ~w(mailbox direction flag)a

  postgres do
    table "messages"
    repo Arbiter.Repo

    custom_indexes do
      # Mailbox queries: "unread messages addressed to bead X in workspace W".
      index [:workspace_id, :to_ref, :read_at]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:kind, :from_ref, :to_ref, :workspace_id, :subject, :body]

      change after_action(fn _changeset, message, _context ->
               Arbiter.Messages.Message.broadcast_new(message)
               {:ok, message}
             end)
    end

    update :mark_read do
      # No attributes accepted from the caller — just stamps read_at. Idempotent:
      # re-running on an already-read message simply re-stamps the time.
      accept []
      require_atomic? false
      change set_attribute(:read_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: @kinds
    end

    attribute :from_ref, :string do
      public? true
      constraints max_length: 255, trim?: true
      description ~s(bead_id, "admiral", or "system". nil for anonymous events.)
    end

    attribute :to_ref, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Recipient bead_id. nil = broadcast (notifications)."
    end

    attribute :workspace_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description "Workspace scope. Not a foreign key — messages outlive bead churn."
    end

    attribute :subject, :string do
      public? true
      constraints max_length: 500, trim?: true
      description ~s(Short label, e.g. "bd-7wyihw complete".)
    end

    attribute :body, :string do
      allow_nil? false
      public? true
      default ""
      description "The message content (Markdown / plain text)."
    end

    attribute :read_at, :utc_datetime_usec do
      public? true
      description "When a mailbox message was acknowledged. nil = unread."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # ---- introspection -------------------------------------------------------

  @doc "All valid kind atoms."
  def kinds, do: @kinds

  @doc "The mailbox-family kinds (addressed, read-acknowledged)."
  def mailbox_kinds, do: @mailbox_kinds

  # ---- PubSub --------------------------------------------------------------

  @doc false
  def topic(workspace_id) when is_binary(workspace_id), do: "messages:" <> workspace_id

  @doc """
  Broadcast `{:new_message, message}` on the message's workspace topic.

  Silent-on-failure (the PubSub registry may be down in tests) but leaves a
  debug breadcrumb so a payload bug isn't invisible — mirrors the contract of
  `Arbiter.Polecat.broadcast_lifecycle/2`.
  """
  def broadcast_new(%{workspace_id: ws_id} = message) when is_binary(ws_id) do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, topic(ws_id), {:new_message, message})
    :ok
  rescue
    e ->
      require Logger
      Logger.debug("Messages.Message.broadcast_new/1 swallowed: #{Exception.message(e)}")
      :ok
  end

  def broadcast_new(_message), do: :ok

  # ---- convenience helpers -------------------------------------------------

  @doc """
  Record a `:notification` (broadcast event). Required keys: `:workspace_id`,
  `:body`. Optional: `:from_ref`, `:subject`. Returns `{:ok, message}` /
  `{:error, _}`.
  """
  def notify(attrs) when is_map(attrs) do
    attrs
    |> Map.put(:kind, :notification)
    |> create()
  end

  @doc """
  Send an addressed mailbox-family message. `:kind` defaults to `:mailbox`;
  pass `:direction` or `:flag` for the subtypes. Required keys: `:workspace_id`,
  `:to_ref`, `:body`.
  """
  def send_mail(attrs) when is_map(attrs) do
    attrs
    |> Map.put_new(:kind, :mailbox)
    |> create()
  end

  defp create(attrs), do: Ash.create(__MODULE__, attrs)

  @doc """
  Mark a message read (stamps `read_at`). Accepts a `%Message{}` or an id.
  """
  def mark_read(id) when is_binary(id) do
    with {:ok, message} <- Ash.get(__MODULE__, id) do
      mark_read(message)
    end
  end

  def mark_read(message), do: Ash.update(message, %{}, action: :mark_read)

  @doc """
  Unread mailbox-family messages addressed to `to_ref`, oldest first. Pure
  read — does NOT mark them read (the caller decides, e.g. the REST layer).
  Pass `workspace_id:` to scope.
  """
  def inbox(to_ref, opts \\ []) when is_binary(to_ref) do
    query =
      __MODULE__
      |> Ash.Query.filter(to_ref == ^to_ref and is_nil(read_at) and kind in ^@mailbox_kinds)
      |> Ash.Query.sort(inserted_at: :asc)

    query =
      case Keyword.get(opts, :workspace_id) do
        ws when is_binary(ws) -> Ash.Query.filter(query, workspace_id == ^ws)
        _ -> query
      end

    Ash.read!(query)
  end

  @doc """
  The `limit` most recent `:notification` messages, newest first. Pass
  `workspace_id:` to scope to one workspace.
  """
  def recent_notifications(limit \\ 20, opts \\ []) do
    query =
      __MODULE__
      |> Ash.Query.filter(kind == :notification)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(limit)

    query =
      case Keyword.get(opts, :workspace_id) do
        ws when is_binary(ws) -> Ash.Query.filter(query, workspace_id == ^ws)
        _ -> query
      end

    Ash.read!(query)
  end
end
