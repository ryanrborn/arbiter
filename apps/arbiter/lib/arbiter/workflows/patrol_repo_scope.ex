defmodule Arbiter.Workflows.PatrolRepoScope do
  @moduledoc """
  Pure ref→repo helpers shared by the lazy-start machinery (bd-7tr11p).

  A patrol's watched items are `Issue`s that carry a merge ref — an engagement's
  `source_pr` or a fleet-authored PR task's `pr_ref`. For GitHub those refs are
  minted by `Arbiter.Mergers.Github` in one of two shapes (see that module's
  `build_mr_ref/4`):

    * **qualified** `"owner/repo#N"` (optionally `"github:owner/repo#N"`) — the
      multi-repo shape, where the workspace's merge config pins only an `owner`
      and each repo is derived per-rig. The repo is embedded in the ref.

    * **bare** `"#N"` — the single-repo shape, used when `merge.config.repo` is
      set. GitLab refs (`"!<iid>"`) are likewise single-project/bare.

  So the repo a watched item belongs to is recoverable from the ref alone, with
  no forge call: a qualified ref names its repo directly, and a bare ref can only
  occur in a single-repo workspace — where there is exactly one repo — so it
  matches whichever repo is asking. This lets the supervisor decide *whether* a
  repo has watched work, and lets a patrol scope its watched set to its own repo,
  entirely from the database.
  """

  # owner/repo#N — owner and repo each contain no slash, whitespace, or '#',
  # with exactly one '/' between them and a trailing '#<number>'. An optional
  # "github:" scheme prefix is stripped first.
  @qualified ~r{^([^/\s#]+/[^/\s#]+)#\d+$}

  @doc """
  Extract the `"owner/repo"` slug embedded in a merge ref, or `:bare` when the
  ref carries no embedded repo (single-repo / GitLab shape, or anything
  unparseable).
  """
  @spec repo_of_ref(term()) :: {:ok, String.t()} | :bare
  def repo_of_ref(ref) when is_binary(ref) do
    ref = String.replace_prefix(ref, "github:", "")

    case Regex.run(@qualified, ref) do
      [_, slug] -> {:ok, slug}
      _ -> :bare
    end
  end

  def repo_of_ref(_ref), do: :bare

  @doc """
  Whether a watched item's merge `ref` belongs to `repo` (an `"owner/repo"`
  slug). A qualified ref matches only its own repo; a bare ref matches any repo
  (it can only exist in a single-repo workspace, so the sole repo is always the
  right answer). A non-binary ref or repo never matches.
  """
  @spec ref_matches_repo?(term(), term()) :: boolean()
  def ref_matches_repo?(ref, repo) when is_binary(ref) and is_binary(repo) do
    case repo_of_ref(ref) do
      {:ok, slug} -> slug == repo
      :bare -> true
    end
  end

  def ref_matches_repo?(_ref, _repo), do: false
end
