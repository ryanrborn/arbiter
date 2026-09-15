defmodule Arbiter.Reviews.PushState do
  @moduledoc """
  Whether the commit a review (or an escalation) is talking about is actually
  **on the remote branch the PR/MR points at** (bd-2jkrqu).

  ## Why this exists

  Every other part of the review/merge control plane reads the *local*
  worktree: `Arbiter.Worker.ReviewGate` diffs `base_sha..HEAD` in the worktree,
  the reviewer agent reads files in the worktree, `stamp_reviewed_head/1`
  stamps `git rev-parse HEAD`. That is correct only while local HEAD and
  `origin/<branch>` are the same commit — and nothing enforced that.

  On 2026-09-15 they were not. A ReviewGate fix round committed its fixes as
  `edadf22c` in the worktree and never pushed; `origin` and the MR's pipeline
  stayed on the unfixed `8deed4e5`. The round-2 reviewer read the local
  worktree, marked every finding `[ADDRESSED]` citing lines that existed only
  locally, and APPROVED. The park escalation then told a human "the work is
  committed and the branch is pushed … merge it by hand, if the diff is fine".
  Merging by hand would have merged the unfixed commit. (Two days earlier, a
  timed-out fix round left *sixteen* commits unpushed.)

  This module is the one place that answers the git question underneath all of
  that, so the gate, the coverage/stamp writes and the escalation text all
  answer it the same way instead of assuming.

  ## The three-valued verdict

  `verdict/1` is deliberately three-valued, because "I could not tell" and
  "definitely not pushed" must not be collapsed:

    * `:pushed` — local HEAD is an ancestor of (or equal to) `origin/<branch>`;
      the remote genuinely carries this commit.
    * `:unpushed` — the remote ref exists and does **not** contain local HEAD,
      or the branch does not exist on the remote at all. Positive knowledge of
      the bug's shape.
    * `:unknown` — no worktree, no `origin`, or git failed. Callers **fail
      open** here: an ad-hoc checkout with no remote is not an incident, and a
      guard that refuses on "I could not tell" is exactly the misfire class
      `docs/review-coverage-and-guard-policy.md` §5.1 exists to prevent.

  `:behind` counts as `:pushed` on purpose: the remote already has this commit
  (and more). The head under review is published; whether the branch also
  moved on is a different question, and not this guard's.

  ## Fetching

  `inspect_branch/3` fetches `origin/<branch>` first by default, because a
  stale remote-tracking ref would answer the question about the past. Pass
  `fetch?: false` on a path that has just fetched or pushed (the tracking ref
  is updated by a successful push) to skip the network round trip.
  """

  require Logger

  @type status ::
          :in_sync
          | :ahead
          | :behind
          | :diverged
          | :no_remote_branch
          | :no_origin
          | :unknown

  @type t :: %{
          status: status(),
          branch: String.t() | nil,
          remote: String.t(),
          local_head: String.t() | nil,
          remote_head: String.t() | nil,
          ahead_by: non_neg_integer() | nil
        }

  @doc """
  Resolve the push state of `branch` as seen from the git worktree at `path`.

  Never raises and never returns `{:error, _}`: an unusable checkout is a
  `:unknown` / `:no_origin` state, which callers read through `verdict/1`.

  ## Options

    * `:remote` — remote name, default `"origin"`.
    * `:fetch?` — fetch the branch from the remote first, default `true`.
  """
  @spec inspect_branch(String.t() | nil, String.t() | nil, keyword()) :: t()
  def inspect_branch(path, branch, opts \\ [])

  def inspect_branch(path, branch, opts) when is_binary(path) and is_binary(branch) do
    remote = Keyword.get(opts, :remote, "origin")

    base = %{
      status: :unknown,
      branch: branch,
      remote: remote,
      local_head: nil,
      remote_head: nil,
      ahead_by: nil
    }

    case git(path, ["rev-parse", "HEAD"]) do
      {:ok, local} -> resolve(path, %{base | local_head: local}, opts)
      :error -> base
    end
  end

  def inspect_branch(_path, _branch, opts) do
    %{
      status: :unknown,
      branch: nil,
      remote: Keyword.get(opts, :remote, "origin"),
      local_head: nil,
      remote_head: nil,
      ahead_by: nil
    }
  end

  defp resolve(path, %{branch: branch, remote: remote} = state, opts) do
    with {:ok, _url} <- git(path, ["remote", "get-url", remote]) do
      if Keyword.get(opts, :fetch?, true) do
        # Best effort: a fetch failure (offline, auth) leaves the cached
        # tracking ref in place and the comparison below still runs.
        _ = git(path, ["fetch", "--quiet", remote, branch])
      end

      ref = remote <> "/" <> branch

      case git(path, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]) do
        {:ok, remote_head} -> compare(path, %{state | remote_head: remote_head}, ref)
        :error -> %{state | status: :no_remote_branch}
      end
    else
      :error -> %{state | status: :no_origin}
    end
  end

  defp compare(path, %{local_head: local, remote_head: remote} = state, ref) do
    cond do
      local == remote ->
        %{state | status: :in_sync, ahead_by: 0}

      ancestor?(path, "HEAD", ref) ->
        %{state | status: :behind, ahead_by: 0}

      ancestor?(path, ref, "HEAD") ->
        %{state | status: :ahead, ahead_by: count_ahead(path, ref)}

      true ->
        %{state | status: :diverged, ahead_by: count_ahead(path, ref)}
    end
  end

  defp ancestor?(path, a, b) do
    match?({:ok, _}, git(path, ["merge-base", "--is-ancestor", a, b]))
  end

  defp count_ahead(path, ref) do
    case git(path, ["rev-list", "--count", ref <> "..HEAD"]) do
      {:ok, out} -> String.to_integer(out)
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Three-valued read of a state produced by `inspect_branch/3`.

  See the moduledoc for why `:unknown` is distinct from `:unpushed`.
  """
  @spec verdict(t()) :: :pushed | :unpushed | :unknown
  def verdict(%{status: status}) do
    case status do
      :in_sync -> :pushed
      :behind -> :pushed
      :ahead -> :unpushed
      :diverged -> :unpushed
      :no_remote_branch -> :unpushed
      _ -> :unknown
    end
  end

  @doc """
  One sentence a human can act on, naming the actual SHAs.

  This is the sentence that replaces the old escalation's blanket assertion
  that "the branch is pushed" — it is derived from git, so it can say the
  branch is not.
  """
  @spec describe(t()) :: String.t()
  def describe(%{status: :in_sync} = s),
    do: "`#{s.branch}` is pushed: local HEAD and `#{ref(s)}` are both #{short(s.local_head)}."

  def describe(%{status: :behind} = s),
    do:
      "local HEAD #{short(s.local_head)} is already on `#{ref(s)}`, which has since " <>
        "advanced to #{short(s.remote_head)}."

  def describe(%{status: :ahead} = s),
    do:
      "`#{s.branch}` is NOT pushed: local HEAD is #{short(s.local_head)} but `#{ref(s)}` " <>
        "is #{short(s.remote_head)} (#{commits(s.ahead_by)} unpushed)."

  def describe(%{status: :diverged} = s),
    do:
      "`#{s.branch}` has DIVERGED from `#{ref(s)}` and is NOT pushed: local HEAD is " <>
        "#{short(s.local_head)}, `#{ref(s)}` is #{short(s.remote_head)}, and neither " <>
        "contains the other."

  def describe(%{status: :no_remote_branch} = s),
    do:
      "`#{s.branch}` does not exist on `#{s.remote}` at all: local HEAD " <>
        "#{short(s.local_head)} is NOT pushed anywhere."

  def describe(%{status: :no_origin} = s),
    do: "push state unknown: this checkout has no `#{s.remote}` remote."

  def describe(_state), do: "push state could not be determined from the worktree."

  defp ref(%{remote: remote, branch: branch}), do: remote <> "/" <> branch

  defp short(nil), do: "(unknown)"
  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 12)

  defp commits(nil), do: "local commits"
  defp commits(1), do: "1 local commit"
  defp commits(n), do: "#{n} local commits"

  @doc """
  Make the local head of `branch` reachable on the remote, pushing it once if
  it is not.

  This is the review gate's pre-round obligation: the head a reviewer is about
  to read, a coverage row is about to name and a human is about to be told to
  merge must be the head the PR carries.

  Returns:

    * `{:ok, :already_pushed, state}` — nothing to do.
    * `{:ok, :pushed, state}` — one push landed the local head on the remote.
    * `{:ok, :unknown, state}` — push state is undeterminable (no remote, no
      git); fail open, exactly as the gate did before this guard existed.
    * `{:error, reason, state}` — the head is definitely not on the remote and
      could not be put there. A **diverged** branch is never force-pushed: the
      remote may carry another worker's commits, so this escalates instead.

  Exactly one push attempt is made per call — the guard's bound
  (`GuardRegistry` row `G18`, `{:attempts, 1}`).
  """
  @spec ensure_pushed(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, :already_pushed | :pushed | :unknown, t()} | {:error, term(), t()}
  def ensure_pushed(path, branch, opts \\ []) do
    state = inspect_branch(path, branch, opts)

    case verdict(state) do
      :pushed -> {:ok, :already_pushed, state}
      :unknown -> {:ok, :unknown, state}
      :unpushed -> push_once(path, branch, state, opts)
    end
  end

  # A diverged branch must not be force-pushed: `origin/<branch>` may carry
  # commits this worktree has never seen (a ReviewGate implementer round
  # pushing straight to origin is the known producer — see
  # `Worktree.rebase_onto_origin/2`). Refuse and let the caller escalate.
  defp push_once(_path, _branch, %{status: :diverged} = state, _opts),
    do: {:error, :diverged, state}

  defp push_once(path, branch, state, opts) do
    remote = state.remote
    refspec = "HEAD:refs/heads/" <> branch

    case git(path, ["push", remote, refspec]) do
      {:ok, _out} ->
        # A successful push updates refs/remotes/<remote>/<branch> locally, so
        # the confirmation read needs no second network round trip.
        after_push = inspect_branch(path, branch, Keyword.put(opts, :fetch?, false))

        case verdict(after_push) do
          :pushed -> {:ok, :pushed, after_push}
          _ -> {:error, :push_did_not_land, after_push}
        end

      :error ->
        {:error, :push_failed, state}
    end
  end

  @doc """
  The head SHA a reviewed-SHA stamp or a `review_coverage` row may name for
  this branch, or a refusal.

  `{:error, {:head_not_pushed, state}}` means the local head is positively not
  on the remote branch: stamping it would record a review of a commit the PR
  does not carry, which is the write that made the vs-5l45oz approval look
  legitimate. An undeterminable push state falls back to the local head (the
  pre-bd-2jkrqu behaviour) rather than refusing.
  """
  @spec reviewable_head(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, {:head_not_pushed, t()} | :no_head}
  def reviewable_head(path, branch, opts \\ []) do
    state = inspect_branch(path, branch, opts)

    case {verdict(state), state.local_head} do
      {:unpushed, _} -> {:error, {:head_not_pushed, state}}
      {_, head} when is_binary(head) and head != "" -> {:ok, head}
      _ -> {:error, :no_head}
    end
  end

  # `System.cmd/3` raises when `cd:` does not exist; a missing worktree is a
  # normal state here (it was cleaned up, the path came from stale meta), not
  # an exception.
  defp git(path, args) do
    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {_out, _code} -> :error
    end
  rescue
    e in [ErlangError, ArgumentError] ->
      Logger.debug("PushState: git #{inspect(args)} in #{path} failed: #{inspect(e)}")
      :error
  end
end
