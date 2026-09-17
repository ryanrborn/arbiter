defmodule Arbiter.Messages.MessageReceipt do
  @moduledoc """
  One reader's view of one shared message (bd-8akewg).

  The coordinator mailbox is a **single shared queue**: every producer writes
  `to_ref: "coordinator"`, and every browser-hosted session plus the sessionless
  coordinator (CLI, dashboard drawer, a plain minted token) reads the same rows.
  Before this resource existed, "read" and "cleared" were one pair of timestamps
  *on the row*, so the first reader to poll consumed everybody else's mail.

  A receipt moves that state off the row and onto the (message, reader) pair:

    * `reader_ref` — `"coordinator"` for every sessionless reader (they
      deliberately share one identity, because the runbook mints a fresh token
      every cycle and per-token identity would fragment the operator's triage
      state), or `"session:<session_id>"` for a browser-hosted session. Built by
      `Arbiter.Messages.Message.coordinator_reader/0` and `session_reader/1`.
    * `read_at` / `cleared_at` — the same three-state lifecycle the row used to
      carry (unread → outstanding → cleared), now per reader.

  **No receipt at all is the unread state.** Readers are not enrolled and rows
  are not fanned out: a message with no receipt for you is mail you have not
  seen. That keeps a new session free of any write amplification, at the cost of
  needing an `inserted_at` floor so a session created today is not handed the
  whole archive — see the `:since` option on
  `Arbiter.Messages.Message.inbox/2`.

  The row's own `read_at`/`cleared_at` survive as the **global** signal: the
  task-mailbox path (a worker reading its own mail — exactly one reader, so
  receipts would be pure overhead) still uses them, the sessionless
  `"coordinator"` reader mirrors its writes onto them so the REST/CLI listing
  and `hard_purge/2` behave exactly as before, and escalation dedupe
  (`Message.last_with_subject/3` with `uncleared: true`) reads the row so that
  one session clearing *its* copy can never re-arm a repeat page.
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Messages,
    data_layer: AshSqlite.DataLayer

  require Ash.Query

  sqlite do
    table "message_receipts"
    repo Arbiter.Repo

    custom_indexes do
      # "what has this reader still not addressed" — the per-render query behind
      # a session's unread/outstanding counts.
      index [:reader_ref, :cleared_at]
    end
  end

  actions do
    defaults [:read, :destroy]

    # Both writers are upserts against the (message_id, reader_ref) identity:
    # marking read/cleared is idempotent, and two pollers for the same reader
    # must not race a duplicate row past the unique index. `upsert_fields` is
    # narrowed per action so stamping `read_at` cannot silently unset a
    # `cleared_at` the same reader already recorded.
    create :mark_read do
      primary? true
      accept [:message_id, :reader_ref]
      upsert? true
      upsert_identity :unique_message_reader
      upsert_fields [:read_at, :updated_at]
      change set_attribute(:read_at, &DateTime.utc_now/0)
    end

    create :mark_cleared do
      accept [:message_id, :reader_ref]
      upsert? true
      upsert_identity :unique_message_reader
      upsert_fields [:cleared_at, :updated_at]
      change set_attribute(:cleared_at, &DateTime.utc_now/0)
    end
  end

  identities do
    identity :unique_message_reader, [:message_id, :reader_ref]
  end

  attributes do
    uuid_primary_key :id

    attribute :message_id, :uuid do
      allow_nil? false
      public? true
      description "The shared message this receipt is about."
    end

    attribute :reader_ref, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description ~s(Reader identity: "coordinator", or "session:<session_id>".)
    end

    attribute :read_at, :utc_datetime_usec do
      public? true
      description "When this reader first saw the message. nil = unread for this reader."
    end

    attribute :cleared_at, :utc_datetime_usec do
      public? true
      description "When this reader addressed the message. nil = still owed."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # ---- helpers -------------------------------------------------------------

  @doc "Every receipt belonging to `reader_ref`."
  def for_reader(reader_ref) when is_binary(reader_ref) do
    __MODULE__
    |> Ash.Query.filter(reader_ref == ^reader_ref)
    |> Ash.read!()
  end

  @doc "Every receipt recorded against `message_id`, by any reader."
  def for_message(message_id) when is_binary(message_id) do
    __MODULE__
    |> Ash.Query.filter(message_id == ^message_id)
    |> Ash.read!()
  end

  @doc """
  Stamp `read_at` for `reader_ref` on `message_id`, creating the receipt if this
  is the reader's first contact with the message. Idempotent.
  """
  def mark_read(message_id, reader_ref) when is_binary(message_id) and is_binary(reader_ref) do
    Ash.create(__MODULE__, %{message_id: message_id, reader_ref: reader_ref}, action: :mark_read)
  end

  @doc """
  Stamp `cleared_at` for `reader_ref` on `message_id`. Creating the receipt
  outright (reader never read it) is the "clear the lot" case and leaves
  `read_at` nil, mirroring how the row-level `clear_all/2` records a
  cleared-while-unread message. Idempotent.
  """
  def mark_cleared(message_id, reader_ref) when is_binary(message_id) and is_binary(reader_ref) do
    Ash.create(__MODULE__, %{message_id: message_id, reader_ref: reader_ref},
      action: :mark_cleared
    )
  end

  @doc "Destroy every receipt for the given message ids (used by `hard_purge`)."
  def purge_for_messages([]), do: :ok

  def purge_for_messages(message_ids) when is_list(message_ids) do
    # Chunked rather than one wide `in`: a single SQLite expression tree past
    # ~1000 terms is rejected outright ("Expression tree is too large").
    message_ids
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      __MODULE__
      |> Ash.Query.filter(message_id in ^chunk)
      |> Ash.read!()
      |> Enum.each(&Ash.destroy!/1)
    end)
  end
end
