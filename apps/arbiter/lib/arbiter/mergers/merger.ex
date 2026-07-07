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
  opaque — its internal shape is adapter-specific (e.g.
  `"direct:<branch>|<repo_path>|<target>"` for `Direct`, a
  project/MR-iid pair for GitLab, an owner/repo/PR-number triple for GitHub).

  ## `opts` map (passed to `open/4`)

  Task-domain keys, all optional unless an adapter says otherwise:

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

  @typedoc """
  A summary of an open MR/PR returned by `list_open/0`.

    * `:ref` — an opaque `t:mr_ref/0` ready to pass to other callbacks.
    * `:number` — the MR/PR number.
    * `:title` — the MR/PR title.
    * `:url` — a human-clickable URL for the MR/PR.
    * `:author` — the forge login that opened the MR/PR (best-effort; may be
      `nil` when the adapter can't resolve it).
  """
  @type open_mr :: %{
          required(:ref) => mr_ref(),
          required(:number) => pos_integer(),
          required(:title) => String.t(),
          required(:url) => String.t(),
          optional(:author) => String.t() | nil
        }

  @typedoc """
  A single piece of human PR-side review feedback surfaced by
  `list_review_feedback/1`.

    * `:kind` — `:review` for a formal review's summary body,
      `:comment` for an inline code-review comment.
    * `:author` — the reviewer's handle (best-effort; may be `nil`).
    * `:state` — the review verdict state (`"CHANGES_REQUESTED"`,
      `"COMMENTED"`, …) for `:review` items; `nil` for comments.
    * `:path` / `:line` — the file + line an inline `:comment` anchors to;
      `nil` for review summaries.
    * `:body` — the feedback text.
  """
  @type feedback_item :: %{
          required(:kind) => :review | :comment,
          required(:body) => String.t(),
          optional(:author) => String.t() | nil,
          optional(:state) => String.t() | nil,
          optional(:path) => String.t() | nil,
          optional(:line) => pos_integer() | nil
        }

  @typedoc """
  A single comment inside a review thread, returned in `t:review_thread/0`'s
  `:comments` list.

    * `:id` — the forge's integer comment id (GitHub `databaseId`, GitLab note
      id). Monotonically increasing within a thread — use as a cursor to find
      replies newer than a known `last_seen_comment_id`.
    * `:author` — the commenter's handle (best-effort; may be `nil`).
    * `:body` — the comment text (best-effort; may be `nil`).
  """
  @type review_thread_comment :: %{
          required(:id) => pos_integer() | nil,
          optional(:author) => String.t() | nil,
          optional(:body) => String.t() | nil
        }

  @typedoc """
  A review thread / inline review discussion surfaced by
  `list_open_review_threads/1` (bd-823q7e). Normalized across forges so the
  workflow layer never sees a GitHub GraphQL `reviewThread` or a GitLab
  discussion shape — only this provider-agnostic map.

    * `:id` — opaque thread/discussion id (a GitHub `reviewThread` node id, a
      GitLab discussion id). Stable enough to dedup/debounce on.
    * `:resolved` — `true` when the thread is resolved; `false` otherwise.
      `list_open_review_threads/1` returns only unresolved threads, so this
      is always `false` in practice — it is included so the full thread shape
      is self-describing when adapters surface richer data.
    * `:path` — the file the thread anchors to; `nil` for a file-level or
      MR-level (non-positional) thread.
    * `:line` — the line the thread anchors to; `nil` when unavailable.
    * `:author` — the handle that opened the thread (first comment's author;
      best-effort; may be `nil`).
    * `:body` — the opening comment's text (best-effort; may be `nil`).
    * `:comments` — all comments in the thread as a list of
      `t:review_thread_comment/0`. Callers can use `:comments` to find replies
      newer than a known `last_seen_comment_id` by filtering on `c.id > last_seen`.
      May be `nil` when the adapter does not surface individual comment ids
      (e.g. GitLab).
  """
  @type review_thread :: %{
          required(:id) => term(),
          optional(:resolved) => boolean(),
          optional(:path) => String.t() | nil,
          optional(:line) => pos_integer() | nil,
          optional(:author) => String.t() | nil,
          optional(:body) => String.t() | nil,
          optional(:comments) => [review_thread_comment()] | nil
        }

  @typedoc """
  A single failing CI check surfaced by `failing_check_logs/1` so the Warden
  can brief a fix-pass acolyte with the failure (#354, Phase 2a).

    * `:name` — the check/job name (e.g. `"build"`, `"test (1.16)"`).
    * `:summary` — a tail of the failure output (title/summary/log excerpt),
      truncated to a briefing-sized snippet.
    * `:url` — a human link to the full check run, when the adapter has one.
  """
  @type failing_check :: %{
          required(:name) => String.t(),
          required(:summary) => String.t(),
          optional(:url) => String.t() | nil
        }

  @typedoc """
  Aggregated human PR-side review feedback (bd-95lsjb). Returned by
  `list_review_feedback/1` and consumed by the MergeQueue to drive an
  auto-revise pass on the existing worktree.

    * `:changes_requested` — true when the latest verdict (per reviewer) on
      the PR is CHANGES_REQUESTED.
    * `:latest_review_id` — an opaque, monotonic-ish handle for the most
      recent CHANGES_REQUESTED review (its id, else its timestamp). The
      MergeQueue debounces on this so the same review is actioned at most once.
    * `:feedback` — the review summaries (with bodies) and inline comments to
      inject into the revise worker's prompt.
  """
  @type review_feedback :: %{
          required(:changes_requested) => boolean(),
          required(:latest_review_id) => term() | nil,
          required(:feedback) => [feedback_item()]
        }

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

  @doc """
  Fetch the human PR-side review feedback for `mr_ref` — the latest review
  verdict (with its body) and the inline review comments — so the MergeQueue
  can dispatch an auto-revise pass when a reviewer requests changes
  (bd-95lsjb).

  Adapters with no forge review surface (e.g. `Direct`) no-op:
  `{:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}}`.
  """
  @callback list_review_feedback(mr_ref) :: {:ok, review_feedback()} | {:error, term()}

  @doc """
  Update the MR's head branch from its base — the mechanical rebase-forward the
  base-aware merge queue (Crucible, #354 Phase 3) runs to keep an in-flight PR
  continuously rebased as the integration branch moves. For hosted forges
  (GitHub: `PUT /pulls/:n/update-branch`; GitLab: `PUT …/rebase`) the update
  may complete asynchronously — the queue re-polls `get/1` to observe the
  result. For `Direct`, this is a local `git rebase <target_branch>` on the
  working branch inside the repo (synchronous, returns `:ok` once the rebase
  applies cleanly).

  Returns `:ok` once the update is accepted. Returns `{:error, term()}` when
  the update can't be performed (e.g. the rebase/merge would conflict). The
  queue treats the error as non-fatal: it does not classify the conflict from
  this return, but re-polls and lets `get/1`'s `conflicting` field route a
  genuine conflict to the resolver (so a base-introduced conflict surfaces
  during the rebase step, not at merge time).

  Optional — adapters that have no meaningful way to update a branch simply
  don't implement it; callers guard with `function_exported?/3` and fall back
  to leaving the PR un-rebased.
  """
  @callback update_branch(mr_ref) :: :ok | {:error, term()}

  @doc """
  Fetch the failing CI checks for `mr_ref` — their names and a tail of each
  one's output — so the Warden can brief a fix-pass acolyte on a `:ci_failed`
  block (#354, Phase 2a). For GitHub this reads the Checks API for the PR's head
  commit.

  Returns `{:ok, [failing_check()]}` (an empty list when nothing is failing or
  no CI is configured) or `{:error, term()}`.

  Optional — adapters that don't expose check logs simply don't implement it;
  the Warden guards with `function_exported?/3` and dispatches the fix pass with
  whatever context it has.
  """
  @callback failing_check_logs(mr_ref) :: {:ok, [failing_check()]} | {:error, term()}

  @doc """
  List open merge requests / pull requests in the configured repository.

  Returns `{:ok, [open_mr()]}` (an empty list when no open MRs exist — not
  an error) or `{:error, term()}`. Each `open_mr` carries an opaque
  `t:mr_ref/0` ready to pass to `list_review_feedback/1` or other callbacks.

  Optional — adapters with no concept of an open-MR listing (e.g. `Direct`)
  simply don't implement it; callers guard with `function_exported?/3` and
  skip the patrol for that strategy.
  """
  @callback list_open() :: {:ok, [open_mr()]} | {:error, term()}

  @doc """
  List the **unresolved** review threads / inline review discussions on
  `mr_ref` — the provider-agnostic "open review feedback" signal PRPatrol
  triggers on (bd-823q7e).

  This is distinct from `list_review_feedback/1`: that surface reports the
  latest *verdict* state (CHANGES_REQUESTED) and the raw comment bodies, but
  carries no resolution state, so a `COMMENTED` review with inline comments —
  e.g. an automated reviewer leaving line comments without requesting changes
  — is invisible to it. Resolution state only lives on the forge's thread
  primitive: GitHub's `pullRequest.reviewThreads { isResolved }` (GraphQL),
  GitLab's MR discussions (`notes[].resolvable` / `resolved`). Each adapter
  queries its own primitive and returns only the **open** (unresolved) threads,
  already normalized to `t:review_thread/0`.

  Returns `{:ok, [review_thread()]}` (an empty list when every thread is
  resolved or the PR has none — not an error) or `{:error, term()}`.

  Optional — adapters with no review-thread surface (e.g. `Direct`, the
  local-merge strategy) simply don't implement it; callers guard with
  `function_exported?/3` and treat the absence as "no open review feedback".
  """
  @callback list_open_review_threads(mr_ref) :: {:ok, [review_thread()]} | {:error, term()}

  @doc """
  Post a threaded reply to an existing review comment on `mr_ref`.

  `comment_id` is the forge's integer comment id — the same integer surfaced as
  `:id` in each `t:review_thread_comment/0` map returned by
  `list_open_review_threads/1`. `body` is the reply text.

  Returns `{:ok, comment_payload}` on success. Adapters with no thread-reply
  surface (e.g. `Direct`, `GitLab`) return `{:error, :unsupported}` — callers
  guard with `function_exported?/3` or check the error and fall back to a
  top-level comment via `add_comment/2`.

  Optional — adapters that don't implement in-thread replies simply don't
  export it.
  """
  @callback reply_to_review_comment(
              mr_ref,
              comment_id :: pos_integer(),
              body :: String.t(),
              opts :: map()
            ) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Construct an `t:mr_ref/0` for an **existing, externally-authored** PR/MR from
  an operator-supplied identifier — a forge URL, an `owner/repo#n` slug, or a
  bare number/`#n` — so `arb review --pr <url|number>` can point a review-only
  pass at a PR the fleet never opened (bd-d4ealy).

  This is the provider-agnostic seam that keeps `mr_ref` minting from being
  hard-coded to GitHub: each adapter parses the forms it recognizes into its own
  opaque ref shape (GitHub's `"<owner>/<repo>#<n>"`, GitLab's `"!<n>"`, …) and
  the external-review orchestrator stays adapter-blind.

  `opts` may carry `:repo_path` (a local checkout) so an adapter can derive the
  target repo from the checkout's `origin` remote when the identifier is a bare
  number (e.g. GitHub embeds the derived `owner/repo` into the ref).

  Returns `{:ok, mr_ref}` or `{:error, term()}` (an unparseable identifier).

  Optional — adapters with no concept of an external PR (e.g. `Direct`, the
  local-merge strategy) simply don't implement it; callers guard with
  `function_exported?/3` and reject external review for that strategy.
  """
  @callback ref_for_pr(pr :: String.t(), opts :: map()) :: {:ok, mr_ref} | {:error, term()}

  @doc """
  Resolve (close) a review thread on `mr_ref` — the counterpart to
  `list_open_review_threads/1`'s `:id` field (bd-76ydsu).

  Used by author-side follow-up (PRPatrol / the merge-queue revise dispatch)
  after pushing a fix so an addressed thread stops showing as "unresolved" —
  distinct from `reply_to_review_comment/4`, which only posts a reply and
  leaves the thread's resolution state untouched.

  Returns `{:ok, term()}` on success. Adapters with no thread-resolution
  primitive (e.g. `Direct`) return `{:error, :unsupported}`.

  Optional — adapters that don't implement thread resolution simply don't
  export it; callers guard with `function_exported?/3`.
  """
  @callback resolve_review_thread(mr_ref, thread_id :: String.t(), opts :: map()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  List the **settled, REQUIRED** failing checks on `mr_ref` (bd-ayetel) — the
  signal PRPatrol's author-side CI trigger fires on.

  Distinct from `failing_check_logs/1`: that surface reports *every* failing
  check (required or not) for the fix-pass briefing, with no notion of
  "required for merge". A failing optional/informational check must not page
  anyone, so this callback filters down to checks the forge's branch
  protection actually requires — GitHub's GraphQL `isRequired` field on each
  `statusCheckRollup` context (works for both modern check runs and legacy
  commit statuses) — and further to checks that have **settled** (not
  pending/in-progress): a required check still running is not yet a failure.

  Returns `{:ok, [failing_check()]}` (an empty list when every required check
  is passing/pending, or the PR has none — not an error) or
  `{:error, term()}`.

  Optional — adapters with no concept of required checks (e.g. `Direct`)
  simply don't implement it; callers guard with `function_exported?/3` and
  treat the absence as "no required-check failures".
  """
  @callback list_required_check_failures(mr_ref) :: {:ok, [failing_check()]} | {:error, term()}

  @optional_callbacks update_branch: 1,
                      failing_check_logs: 1,
                      ref_for_pr: 2,
                      list_open: 0,
                      list_open_review_threads: 1,
                      reply_to_review_comment: 4,
                      resolve_review_thread: 3,
                      list_required_check_failures: 1
end
