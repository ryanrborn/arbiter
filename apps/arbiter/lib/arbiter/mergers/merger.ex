defmodule Arbiter.Mergers.Merger do
  @moduledoc """
  Behaviour for merge-request / integration adapters.

  An adapter implements this for one merge backend: the local `Direct` merge
  (no MR, no review gate — the current default), or a hosted forge
  (`GitLab`, `GitHub` — wired up in later directives). The `Arbiter.Mergers`
  helper resolves which adapter to use for a given workspace by reading
  `workspace.config["merge"]["strategy"]`.

  This mirrors the `Arbiter.Trackers.Tracker` abstraction: a behaviour, a
  dispatcher that resolves the adapter from workspace config, and one module
  per backend.

  ## `mr_ref`

  Every adapter mints an opaque `t:mr_ref/0` (a binary) from `open/4` and
  accepts it back on the remaining callbacks. Callers should treat it as
  opaque — its internal shape is adapter-specific (e.g. `"direct:<branch>"`
  for `Direct`, a project/MR-iid pair for GitLab, an owner/repo/PR-number
  triple for GitHub).

  ## `opts` map (passed to `open/4`)

  Bead-domain keys, all optional unless an adapter says otherwise:

    * `:target_branch` — branch to integrate into (e.g. `"main"`).
    * `:reviewer_ids` — reviewers to request on open.
    * `:labels` — labels to apply to the MR.

  Individual adapters may read additional keys (the `Direct` adapter, for
  instance, requires a `:repo_path` since it operates on a local checkout).

  ## Callback semantics

    * `open/4` — open the merge request (or perform the merge, for `Direct`)
      for `branch`. Returns `{:ok, mr_ref}`.
    * `get/1` — fetch the current state of the MR as an opaque map.
    * `merge/1` — merge the MR (no-op where `open/4` already merged).
    * `close/1` — close the MR without merging.
    * `add_comment/2` — post a comment on the MR.
    * `request_review/2` — request review from `reviewers`.
    * `link_for/1` — return a human-clickable URL for the ref (empty string
      when the backend has no web UI, e.g. `Direct`).

  ## Review callbacks

  The remaining callbacks let `Arbiter.Workflows.CodeReview` operate on a
  PR/MR through the same adapter abstraction, instead of hard-coding a
  GitHub HTTP client. They take a small `opts` map so callers can pass
  adapter-specific context (e.g. the `Direct` adapter's `:repo_path` and
  `:target_branch`) without having to pre-seed a per-process config.

    * `get_diff/2` — fetch the unified diff text for `mr_ref`. For local
      adapters this is `git diff <base>..<branch>`; for hosted forges it is
      the diff payload returned by the API.
    * `post_inline_comment/3` — post a single finding as an inline review
      comment (or its adapter-specific equivalent, e.g. a local-file entry
      for `Direct`).
    * `submit_review/4` — submit a final review verdict (approve or
      request_changes) with a body. Adapters that have no concept of a
      "review" (e.g. `Direct`) write the verdict locally.
  """

  @typedoc "Adapter-specific merge-request reference (opaque binary)."
  @type mr_ref :: String.t()

  @typedoc "A code-review finding produced by the check runner."
  @type finding :: %{
          required(:severity) => :info | :warning | :error,
          required(:file) => String.t(),
          required(:line) => pos_integer(),
          required(:message) => String.t()
        }

  @typedoc "Final review verdict."
  @type verdict :: :approve | :request_changes

  @callback open(
              branch :: String.t(),
              title :: String.t(),
              description :: String.t(),
              opts :: map()
            ) ::
              {:ok, mr_ref} | {:error, term()}
  @callback get(mr_ref) :: {:ok, map()} | {:error, term()}
  @callback merge(mr_ref) :: :ok | {:error, term()}
  @callback close(mr_ref) :: :ok | {:error, term()}
  @callback add_comment(mr_ref, body :: String.t()) :: :ok | {:error, term()}
  @callback request_review(mr_ref, reviewers :: [term()]) :: :ok | {:error, term()}
  @callback link_for(mr_ref) :: String.t()

  @callback get_diff(mr_ref, opts :: map()) :: {:ok, String.t()} | {:error, term()}
  @callback post_inline_comment(mr_ref, finding, opts :: map()) ::
              {:ok, term()} | {:error, term()}
  @callback submit_review(mr_ref, verdict, body :: String.t(), opts :: map()) ::
              {:ok, term()} | {:error, term()}
end
