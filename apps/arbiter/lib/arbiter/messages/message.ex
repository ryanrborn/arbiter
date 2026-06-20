defmodule Arbiter.Messages.Message do
  @moduledoc """
  A single entry in the inter-agent message queue.

  One table holds several kinds, distinguished by `:kind`:

    * `:notification` — broadcast event, no specific recipient (`to_ref` nil).
      Worker completion, progress milestones, system events. Feeds the
      Admiral's live dashboard. Never "consumed" — `read_at` stays nil.
    * `:mailbox` — targeted at a specific task (`to_ref`). Requires read
      acknowledgement (`mark_read`).
    * `:direction` — user-authored instruction sent from the LiveView to a
      running worker. A subtype of mailbox; distinguished for display.
    * `:flag` — worker-to-worker signal (e.g. Varek telling Soren the API
      shape changed). A subtype of mailbox.

  The remaining kinds are the **Admiral mailbox family** — addressed reports
  an worker (or the system) sends *up* to the Admiral (`to_ref "admiral"`),
  surfaced by `arb inbox` and the prime briefing:

    * `:completion` — a directive finished successfully.
    * `:failure` — a directive failed (crash, non-zero exit, aborted run).
    * `:escalation` — needs the Admiral's attention/decision.
    * `:info` — a neutral FYI; the default for `arb msg`.

  `:mailbox`, `:direction`, `:flag`, `:completion`, `:failure`,
  `:escalation`, and `:info` together are the "mailbox family": addressed
  messages that show up in an inbox and are read-acknowledged. The
  `:directive_ref` they may carry links the message to the task it concerns
  (shown in brackets in `arb inbox`). See `mailbox_kinds/0`.

  ## PubSub

  On create, the message is broadcast on `"messages:<workspace_id>"` as
  `{:new_message, message}`. The dashboard subscribes per workspace; the
  notification feed and mailbox views update in real time.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Messages,
    data_layer: AshSqlite.DataLayer

  require Ash.Query

  @kinds ~w(notification mailbox direction flag completion failure escalation info)a
  @mailbox_kinds ~w(mailbox direction flag completion failure escalation info)a

  sqlite do
    table "messages"
    repo Arbiter.Repo

    custom_indexes do
      # Mailbox queries: "unread messages addressed to task X in workspace W".
      index [:workspace_id, :to_ref, :read_at]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:kind, :from_ref, :to_ref, :workspace_id, :subject, :body, :directive_ref]

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

      change after_action(fn _changeset, message, _context ->
               Arbiter.Messages.Message.broadcast_read(message)
               {:ok, message}
             end)
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
      description ~s(task_id, "admiral", or "system". nil for anonymous events.)
    end

    attribute :to_ref, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Recipient task_id. nil = broadcast (notifications)."
    end

    attribute :workspace_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description "Workspace scope. Not a foreign key — messages outlive task churn."
    end

    attribute :subject, :string do
      public? true
      constraints max_length: 500, trim?: true
      description ~s(Short label, e.g. "bd-7wyihw complete".)
    end

    attribute :directive_ref, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "The directive task_id this message concerns. Shown in brackets by arb inbox. nil = not about a specific directive."
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
  `Arbiter.Worker.broadcast_lifecycle/2`.
  """
  def broadcast_new(%{workspace_id: ws_id} = message) when is_binary(ws_id) do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, topic(ws_id), {:new_message, message})

    if Map.get(message, :to_ref) == "admiral" do
      Arbiter.Events.broadcast(ws_id, "inbox", %{
        task_id: Map.get(message, :directive_ref),
        from_ref: Map.get(message, :from_ref),
        subject: Map.get(message, :subject),
        kind: to_string(Map.get(message, :kind) || "")
      })
    end

    :ok
  rescue
    e ->
      require Logger
      Logger.debug("Messages.Message.broadcast_new/1 swallowed: #{Exception.message(e)}")
      :ok
  end

  def broadcast_new(_message), do: :ok

  @doc """
  Broadcast `{:message_read, message}` on the message's workspace topic.

  Called by the `mark_read` action so that all paths that read/clear a message
  (CLI, MCP, HTTP API, another dashboard session) push a live update. Silent-
  on-failure, mirroring `broadcast_new/1`.
  """
  def broadcast_read(%{workspace_id: ws_id} = message) when is_binary(ws_id) do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, topic(ws_id), {:message_read, message})
    :ok
  rescue
    e ->
      require Logger
      Logger.debug("Messages.Message.broadcast_read/1 swallowed: #{Exception.message(e)}")
      :ok
  end

  def broadcast_read(_message), do: :ok

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
  Drain the read tail of a mailbox: destroy every *already-read* message
  addressed to `to_ref`. Unread mail is left untouched — you read it first,
  then clear. Returns the number of messages destroyed. Pass `workspace_id:`
  to scope to one workspace.

  Mirrors the `DELETE /api/messages` (`:clear`) contract; the REST layer and
  the dashboard's Admiral mailbox both route through here.
  """
  def clear_read(to_ref, opts \\ []) when is_binary(to_ref) do
    query =
      __MODULE__
      |> Ash.Query.filter(to_ref == ^to_ref and not is_nil(read_at))

    query =
      case Keyword.get(opts, :workspace_id) do
        ws when is_binary(ws) -> Ash.Query.filter(query, workspace_id == ^ws)
        _ -> query
      end

    read = Ash.read!(query)
    Enum.each(read, &Ash.destroy!/1)
    length(read)
  end

  @doc """
  The full inter-agent thread about a directive (task), oldest first: every
  mailbox-family message whose `directive_ref` is `ref`, regardless of direction
  or read state.

  This is the durable implementer↔reviewer transcript the ReviewGate's
  revise-and-rediscuss loop builds (each reviewer finding and implementer
  response is a persisted `:flag` row), so it survives the workers that wrote it
  and escalation can reconstruct the ordered argument for Darth Gnosis. Pass
  `workspace_id:` to scope to one workspace.
  """
  def thread(ref, opts \\ []) when is_binary(ref) do
    query =
      __MODULE__
      |> Ash.Query.filter(directive_ref == ^ref and kind in ^@mailbox_kinds)
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

  @doc """
  The `limit` most recent `:escalation` messages, newest first — read *and*
  unread alike (unlike `inbox/2`, which is unread-only). Escalations are raised
  solely by the ReviewGate review gate on a non-approve verdict
  (`Arbiter.Worker` reject/inconclusive path), so this is the durable record of
  rejected reviews, carrying the reviewer's findings in `:body`. Powers the
  dashboard's ReviewGate view. Pass `workspace_id:` to scope to one workspace.
  """
  def recent_escalations(limit \\ 10, opts \\ []) do
    query =
      __MODULE__
      |> Ash.Query.filter(kind == :escalation)
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
