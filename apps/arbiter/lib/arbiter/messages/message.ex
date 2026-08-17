defmodule Arbiter.Messages.Message do
  @moduledoc """
  A single entry in the inter-agent message queue.

  One table holds several kinds, distinguished by `:kind`:

    * `:notification` — broadcast event, no specific recipient (`to_ref` nil).
      Worker completion, progress milestones, system events. Feeds the
      coordinator's live dashboard. Never "consumed" — `read_at`/`cleared_at`
      stay nil (the `cleared_at` scoping validation asserts this, rather than
      leaving it to convention).
    * `:mailbox` — targeted at a specific task (`to_ref`). Requires read
      acknowledgement (`mark_read`).
    * `:direction` — user-authored instruction sent from the LiveView to a
      running worker. A subtype of mailbox; distinguished for display.
    * `:flag` — worker-to-worker signal (e.g. Varek telling Soren the API
      shape changed). A subtype of mailbox.

  The remaining kinds are the **coordinator mailbox family** — addressed reports
  an worker (or the system) sends *up* to the coordinator (`to_ref
  "coordinator"`; the legacy `"admiral"` literal is still accepted during the
  retirement compat window — see `ref_variants/1`), surfaced by `arb inbox` and
  the prime briefing:

    * `:completion` — a directive finished successfully.
    * `:failure` — a directive failed (crash, non-zero exit, aborted run).
    * `:escalation` — needs the coordinator's attention/decision.
    * `:info` — a neutral FYI; the default for `arb msg`.

  `:mailbox`, `:direction`, `:flag`, `:completion`, `:failure`,
  `:escalation`, and `:info` together are the "mailbox family": addressed
  messages that show up in an inbox and are read-acknowledged. The
  `:directive_ref` they may carry links the message to the task it concerns
  (shown in brackets in `arb inbox`). See `mailbox_kinds/0`.

  ## Mailbox lifecycle (three durable states)

  A mailbox-family row carries two independent timestamps — `read_at` (seen)
  and `cleared_at` (addressed) — so "seen" and "still owes action" stop sharing
  one bit:

    * **unread** — `read_at IS NULL AND cleared_at IS NULL`: not yet seen. The
      pending queue (`inbox/2`); auto → read on any fetch that returns bodies.
    * **outstanding** — `read_at NOT NULL AND cleared_at IS NULL`: seen but
      still owes an action. *The triage queue* (`outstanding/2`). Reading no
      longer empties it, so reading escalations every morning is safe.
    * **cleared** — `cleared_at NOT NULL`: addressed. Set explicitly and
      *softly* (`clear_read/2`, `clear_all/2`, `mark_cleared/1`); the row is
      retained as the durable escalation record. Only `hard_purge/2` destroys.

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

  # The coordinator mailbox address. `"coordinator"` is the canonical wire
  # literal persisted on `to_ref`/`from_ref`; `"admiral"` is the legacy literal
  # accepted during the retirement compat window. A data migration rewrites
  # stored rows, but an in-flight old binary may still write `"admiral"`, so
  # readers dual-read both via `ref_variants/1`. Drop `@legacy_coordinator_ref`
  # (and the compat branch of `ref_variants/1`) once no old producer remains.
  @coordinator_ref "coordinator"
  @legacy_coordinator_ref "admiral"
  @coordinator_refs [@coordinator_ref, @legacy_coordinator_ref]

  sqlite do
    table "messages"
    repo Arbiter.Repo

    custom_indexes do
      # Pending query: "unread messages addressed to task X in workspace W"
      # (`read_at IS NULL`). Every dashboard render and every inbox fetch hits it.
      index [:workspace_id, :to_ref, :read_at]

      # Outstanding query: "read-but-uncleared messages addressed to X in W"
      # (`read_at NOT NULL AND cleared_at IS NULL`) — the triage queue, and now
      # the hot count on a table that grows without bound because clear is soft.
      # A second composite (rather than replacing the read_at one) keeps *both*
      # per-render figures index-covered; they share the (workspace_id, to_ref)
      # prefix so the cost is one extra index on a write path that is already
      # cheap relative to the read volume.
      index [:workspace_id, :to_ref, :cleared_at]
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

      change after_action(fn _changeset, message, _context ->
               Arbiter.Messages.WorktreeDelivery.maybe_deliver(message)
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

    update :mark_cleared do
      # Stamp cleared_at — the explicit, *soft* transition read → cleared. The
      # row is retained (this is the durable escalation record); only the
      # separately-named hard purge destroys. Idempotent, mirroring mark_read.
      # The kind-scoping validation below rejects clearing a :notification, so
      # this action can only ever move a mailbox-family row.
      accept []
      require_atomic? false
      change set_attribute(:cleared_at, &DateTime.utc_now/0)

      change after_action(fn _changeset, message, _context ->
               Arbiter.Messages.Message.broadcast_cleared(message.workspace_id)
               {:ok, message}
             end)
    end
  end

  validations do
    # cleared_at is a mailbox-family concept only. Notifications are never
    # consumed (their read_at stays nil forever); asserting it here — rather
    # than trusting every caller to filter on @mailbox_kinds — is the whole
    # point of this resource: one field must not silently pick up a second
    # meaning for a kind it was never meant to describe.
    validate fn changeset, _context ->
      kind = Ash.Changeset.get_attribute(changeset, :kind)
      cleared_at = Ash.Changeset.get_attribute(changeset, :cleared_at)

      if kind == :notification and not is_nil(cleared_at) do
        {:error, field: :cleared_at, message: "cannot be set on a :notification"}
      else
        :ok
      end
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
      description ~s(task_id, "coordinator", or "system". nil for anonymous events.)
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
      description "When a mailbox message was first seen (body read). nil = unread."
    end

    attribute :cleared_at, :utc_datetime_usec do
      public? true

      description "When a mailbox message was addressed (soft-cleared). nil = not cleared. Mailbox-family only."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # ---- introspection -------------------------------------------------------

  @doc "All valid kind atoms."
  def kinds, do: @kinds

  @doc "The mailbox-family kinds (addressed, read-acknowledged)."
  def mailbox_kinds, do: @mailbox_kinds

  @doc """
  The canonical coordinator mailbox literal (`"coordinator"`). Producers address
  reports *up* to the coordinator with this value.
  """
  def coordinator_ref, do: @coordinator_ref

  @doc """
  Every literal that addresses the coordinator mailbox: the canonical
  `"coordinator"` plus the legacy `"admiral"` still accepted during the
  retirement compat window. Readers filter on this set so a row written under
  either literal is found under either.
  """
  def coordinator_refs, do: @coordinator_refs

  @doc """
  Expand a `to_ref`/`from_ref` into the set of literals that address the same
  mailbox. Either coordinator literal expands to both variants (dual-read);
  every other ref matches only itself.
  """
  def ref_variants(ref) when ref in @coordinator_refs, do: @coordinator_refs
  def ref_variants(ref), do: [ref]

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

    if Map.get(message, :to_ref) in @coordinator_refs do
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

  @doc """
  Broadcast `{:mailbox_cleared, workspace_id}` on a workspace's message topic.

  Called by `mark_cleared`, `clear_read/2`, `clear_all/2`, and `hard_purge/2`
  after a state transition, so every open LiveView session refreshes its inbox
  panel without a manual page reload. Silent-on-failure, mirroring
  `broadcast_new/1`.
  """
  def broadcast_cleared(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      topic(workspace_id),
      {:mailbox_cleared, workspace_id}
    )

    :ok
  rescue
    e ->
      require Logger
      Logger.debug("Messages.Message.broadcast_cleared/1 swallowed: #{Exception.message(e)}")
      :ok
  end

  def broadcast_cleared(_workspace_id), do: :ok

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
  Mark a message cleared (stamps `cleared_at` — the soft "addressed" transition).
  Accepts a `%Message{}` or an id. Idempotent, mirroring `mark_read/1`. Rejected
  for `:notification` rows by the resource validation.
  """
  def mark_cleared(id) when is_binary(id) do
    with {:ok, message} <- Ash.get(__MODULE__, id) do
      mark_cleared(message)
    end
  end

  def mark_cleared(message), do: Ash.update(message, %{}, action: :mark_cleared)

  @doc """
  Pending (unread) mailbox-family messages addressed to `to_ref`, oldest first:
  `read_at IS NULL AND cleared_at IS NULL`. Pure read — does NOT mark them read
  (the caller decides, e.g. the REST layer). Pass `workspace_id:` to scope.

  A message soft-cleared while still unread (via `clear_all/2`) drops out here —
  it has been addressed, so it is neither pending nor outstanding.
  """
  def inbox(to_ref, opts \\ []) when is_binary(to_ref) do
    refs = ref_variants(to_ref)

    query =
      __MODULE__
      |> Ash.Query.filter(
        to_ref in ^refs and is_nil(read_at) and is_nil(cleared_at) and kind in ^@mailbox_kinds
      )
      |> Ash.Query.sort(inserted_at: :asc)

    query =
      case Keyword.get(opts, :workspace_id) do
        ws when is_binary(ws) -> Ash.Query.filter(query, workspace_id == ^ws)
        _ -> query
      end

    Ash.read!(query)
  end

  @doc """
  Outstanding mailbox-family messages addressed to `to_ref`, oldest first:
  `read_at NOT NULL AND cleared_at IS NULL`. This is *the queue* — items the
  coordinator has seen but that still owe an action. Reading no longer empties
  it (that only stamps `read_at`); an item leaves only when explicitly cleared.
  Pure read. Pass `workspace_id:` to scope.
  """
  def outstanding(to_ref, opts \\ []) when is_binary(to_ref) do
    refs = ref_variants(to_ref)

    query =
      __MODULE__
      |> Ash.Query.filter(
        to_ref in ^refs and not is_nil(read_at) and is_nil(cleared_at) and kind in ^@mailbox_kinds
      )
      |> Ash.Query.sort(inserted_at: :asc)

    query =
      case Keyword.get(opts, :workspace_id) do
        ws when is_binary(ws) -> Ash.Query.filter(query, workspace_id == ^ws)
        _ -> query
      end

    Ash.read!(query)
  end

  @doc """
  The most recent mailbox-family message addressed to `to_ref` whose `subject`
  is one of `subjects`, or `nil` when there is none (bd-brwx7w).

  This is the durable dedupe/backoff surface for repeated escalations. Two
  independent pollers (and the same poller across a restart) can each ask
  "has this exact page already gone out?" and get the same answer, because the
  state lives in the message table rather than in either poller's memory.

  `subjects` is a list so a caller can treat several near-identical subjects as
  one dedupe key (e.g. the two ways a missing approval is reported).

  Options:

    * `:workspace_id` — scope to a workspace.
    * `:directive_ref` — scope to the task the message concerns.
    * `:uncleared` — when `true`, consider only rows with `cleared_at IS NULL`
      (unread *or* outstanding); a cleared row has been addressed and no longer
      suppresses a repeat.

  Pure read.
  """
  @spec last_with_subject(String.t(), [String.t()], keyword()) :: struct() | nil
  def last_with_subject(to_ref, subjects, opts \\ [])

  def last_with_subject(_to_ref, [], _opts), do: nil

  def last_with_subject(to_ref, subjects, opts) when is_binary(to_ref) and is_list(subjects) do
    refs = ref_variants(to_ref)

    query =
      __MODULE__
      |> Ash.Query.filter(to_ref in ^refs and kind in ^@mailbox_kinds and subject in ^subjects)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)

    query =
      case Keyword.get(opts, :workspace_id) do
        ws when is_binary(ws) -> Ash.Query.filter(query, workspace_id == ^ws)
        _ -> query
      end

    query =
      case Keyword.get(opts, :directive_ref) do
        dr when is_binary(dr) -> Ash.Query.filter(query, directive_ref == ^dr)
        _ -> query
      end

    query =
      if Keyword.get(opts, :uncleared, false) do
        Ash.Query.filter(query, is_nil(cleared_at))
      else
        query
      end

    case Ash.read!(query) do
      [message | _] -> message
      [] -> nil
    end
  end

  @doc """
  Clear the outstanding tail of a mailbox: **soft-clear** (stamp `cleared_at`)
  every *read-but-uncleared* message addressed to `to_ref`. Pending (unread)
  mail is left untouched — you read it first, then clear. Rows are **retained**
  (this is the durable escalation record); nothing is destroyed here — see
  `hard_purge/2` for the only destructive path.

  Returns `{:ok, cleared, 0, remaining_unread}` where `cleared` is the number of
  rows transitioned to cleared and `remaining_unread` is the count of pending
  messages that still exist afterwards. (The 4-tuple shape and the middle
  `0` — unread-cleared — are preserved for the CLI/HTTP callers.) Pass
  `workspace_id:` to scope to one workspace.
  """
  def clear_read(to_ref, opts \\ []) when is_binary(to_ref) do
    refs = ref_variants(to_ref)

    outstanding_query =
      __MODULE__
      |> Ash.Query.filter(
        to_ref in ^refs and not is_nil(read_at) and is_nil(cleared_at) and kind in ^@mailbox_kinds
      )

    outstanding_query = scope_workspace(outstanding_query, opts)

    outstanding = Ash.read!(outstanding_query)
    Enum.each(outstanding, &mark_cleared/1)

    broadcast_workspaces(outstanding)

    remaining_unread = count_pending(refs, opts)

    {:ok, length(outstanding), 0, remaining_unread}
  end

  @doc """
  Clear every message (pending *and* outstanding) addressed to `to_ref` by
  **soft-clearing** (stamping `cleared_at`). Rows are retained — this is the
  "clear the lot" button, not a delete. Returns
  `{:ok, cleared_read, cleared_unread, 0}` split by prior read state
  (`remaining_unread` is always 0 — everything is cleared). Pass `workspace_id:`
  to scope to one workspace.
  """
  def clear_all(to_ref, opts \\ []) when is_binary(to_ref) do
    refs = ref_variants(to_ref)

    query =
      __MODULE__
      |> Ash.Query.filter(to_ref in ^refs and is_nil(cleared_at) and kind in ^@mailbox_kinds)

    query = scope_workspace(query, opts)

    to_clear = Ash.read!(query)
    read_count = Enum.count(to_clear, &(not is_nil(&1.read_at)))
    unread_count = Enum.count(to_clear, &is_nil(&1.read_at))

    Enum.each(to_clear, &mark_cleared/1)

    broadcast_workspaces(to_clear)

    {:ok, read_count, unread_count, 0}
  end

  @doc """
  Hard purge: the **only** path that destroys rows. Permanently deletes every
  *already-cleared* (`cleared_at NOT NULL`) message addressed to `to_ref` — the
  addressed history that soft-clear accumulates. Pending and outstanding mail
  are never touched, so genuine housekeeping cannot silently drop an
  unaddressed escalation. Deliberately not reachable from `arb inbox clear`.
  Returns `{:ok, purged}`. Pass `workspace_id:` to scope to one workspace.
  """
  def hard_purge(to_ref, opts \\ []) when is_binary(to_ref) do
    refs = ref_variants(to_ref)

    query =
      __MODULE__
      |> Ash.Query.filter(to_ref in ^refs and not is_nil(cleared_at) and kind in ^@mailbox_kinds)

    query = scope_workspace(query, opts)

    purged = Ash.read!(query)
    Enum.each(purged, &Ash.destroy!/1)

    broadcast_workspaces(purged)

    {:ok, length(purged)}
  end

  defp scope_workspace(query, opts) do
    case Keyword.get(opts, :workspace_id) do
      ws when is_binary(ws) -> Ash.Query.filter(query, workspace_id == ^ws)
      _ -> query
    end
  end

  defp count_pending(refs, opts) do
    __MODULE__
    |> Ash.Query.filter(
      to_ref in ^refs and is_nil(read_at) and is_nil(cleared_at) and kind in ^@mailbox_kinds
    )
    |> scope_workspace(opts)
    |> Ash.count!()
  end

  defp broadcast_workspaces(messages) do
    messages
    |> Enum.map(& &1.workspace_id)
    |> Enum.uniq()
    |> Enum.each(&broadcast_cleared/1)
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
