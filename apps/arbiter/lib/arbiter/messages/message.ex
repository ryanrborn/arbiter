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
  `:task_ref` they may carry links the message to the task it concerns (shown
  in brackets in `arb inbox`; `:directive_ref` is the deprecated legacy alias
  during the bd-58vtjk compat window). See `mailbox_kinds/0`.

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

  ## Per-reader read state (bd-8akewg)

  Those three states are *per reader* on the coordinator mailbox, which is a
  single shared queue: producers write one row addressed to `"coordinator"` and
  every browser-hosted session plus the sessionless coordinator reads it. When
  read/cleared were only the two row timestamps above, the first reader to poll
  consumed everybody else's mail.

  So `inbox/2`, `outstanding/2`, `mark_read/2`, `clear_read/2` and `clear_all/2`
  take a `reader:` option, and the state for that reader lives in
  `Arbiter.Messages.MessageReceipt` — no receipt is the unread state. Two rules
  make the rest of the system hold still:

    * A **session** reader (`session_reader/1`) writes only its own receipt. The
      row's `cleared_at` stays nil, so one session triaging its copy cannot
      re-arm an escalation the `last_with_subject/3` dedupe is suppressing.
    * The **sessionless coordinator** reader (`coordinator_reader/0` — the CLI,
      the dashboard drawer, a plain minted token) mirrors its writes onto the
      row *and* reads through it, so the REST listing, `hard_purge/2` and that
      same dedupe behave exactly as they did.

  Omitting `reader:` keeps the original row-level semantics, which is what a
  task mailbox wants: it has exactly one reader.

  A session reader with no receipts is, by definition, unread on *everything*,
  so its unread view is bounded (`unread_floor/2`): everything since the
  session started, **plus** every row that is still globally uncleared. The
  second half is what matters — an escalation raised before the session was
  launched is exactly what that session is usually launched to deal with, and
  the `last_with_subject/3` dedupe guarantees it is never re-raised. Only the
  resolved archive is withheld.

  ## PubSub

  On create, the message is broadcast on `"messages:<workspace_id>"` as
  `{:new_message, message}`. The dashboard subscribes per workspace; the
  notification feed and mailbox views update in real time.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Messages,
    data_layer: AshSqlite.DataLayer

  alias Arbiter.Messages.MessageReceipt

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

  # bd-8akewg: the *reader* identity every sessionless coordinator shares — the
  # CLI, the dashboard drawer, and any plain `arb mcp token mint` token. It is
  # deliberately one identity rather than one per token: the runbook mints a
  # fresh token every cycle, so per-token identity would scatter the operator's
  # triage state across throwaway readers. A browser-hosted session gets
  # `session_reader/1` instead. Distinct from `@coordinator_ref`, which is the
  # *address* rows are sent to; they share a literal only by coincidence.
  @coordinator_reader "coordinator"

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

    # bd-cpt2ej: everything addressed to (`to_ref`) *or* about (`task_ref`) one
    # task, newest first — the task detail page's MESSAGES panel. A named read
    # action rather than another hand-rolled query so the filter lives on the
    # resource and the LiveView goes through the domain like every other
    # caller. Deliberately unfiltered by kind: "about this task" is the whole
    # predicate, and a caller that wants only the mailbox family already has
    # `thread/2`. Pure read — nothing here stamps `read_at`/`cleared_at`.
    read :for_task do
      argument :ref, :string, allow_nil?: false

      argument :workspace_id, :string do
        description "Optional workspace scope; nil means every workspace."
      end

      filter expr(
               (to_ref == ^arg(:ref) or task_ref == ^arg(:ref)) and
                 (is_nil(^arg(:workspace_id)) or workspace_id == ^arg(:workspace_id))
             )

      prepare build(sort: [inserted_at: :desc])
    end

    create :create do
      primary? true

      accept [
        :kind,
        :from_ref,
        :to_ref,
        :workspace_id,
        :subject,
        :body,
        :task_ref,
        :directive_ref
      ]

      # bd-58vtjk: `task_ref` is the canonical field; `directive_ref` is the
      # deprecated legacy alias (old fleet vernacular for "task"). Dual-write
      # both so a row is findable under either name during the compat window,
      # regardless of which one the caller supplied. task_ref wins when both
      # are given and disagree.
      change fn changeset, _context ->
        task_ref = Ash.Changeset.get_attribute(changeset, :task_ref)
        directive_ref = Ash.Changeset.get_attribute(changeset, :directive_ref)
        canonical = task_ref || directive_ref

        changeset
        |> Ash.Changeset.force_change_attribute(:task_ref, canonical)
        |> Ash.Changeset.force_change_attribute(:directive_ref, canonical)
      end

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

    attribute :task_ref, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "The task_id this message concerns. Shown in brackets by arb inbox. nil = not about a specific task."
    end

    # bd-58vtjk: legacy alias for `task_ref`, kept for the retirement compat
    # window. "directive" here is old fleet vernacular for "task/issue" — it
    # predates, and is unrelated to, the Graph/Conductor `directive` concept
    # (`graph_add_directive` etc., which uses `issue_id`). Dual-written by the
    # `:create` action's change so a row written under either name is found
    # under either; readers should prefer `task_ref/1`. Drop this attribute
    # (and the compat branches in :create and `task_ref/1`) once no old
    # producer remains.
    attribute :directive_ref, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "Deprecated legacy alias for task_ref. nil = not about a specific task."
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

  relationships do
    # bd-8akewg: per-reader read state. Declared so the per-reader queries can
    # push `exists(receipts, …)` down into SQL as a subquery rather than
    # loading a reader's whole receipt history into the BEAM on every poll.
    has_many :receipts, Arbiter.Messages.MessageReceipt do
      destination_attribute :message_id
      public? true
    end
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

  @doc """
  The reader identity every **sessionless** coordinator shares (bd-8akewg): the
  CLI (`arb inbox`), the dashboard drawer, and any plain `arb mcp token mint`
  token. One identity, not one per token — the runbook mints a fresh token each
  cycle, so per-token identity would scatter the operator's triage state.

  This reader's reads and clears are additionally **mirrored onto the message
  row** (`read_at`/`cleared_at`), which is what keeps the REST `unread=true`
  listing, `hard_purge/2`, and the `last_with_subject/3` dedupe behaving exactly
  as they did before per-reader state existed. Session readers never touch the
  row, so one session clearing its copy cannot re-arm a repeat escalation.
  """
  def coordinator_reader, do: @coordinator_reader

  @doc """
  The reader identity of a browser-hosted session: `"session:<session_id>"`.
  `session_id` is the `Arbiter.Sessions.Session` row id, the same claim
  `Arbiter.MCP.Scope.mint_session/2` puts on the session's MCP token.
  """
  def session_reader(session_id) when is_binary(session_id) and session_id != "",
    do: "session:" <> session_id

  @doc """
  True when `reader_ref` is the shared sessionless coordinator reader — the one
  whose state is mirrored onto the message row. See `coordinator_reader/0`.
  """
  def sessionless_reader?(reader_ref), do: reader_ref == @coordinator_reader

  @doc "Every per-reader receipt recorded against `message_id`."
  def receipts_for_message(message_id) when is_binary(message_id),
    do: Arbiter.Messages.MessageReceipt.for_message(message_id)

  @doc """
  Narrow an `Ash.Query` on this resource to one lifecycle `state` (`:unread` or
  `:outstanding`) as seen by `reader_ref` — or, when `reader_ref` is `nil`, by
  the row itself (the pre-bd-8akewg semantics).

  Exposed for callers that build their own query and cannot go through
  `inbox/2` / `outstanding/2` — the REST `GET /api/messages` filter endpoint,
  which layers kind/from_ref/limit on top of the same predicate.
  """
  def for_reader(query, reader_ref, :unread), do: unread_filter(query, reader_ref)
  def for_reader(query, reader_ref, :outstanding), do: outstanding_filter(query, reader_ref)

  @doc """
  The preferred task reference for a message: `task_ref` if set, else the
  legacy `directive_ref` alias. Both are dual-written by `:create`, so this
  only differs for rows written before bd-58vtjk shipped.
  """
  def task_ref(%{task_ref: ref}) when is_binary(ref), do: ref
  def task_ref(%{directive_ref: ref}), do: ref
  def task_ref(_), do: nil

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
        task_id: task_ref(message),
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
  def mark_read(message_or_id, opts \\ [])

  def mark_read(id, opts) when is_binary(id) do
    with {:ok, message} <- Ash.get(__MODULE__, id) do
      mark_read(message, opts)
    end
  end

  def mark_read(message, opts) do
    case Keyword.get(opts, :reader) do
      nil ->
        Ash.update(message, %{}, action: :mark_read)

      reader when is_binary(reader) ->
        {:ok, _receipt} = MessageReceipt.mark_read(message.id, reader)

        if sessionless_reader?(reader) do
          Ash.update(message, %{}, action: :mark_read)
        else
          broadcast_read(message)
          {:ok, message}
        end
    end
  end

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
      |> Ash.Query.filter(to_ref in ^refs and kind in ^@mailbox_kinds)
      |> Ash.Query.sort(inserted_at: :asc)
      |> unread_filter(Keyword.get(opts, :reader))
      |> scope_workspace(opts)

    Ash.read!(query)
  end

  # Unread, row-level: the pre-bd-8akewg semantics, still what a *task* mailbox
  # wants (exactly one reader — the worker — so receipts would be pure
  # overhead) and what `to_ref`-agnostic callers get when they name no reader.
  defp unread_filter(query, nil) do
    Ash.Query.filter(query, is_nil(read_at) and is_nil(cleared_at))
  end

  # Unread, per reader: *no receipt at all* is the unread state, so this is a
  # `NOT EXISTS` subquery rather than a load-and-reject in the BEAM — the
  # coordinator mailbox keeps every row it has ever received (clear is soft),
  # and a reader's receipt history grows with it.
  defp unread_filter(query, reader) when is_binary(reader) do
    if sessionless_reader?(reader) do
      # The sessionless coordinator reader mirrors every read/clear onto the row
      # (see `coordinator_reader/0`), so its receipt view and the row view are
      # the same set by construction — and the row predicate is covered by the
      # `(workspace_id, to_ref, read_at)` index the drawer renders through on
      # every page load. Reading it through the subquery would be correct and
      # needlessly slower.
      unread_filter(query, nil)
    else
      query
      |> Ash.Query.filter(
        not exists(
          receipts,
          reader_ref == ^reader and (not is_nil(read_at) or not is_nil(cleared_at))
        )
      )
      |> unread_floor(reader_floor(reader))
    end
  end

  # bd-8akewg: the bound on a session reader's unread view. With no receipts a
  # reader is unread on *everything*, and handing a session created today the
  # whole coordinator archive is not a mailbox.
  #
  # The bound is a union, not a cutoff: everything since the session started,
  # **or** still globally uncleared. Anything the operator has not resolved is
  # live mail no matter when it was raised — a session launched at 09:05 to
  # deal with a 09:00 escalation has to be able to see it, and since a session
  # clear never stamps the row, `last_with_subject/3` would otherwise suppress
  # the repeat forever. What drops out is only the resolved archive.
  #
  # Derived from the reader ref here, in one place, so `inbox/2` and the
  # `for_reader/3` query filter the REST endpoint (and through it `arb inbox
  # --session <id>`) builds on cannot drift apart.
  defp unread_floor(query, %DateTime{} = since),
    do: Ash.Query.filter(query, is_nil(cleared_at) or inserted_at >= ^since)

  # No session row behind the ref (hard-deleted, or a synthetic reader): no
  # floor at all. Degenerate, and showing too much mail beats swallowing an
  # escalation.
  defp unread_floor(query, _no_floor), do: query

  defp reader_floor("session:" <> session_id) when session_id != "" do
    case Ash.get(Arbiter.Sessions.Session, session_id) do
      {:ok, %{started_at: %DateTime{} = started_at}} -> started_at
      _ -> nil
    end
  rescue
    # A ref that is not a real session id at all (Ash raises on an id it cannot
    # cast) reads as "no floor" rather than taking the caller's query down.
    _ -> nil
  end

  defp reader_floor(_reader), do: nil

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
      |> Ash.Query.filter(to_ref in ^refs and kind in ^@mailbox_kinds)
      |> Ash.Query.sort(inserted_at: :asc)
      |> outstanding_filter(Keyword.get(opts, :reader))
      |> scope_workspace(opts)

    Ash.read!(query)
  end

  defp outstanding_filter(query, nil) do
    Ash.Query.filter(query, not is_nil(read_at) and is_nil(cleared_at))
  end

  # Per reader, outstanding needs a receipt to exist — no `:since` floor is
  # needed here, because a reader can only be outstanding on mail it has
  # already read.
  defp outstanding_filter(query, reader) when is_binary(reader) do
    if sessionless_reader?(reader) do
      outstanding_filter(query, nil)
    else
      Ash.Query.filter(
        query,
        exists(receipts, reader_ref == ^reader and not is_nil(read_at) and is_nil(cleared_at))
      )
    end
  end

  # "Not yet addressed by this reader" — the predicate behind a targeted clear.
  # Unlike `outstanding`, an unread message counts: clearing a task's thread
  # sweeps mail the reader never opened, exactly as `clear_all/2` does.
  defp uncleared_filter(query, nil), do: Ash.Query.filter(query, is_nil(cleared_at))

  defp uncleared_filter(query, reader) when is_binary(reader) do
    if sessionless_reader?(reader) do
      uncleared_filter(query, nil)
    else
      Ash.Query.filter(
        query,
        not exists(receipts, reader_ref == ^reader and not is_nil(cleared_at))
      )
    end
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
    * `:task_ref` — scope to the task the message concerns.
    * `:uncleared` — when `true`, consider only rows with `cleared_at IS NULL`
      (unread *or* outstanding); a cleared row has been addressed and no longer
      suppresses a repeat.

  Pure read.
  """
  @spec last_with_subject(String.t(), [String.t()], keyword()) :: struct() | nil
  def last_with_subject(to_ref, subjects, opts \\ [])

  def last_with_subject(_to_ref, [], _opts), do: nil

  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
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
      case Keyword.get(opts, :task_ref) do
        tr when is_binary(tr) -> Ash.Query.filter(query, task_ref == ^tr)
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
    reader = Keyword.get(opts, :reader)
    outstanding = outstanding(to_ref, opts)

    Enum.each(outstanding, &clear_one(&1, reader))
    broadcast_workspaces(outstanding)

    remaining_unread = length(inbox(to_ref, opts))

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
    reader = Keyword.get(opts, :reader)
    pending = inbox(to_ref, opts)
    outstanding = outstanding(to_ref, opts)
    to_clear = outstanding ++ pending

    Enum.each(to_clear, &clear_one(&1, reader))
    broadcast_workspaces(to_clear)

    {:ok, length(outstanding), length(pending), 0}
  end

  # The one place the clear transition branches on reader identity. A session
  # writes only its own receipt: the row's `cleared_at` stays nil, so the
  # `last_with_subject/3` dedupe keeps suppressing a repeat page that one
  # session happened to triage away. The sessionless coordinator reader — the
  # operator — also stamps the row, which is the global "resolved" signal
  # `hard_purge/2` and that same dedupe have always read.
  defp clear_one(message, nil), do: mark_cleared(message)

  defp clear_one(message, reader) when is_binary(reader) do
    {:ok, _receipt} = MessageReceipt.mark_cleared(message.id, reader)
    if sessionless_reader?(reader), do: mark_cleared(message), else: {:ok, message}
  end

  @doc """
  Soft-clear specific messages by id (stamps `cleared_at`; idempotent; rows
  retained — the same transition as `mark_cleared/1`, batched). Resolves each
  id directly with `Ash.get/2`, **regardless of workspace**: an id is already
  unambiguous, so there is nothing to scope it against (bd-95pse9 — a
  workspace-scoped lookup here is exactly the trap that made `coordinator_inbox`
  silently return `count: 0` when the caller omitted `workspace`).

  Returns `{:ok, cleared, not_found}` where `cleared` is the list of updated
  messages and `not_found` is the subset of `ids` that matched no row (or
  matched a row `mark_cleared/1` refuses, e.g. a `:notification`).

  Pass `reader:` to clear only that reader's view (bd-8akewg) — a session
  writes its own receipt and leaves the shared row, and therefore every other
  reader and the escalation dedupe, untouched.
  """
  def clear_ids(ids, opts \\ []) when is_list(ids) do
    reader = Keyword.get(opts, :reader)

    {cleared, not_found} =
      Enum.reduce(ids, {[], []}, fn id, {cleared_acc, missing_acc} ->
        case clear_id(id, reader) do
          {:ok, message} -> {[message | cleared_acc], missing_acc}
          {:error, _} -> {cleared_acc, [id | missing_acc]}
        end
      end)

    cleared = Enum.reverse(cleared)
    broadcast_workspaces(cleared)

    {:ok, cleared, Enum.reverse(not_found)}
  end

  defp clear_id(id, nil), do: mark_cleared(id)

  # Per reader, the row is not the source of truth, so the id has to resolve to
  # a real mailbox-family row before a receipt is written — otherwise a bad id
  # (or a `:notification`, which `mark_cleared/1` refuses outright) would be
  # silently recorded as cleared rather than reported in `not_found`.
  defp clear_id(id, reader) when is_binary(reader) do
    with {:ok, message} <- Ash.get(__MODULE__, id),
         true <- message.kind in @mailbox_kinds do
      clear_one(message, reader)
    else
      false -> {:error, :not_clearable}
      {:error, _} = err -> err
    end
  end

  @doc """
  Soft-clear every coordinator message concerning `task_ref` — every
  mailbox-family row addressed to the coordinator (`to_ref` in
  `coordinator_refs/0`) whose `task_ref` matches, still outstanding
  (`cleared_at IS NULL`). The targeted counterpart to `clear_read/2` /
  `clear_all/2`: clearing one task's escalation thread (e.g. once it closes)
  without sweeping the rest of the coordinator's mailbox. Rows are retained
  (soft). Idempotent — a second call finds nothing left to clear. Pass
  `workspace_id:` to scope to one workspace.

  Returns `{:ok, cleared}`, the list of updated messages (`[]` when nothing
  was outstanding for the task).

  Pass `reader:` to clear only that reader's view (bd-8akewg); "still
  outstanding" is then read per reader too, so the call stays idempotent for
  that reader without depending on the shared row.
  """
  def clear_by_task(task_ref, opts \\ []) when is_binary(task_ref) do
    reader = Keyword.get(opts, :reader)

    query =
      __MODULE__
      |> Ash.Query.filter(
        task_ref == ^task_ref and to_ref in ^@coordinator_refs and kind in ^@mailbox_kinds
      )
      |> uncleared_filter(reader)

    query = scope_workspace(query, opts)

    to_clear = Ash.read!(query)
    Enum.each(to_clear, &clear_one(&1, reader))

    broadcast_workspaces(to_clear)

    {:ok, to_clear}
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
    # Receipts first: there is no FK cascade (see the migration's note), so the
    # per-reader rows would otherwise outlive the message they describe.
    MessageReceipt.purge_for_messages(Enum.map(purged, & &1.id))
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

  defp broadcast_workspaces(messages) do
    messages
    |> Enum.map(& &1.workspace_id)
    |> Enum.uniq()
    |> Enum.each(&broadcast_cleared/1)
  end

  @doc """
  The full inter-agent thread about a task, oldest first: every mailbox-family
  message whose `task_ref` is `ref`, regardless of direction or read state.

  This is the durable implementer↔reviewer transcript the ReviewGate's
  revise-and-rediscuss loop builds (each reviewer finding and implementer
  response is a persisted `:flag` row), so it survives the workers that wrote it
  and escalation can reconstruct the ordered argument for Darth Gnosis. Pass
  `workspace_id:` to scope to one workspace.
  """
  def thread(ref, opts \\ []) when is_binary(ref) do
    query =
      __MODULE__
      |> Ash.Query.filter(task_ref == ^ref and kind in ^@mailbox_kinds)
      |> Ash.Query.sort(inserted_at: :asc)

    query =
      case Keyword.get(opts, :workspace_id) do
        ws when is_binary(ws) -> Ash.Query.filter(query, workspace_id == ^ws)
        _ -> query
      end

    Ash.read!(query)
  end

  @doc """
  Every message addressed to (`to_ref`) or about (`task_ref`) `ref`, newest
  first — the union `thread/2` does not cover, since a direction sent *to* a
  task carries no `task_ref` of its own.

  Reads through the `:for_task` action. Pure read: viewing a task's messages
  never stamps `read_at`/`cleared_at`. Options: `workspace_id:` to scope to one
  workspace, `limit:` to cap the rows returned.
  """
  def for_task(ref, opts \\ []) when is_binary(ref) do
    query =
      __MODULE__
      |> Ash.Query.for_read(:for_task, %{
        ref: ref,
        workspace_id: Keyword.get(opts, :workspace_id)
      })

    query =
      case Keyword.get(opts, :limit) do
        n when is_integer(n) and n > 0 -> Ash.Query.limit(query, n)
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
