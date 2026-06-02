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

  @callback fetch(ref) :: {:ok, map()} | {:error, term()}
  @callback transition(ref, status) :: :ok | {:error, term()}
  @callback update_fields(ref, map()) :: :ok | {:error, term()}
  @callback link_for(ref) :: String.t()
  @callback parse_ref(String.t()) :: {:ok, ref} | :error
  @callback list_transitions(ref) :: {:ok, [status]} | {:error, term()}
  @callback list_open(opts :: keyword()) ::
              {:ok, [summary]} | {:error, :not_supported} | {:error, term()}
end
