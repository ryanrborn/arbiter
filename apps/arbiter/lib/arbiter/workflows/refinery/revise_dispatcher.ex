defmodule Arbiter.Workflows.Refinery.ReviseDispatcher do
  @moduledoc """
  Dispatch an auto-revise pass on a bead's **existing** worktree when a human
  reviewer requests changes (or leaves actionable review comments) on its PR
  (bd-95lsjb).

  Invoked by `Arbiter.Workflows.Refinery` when `adapter.get` reports a
  CHANGES_REQUESTED review newer than the last one the queue handled. Before
  this, a CHANGES_REQUESTED review left the item idling at `:awaiting_approval`
  forever — the internal Tribunal is the only revise loop, and it runs
  *pre-PR*, so human PR-side feedback was wired into nothing. The revise
  dispatcher closes that gap.

  ## Job scope

  This reuses the `arb resume` path (`Arbiter.Polecat.Sling.resume/2`): it
  re-attaches a fresh worker to the bead's **preserved worktree** —
  the same branch the PR already tracks — briefed with the reviewer's feedback
  prepended to the standard work prompt. The worker addresses the feedback,
  commits, and pushes to the **same branch**; the existing PR updates in place.

  It must NOT open a new PR (pairs with bd-53xrmi: single canonical PR, the
  worker only pushes). `Sling.resume` threads the bead's existing `pr_ref`
  through so completion reuses the open PR rather than duplicating it.

  ## Merger/tracker-agnostic

  Like the `ConflictResolver`, this module operates on the bead + its preserved
  worktree. It is unaware of GitHub/GitLab — the Refinery one layer up reads
  the CHANGES_REQUESTED signal from whichever forge adapter it's wired to and
  passes the rendered feedback down.

  ## Behaviour

  `ReviseDispatcher` is a behaviour so the Refinery accepts a swappable
  implementation (defaults to this module). Tests inject a stub so they don't
  boot a real Claude session or shell out to git.
  """

  alias Arbiter.Mergers.Merger
  alias Arbiter.Polecat.Sling

  require Logger

  # This module both defines the behaviour and ships the default
  # implementation, so it implements itself.
  @behaviour __MODULE__

  @type dispatch_args :: %{
          required(:bead_id) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:target_branch) => String.t() | nil,
          optional(:pr_ref) => term(),
          optional(:feedback) => [Merger.feedback_item()],
          optional(:rig) => String.t() | nil,
          optional(:start_claude) => boolean(),
          optional(:claude_command) => [String.t()]
        }

  @type dispatch_result :: {:ok, map()} | {:error, term()}

  @doc """
  Spawn a worker on the bead's existing worktree to address the review
  feedback and push to the same branch.

  Returns `{:ok, info}` once the worker is spawned (the revise runs
  asynchronously; the Refinery returns the item to `:awaiting_approval` to
  await re-review). Returns `{:error, reason}` when the worktree can't be
  resumed (e.g. it was cleaned up, or a polecat is still actively working the
  bead) — the Refinery parks the item `:failed` so it doesn't spin.
  """
  @callback dispatch(args :: dispatch_args()) :: dispatch_result()

  @optional_callbacks []

  @doc """
  Default implementation of `dispatch/1`. Delegates to
  `Arbiter.Polecat.Sling.resume/2` with the review feedback rendered into a
  briefing that is prepended to the work prompt.

  Tests should pass a stub via the Refinery's `:revise_dispatcher` opt so they
  don't shell out to git or spawn `claude`.
  """
  @impl true
  @spec dispatch(dispatch_args()) :: dispatch_result()
  def dispatch(%{bead_id: bead_id} = args) when is_binary(bead_id) do
    briefing = render_feedback(args)

    resume_opts =
      [revise_feedback: briefing]
      |> maybe_put(:rig, Map.get(args, :rig))
      |> maybe_put(:claude_command, Map.get(args, :claude_command))
      |> Keyword.put(:start_claude, Map.get(args, :start_claude, true))

    case Sling.resume(bead_id, resume_opts) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, reason}
    end
  end

  def dispatch(_), do: {:error, :missing_bead_id}

  @doc """
  Render the reviewer's feedback into the briefing block prepended to the
  revise worker's prompt. Public for tests + introspection.

  Lists the formal review summaries (with their verdict state) and the inline
  review comments (`path:line — body`), with an explicit, narrow instruction:
  address the feedback, commit, and push to the SAME branch — do not open a
  new PR.
  """
  @spec render_feedback(dispatch_args()) :: String.t()
  def render_feedback(%{} = args) do
    bead_id = Map.get(args, :bead_id, "(unknown)")
    feedback = Map.get(args, :feedback) || []

    """
    ## Human PR review feedback to address (bd-95lsjb)

    A reviewer requested changes on the open PR for bead #{bead_id}. Your job
    this pass is to ADDRESS THE FEEDBACK BELOW on the existing branch:

    #{render_items(feedback)}

    Then:
      * commit your changes and push to the SAME branch (the PR updates in
        place — do NOT open a new PR),
      * keep the change scoped to what the feedback asks for,
      * print `arb done` when finished so the merge queue re-reviews.

    ----

    """
  end

  defp render_items([]),
    do: "  (No structured comment bodies were captured — re-read the PR thread for context.)"

  defp render_items(feedback) when is_list(feedback) do
    feedback
    |> Enum.map(&render_item/1)
    |> Enum.join("\n")
  end

  defp render_item(%{kind: :review} = item) do
    state = item[:state] || "REVIEW"
    author = author_label(item[:author])
    "  * [#{state}#{author}] #{one_line(item[:body])}"
  end

  defp render_item(%{kind: :comment} = item) do
    loc =
      case {item[:path], item[:line]} do
        {path, line} when is_binary(path) and is_integer(line) -> "#{path}:#{line}"
        {path, _} when is_binary(path) -> path
        _ -> "inline comment"
      end

    author = author_label(item[:author])
    "  * [#{loc}#{author}] #{one_line(item[:body])}"
  end

  defp render_item(_), do: nil

  defp author_label(author) when is_binary(author) and author != "", do: " by @#{author}"
  defp author_label(_), do: ""

  defp one_line(body) when is_binary(body) do
    body |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  defp one_line(_), do: ""

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
