defmodule Arbiter.Trackers.Tracker do
  @moduledoc """
  Behaviour for external issue-tracker adapters.

  An adapter implements this for one tracker backend (`Jira`, `Linear`,
  `GitHub`, or the trivial `None` stand-in). The `Arbiter.Trackers` helper
  resolves which adapter to use for a given bead by reading
  `issue.tracker_type`.

  See `docs/decision-doc.md` section 8 for the design rationale and the full
  matrix of adapters / formats.

  ## Callback semantics

    * `fetch/1` — pull the canonical record from the tracker. Shape is
      tracker-specific (a Jira issue map, a Linear node, etc.); callers should
      treat the result as opaque and use other callbacks to act on it.
    * `transition/2` — move the external item to a target status. The status
      atom uses the bead vocabulary (`:open | :in_progress | :closed`); each
      adapter maps it to its own state machine.
    * `update_fields/2` — patch fields on the external item. The fields map
      uses bead-domain keys (`:title`, `:description`, `:assignee`, ...); the
      adapter renames + format-converts (e.g. Markdown → ADF for Jira).
    * `link_for/1` — return a human-clickable URL for the ref. Used in CLI
      output and notifications.
    * `parse_ref/1` — best-effort parse of a user-supplied string into the
      adapter's canonical ref form (e.g. `"VR-17585"` for Jira). Returns
      `:error` if the string is clearly not for this tracker.
    * `list_transitions/1` — return the set of legal next-states from the
      current state, as bead-vocabulary atoms.
    * `list_open/1` — return open items in the tracker that look "claimable"
      by the active workspace's user (assignment is the claim signal). Used
      by `arb list --tracker` to surface upstream backlog alongside local
      beads. Adapters that don't have a notion of a backlog return
      `{:error, :not_supported}`.
    * `create/1` — create a new issue in the tracker from the given attrs
      and return the canonical `ref`. Used by `arb create` to mirror a new
      bead into the configured tracker. Attrs use bead-domain keys
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
        priority: 2,               # optional, integer 0..4 (bead priority scale)
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

  @typedoc "Bead-domain status atoms."
  @type status :: :open | :in_progress | :closed

  @typedoc "Normalized open-item summary used by `list_open/1`."
  @type summary :: %{
          required(:ref) => ref,
          required(:title) => String.t(),
          required(:url) => String.t() | nil,
          required(:status) => status,
          required(:assignees) => [String.t()],
          required(:raw) => map()
        }

  @typedoc "Bead-domain attrs accepted by `create/1`."
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
  Derives the bead-vocabulary status (`:open | :in_progress | :closed`) from
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
  Attach a remote link (e.g. the implementing PR/MR) to the tracked item.

  `title` is the human label shown on the ticket; `url` is the link target.
  Optional — adapters without remote links don't implement it.
  """
  @callback add_remote_link(ref, url :: String.t(), title :: String.t()) ::
              :ok | {:error, :not_supported} | {:error, term()}

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
  back the bead. Optional — adapters that have no ownership-signal mechanism
  simply don't implement it.

  `context` carries claim metadata:
  - `:bead_id` — the newly-created bead's id
  - `:workspace_name` / `:workspace_prefix` — the workspace identifiers
  - `:current_user` — the viewer's tracker identity
  - `:host` — the Arbiter host string
  """
  @callback signal_claim(ref, bead_id :: String.t(), context :: map()) :: :ok

  @optional_callbacks add_remote_link: 3, check_prior_claim: 1, signal_claim: 3
end
