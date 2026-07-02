defmodule Arbiter.Trackers.Tracker do
  @moduledoc """
  Behaviour for external issue-tracker adapters.

  An adapter implements this for one tracker backend (`Jira`, `Linear`,
  `GitHub`, or the trivial `None` stand-in). The `Arbiter.Trackers` helper
  resolves which adapter to use for a given task by reading
  `issue.tracker_type`.

  ## Callback semantics

    * `fetch/1` — pull the canonical record from the tracker. Shape is
      tracker-specific (a Jira issue map, a Linear node, etc.); callers should
      treat the result as opaque and use other callbacks to act on it.
    * `transition/2` — move the external item to a target status. The status
      atom uses the task vocabulary (`:open | :in_progress | :closed`); each
      adapter maps it to its own state machine.
    * `update_fields/2` — patch fields on the external item. The fields map
      uses task-domain keys (`:title`, `:description`, `:assignee`, ...); the
      adapter renames + format-converts (e.g. Markdown → ADF for Jira).
    * `link_for/1` — return a human-clickable URL for the ref. Used in CLI
      output and notifications.
    * `parse_ref/1` — best-effort parse of a user-supplied string into the
      adapter's canonical ref form (e.g. `"VR-17585"` for Jira). Returns
      `:error` if the string is clearly not for this tracker.
    * `list_transitions/1` — return the set of legal next-states from the
      current state, as task-vocabulary atoms.
    * `list_open/1` — return open items in the tracker that look "claimable"
      by the active workspace's user (assignment is the claim signal). Used
      by `arb list --tracker` to surface upstream backlog alongside local
      tasks. Adapters that don't have a notion of a backlog return
      `{:error, :not_supported}`.
    * `create/1` — create a new issue in the tracker from the given attrs
      and return the canonical `ref`. Used by `arb create` to mirror a new
      task into the configured tracker. Attrs use task-domain keys
      (`:title`, `:description`, `:assignee`, `:status`); each adapter
      translates to its own field names. Adapters that don't support
      outbound creation return `{:error, :not_supported}`.
    * `add_remote_link/3` — attach an external link (typically the PR/MR that
      implements the ticket) to the tracked item so the ticket references the
      code. **Optional** — adapters that have no notion of remote links simply
      don't implement it, and `Arbiter.Trackers.add_remote_link/3` returns
      `{:error, :not_supported}` for them. The Jira adapter implements it via
      the issue `remotelink` endpoint.

  ## `create` attrs shape

      %{
        title: "Wire the thing",
        description: "...",        # optional, Markdown
        assignee: "alice",         # optional, tracker-specific login
        status: :open,             # optional, default :open
        priority: 2,               # optional, integer 0..4 (task priority scale)
        issue_type: "bug"          # optional, free-form type string
      }

  ## `list_open` shape

  Each adapter normalizes its native payload into the same summary map so the
  CLI doesn't need to know which tracker produced the row:

      %{
        ref: "42",                           # canonical ref, as produced by parse_ref
        title: "Wire the thing",
        url: "https://github.com/o/r/issues/42",
        status: :open | :in_progress | :closed,
        assignees: ["alice", "bob"],
        raw: %{...}                          # the original tracker payload, for debugging
      }

  Options are a keyword list. Currently recognized:

    * `:assignee` — `:viewer` (default; means "the workspace's authenticated
      user") or a tracker-specific login string. Adapters may ignore this if
      they have no way to apply it.
  """

  @typedoc "Tracker-specific reference (Jira issue key, Linear node id, etc.)."
  @type ref :: String.t()

  @typedoc """
  Task-domain status / lifecycle-event atoms passed to `transition/2`.

  `:open | :in_progress | :closed` are the task's own statuses. The remaining
  atoms are richer lifecycle moments that don't map to a task status but still
  drive an external workflow (e.g. Jira's VR board): `:pr_opened` (PR opened
  for review), `:approved_unmerged` (review approved but parked, not merged),
  and `:merged` (PR merged). Adapters that don't model an event simply leave it
  unmapped, and the sync layer skips it.
  """
  @type status ::
          :open | :in_progress | :closed | :pr_opened | :approved_unmerged | :merged

  @typedoc """
  A field the tracker *gates* a transition on — i.e. the provider refuses the
  transition until the field is populated. Returned by `gating_fields/2`.

    * `:id` — the tracker-native field id (e.g. `"customfield_10184"`).
    * `:key` — the task-domain key the value is produced under (`:qa_notes`,
      `:deployment_notes`, ...), or `nil` when the field has no task-domain
      mapping (the sync layer then treats it as a genuinely-missing field and
      escalates it by `:name`).
    * `:name` — the human-facing field label, used when escalating a missing
      required field (e.g. `"QA Testing Notes"`).
    * `:value` — optional pre-resolved value the adapter supplies from workspace
      config for fields that can't be sourced from the task bead (e.g. a Jira
      fix-version name). When present and non-nil, the sync layer uses this
      directly instead of looking up the task's produced value.
  """
  @type gating_field :: %{
          required(:id) => String.t(),
          required(:key) => atom() | nil,
          required(:name) => String.t(),
          optional(:value) => term()
        }

  @typedoc "Normalized open-item summary used by `list_open/1`."
  @type summary :: %{
          required(:ref) => ref,
          required(:title) => String.t(),
          required(:url) => String.t() | nil,
          required(:status) => status,
          required(:assignees) => [String.t()],
          required(:raw) => map()
        }

  @typedoc "Task-domain attrs accepted by `create/1`."
  @type create_attrs :: %{
          required(:title) => String.t(),
          optional(:description) => String.t(),
          optional(:assignee) => String.t() | nil,
          optional(:status) => status,
          optional(:priority) => non_neg_integer() | nil,
          optional(:issue_type) => String.t() | nil
        }

  @callback fetch(ref) :: {:ok, map()} | {:error, term()}
  @callback transition(ref, status) :: :ok | {:error, term()}
  @callback update_fields(ref, map()) :: :ok | {:error, term()}
  @callback link_for(ref) :: String.t()
  @callback parse_ref(String.t()) :: {:ok, ref} | :error
  @callback list_transitions(ref) :: {:ok, [status]} | {:error, term()}
  @callback list_open(opts :: keyword()) ::
              {:ok, [summary]} | {:error, :not_supported} | {:error, term()}
  @callback create(create_attrs) ::
              {:ok, ref} | {:error, :not_supported} | {:error, term()}

  @doc """
  Returns the identity (login, accountId, member UUID, etc.) for the
  authenticated user in the current workspace context. Used by the claim model
  to enforce assignment-as-claim against "me".

  Returns `{:error, :not_supported}` when the tracker has no concept of a
  current user (e.g. `Tracker.None`), which signals that claim/sync is not
  supported for this workspace.
  """
  @callback current_user() ::
              {:ok, String.t()} | {:error, :not_supported} | {:error, term()}

  @doc """
  Extracts the set of assignee identifiers (login, accountId, member UUID,
  etc.) from a raw issue map returned by `fetch/1`. The identifier format
  matches what `current_user/0` returns for the same tracker.
  """
  @callback assignees(map()) :: [String.t()]

  @doc """
  Derives the task-vocabulary status (`:open | :in_progress | :closed`) from
  a raw issue map returned by `fetch/1`.
  """
  @callback issue_status(map()) :: status()

  @doc """
  Extracts the display title from a raw issue map returned by `fetch/1`.
  """
  @callback extract_title(map()) :: String.t()

  @doc """
  Extracts the body/description from a raw issue map returned by `fetch/1`.
  Returns an empty string when the tracker has no body or the format is not
  convertible.
  """
  @callback extract_description(map()) :: String.t()

  @doc """
  Extracts the Arbiter priority (0..4, where 0 = P0 / highest) from a raw
  issue map returned by `fetch/1`.

  Returns `{:ok, priority}` on a successful mapping, or `nil` when the
  tracker has no priority signal, the value is unmapped, or it represents an
  explicit "no priority" sentinel (e.g. Linear's `priority: 0`). Returning
  `nil` lets the schema default (P2) take effect.

  **Scale direction**: 0 = highest priority, 4 = lowest. Do NOT share the
  mapping logic with `extract_difficulty/1` — the two scales run in opposite
  directions.

  Optional — adapters without a priority signal simply don't implement it,
  and `Claim.create_task/4` skips the field so the schema default holds.
  """
  @callback extract_priority(map()) :: {:ok, 0..4} | nil

  @doc """
  Extracts the Arbiter difficulty (0..4, where 0 = D0 / trivial) from a raw
  issue map returned by `fetch/1`, derived from the tracker's
  estimate/story-points field via configurable buckets.

  Returns `{:ok, difficulty}` when a usable estimate is present and the
  difficulty feature is configured; returns `nil` when unavailable, not
  configured, or the estimate is absent. Returning `nil` preserves the
  schema's nil difficulty (routing treats nil as D2).

  **Scale direction**: 0 = easiest, 4 = hardest. Higher story-point values
  map to higher difficulty numbers — opposite of priority. Do NOT share the
  mapping logic with `extract_priority/1`.

  Best-effort and config-gated — enabled only when a workspace explicitly
  configures the estimate field and/or bucketing. Off by default.

  Optional — adapters without an estimate signal simply don't implement it.
  """
  @callback extract_difficulty(map()) :: {:ok, 0..4} | nil

  @doc """
  Attach a remote link (e.g. the implementing PR/MR) to the tracked item.

  `title` is the human label shown on the ticket; `url` is the link target.
  Optional — adapters without remote links don't implement it.
  """
  @callback add_remote_link(ref, url :: String.t(), title :: String.t()) ::
              :ok | {:error, :not_supported} | {:error, term()}

  @doc """
  Post a comment on the tracked item. `body` is Markdown; the adapter converts
  to the tracker's native rich-text format (e.g. ADF for Jira).

  Optional — adapters without a comment mechanism don't implement it, and
  `Arbiter.Trackers.add_comment/2` returns `{:error, :not_supported}`.
  """
  @callback add_comment(ref, body :: String.t()) ::
              :ok | {:error, :not_supported} | {:error, term()}

  @doc """
  Return the fields the tracker *gates* the transition mapped from `status` on
  — the fields the provider requires populated before it will accept the
  transition. Provider-agnostic by design: the adapter (not the sync layer)
  knows which transition it will invoke and which fields that transition
  requires, so the gate stays correct without any provider-specific logic
  leaking up into the workflow/sync layer.

  The sync layer uses this to push the bead's produced values into the gating
  fields *before* attempting the transition, and to escalate — naming the exact
  missing field — when a required field has no produced value.

  Returns `{:ok, []}` when the transition isn't gated (the common case). A
  benign "this tracker doesn't model that event" reason (e.g.
  `:status_unmapped`) is returned as `{:error, reason}` and the sync layer
  treats it as "no gate" (there's no transition to gate).

  **Intentionally Jira-specific.** GitHub and Shortcut have no native
  required-field-gating mechanism, so their adapters are not expected to
  implement this callback — its absence there is by design, not a parity gap.
  Optional — adapters without field gating don't implement it, and
  `Arbiter.Trackers.gating_fields/2` returns `{:ok, []}` for them.
  """
  @callback gating_fields(ref, status) ::
              {:ok, [gating_field]} | {:error, term()}

  @doc """
  Check whether the ref has already been claimed by another Arbiter
  installation. Returns `:ok` if clear, or
  `{:error, {:already_claimed, comment_body}}` if a prior-ownership marker is
  found. Optional — adapters without a comment/annotation mechanism skip the
  check (callers get `:ok`).
  """
  @callback check_prior_claim(ref) ::
              :ok | {:error, {:already_claimed, String.t()}}

  @doc """
  Post-claim side-effects: mark ownership on the upstream item (e.g. post an
  ownership comment and assign the user). Non-fatal — failures do not roll
  back the task. Optional — adapters that have no ownership-signal mechanism
  simply don't implement it.

  `context` carries claim metadata:
  - `:task_id` — the newly-created task's id
  - `:workspace_name` / `:workspace_prefix` — the workspace identifiers
  - `:current_user` — the viewer's tracker identity
  - `:host` — the Arbiter host string
  """
  @callback signal_claim(ref, task_id :: String.t(), context :: map()) :: :ok

  @doc """
  Search upstream tracker items whose title matches `title` (case-insensitive
  substring or exact match, depending on the adapter).

  Used during task creation to detect duplicates before opening a new item —
  callers check the returned list and skip creation when a sufficiently-similar
  item already exists.

  Returns `{:ok, [summary]}` on success (empty list when nothing matches) or
  `{:error, term()}` on failure. Each element in the list is a `t:summary/0`
  map — the same shape produced by `list_open/1`.

  Optional — adapters that cannot search by title simply do not implement
  this callback. The dispatcher in `Arbiter.Trackers` guards the call with
  `function_exported?/3` and falls back to skipping the dedup check.
  """
  @callback search_by_title(title :: String.t()) :: {:ok, [summary()]} | {:error, term()}

  @optional_callbacks add_remote_link: 3,
                      add_comment: 2,
                      check_prior_claim: 1,
                      signal_claim: 3,
                      gating_fields: 2,
                      search_by_title: 1,
                      extract_priority: 1,
                      extract_difficulty: 1
end
