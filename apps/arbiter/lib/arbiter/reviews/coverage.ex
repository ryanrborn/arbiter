defmodule Arbiter.Reviews.Coverage do
  @moduledoc """
  P0 of `docs/review-coverage-and-guard-policy.md` (design #1635), §3.1/§3.3.

  `record/1` is the **only** writer of `Arbiter.Reviews.Coverage.Entry`
  rows. It is idempotent on `{mr_ref, head_sha, kind}` — a second identical
  call returns the existing row rather than inserting a duplicate, so every
  call site in §3.3 can call it unconditionally without first checking
  whether coverage already exists.

  P1 (#1648) wires the three **review** sites of §3.3's stamping table to
  `record/1` — `Arbiter.Worker.ReviewGate`'s clean approve,
  `Arbiter.Workflows.ReviewPatrol`'s post-review and
  `Arbiter.Reviews.ExternalReview`'s baseline. Nothing READS the table yet:
  `decide/3` (§3.2) and the guard rewrites that consume it are P3/P4, and
  `issues.last_reviewed_sha` remains the authoritative input to every merge
  guard until then.
  """

  require Ash.Query

  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Tasks.Issue

  @type attrs :: %{
          required(:task_id) => String.t(),
          required(:mr_ref) => String.t(),
          required(:head_sha) => String.t(),
          required(:base_ref) => String.t(),
          required(:net_diff_id) => String.t(),
          required(:kind) => :reviewed | :mechanical | :operator,
          required(:source) =>
            :review_gate | :review_patrol | :external_review | :watchdog | :cli,
          optional(:round) => integer() | nil,
          optional(:derived_from) => String.t() | nil,
          optional(:covered_at) => DateTime.t()
        }

  @doc """
  Record a coverage entry, or return the existing one if `{mr_ref, head_sha,
  kind}` was already recorded.

  A `:mechanical` row requires `derived_from`; any other kind must leave it
  nil. `head_sha` must be 40 hex characters. Both are rejected by the
  resource's create action and surfaced here as `{:error, _}`.
  """
  @spec record(attrs()) :: {:ok, Entry.t()} | {:error, term()}
  def record(attrs) do
    attrs = Map.new(attrs)

    case fetch_existing(attrs) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        Entry
        |> Ash.Changeset.for_create(:record, attrs)
        |> Ash.create()
        |> case do
          {:ok, entry} -> {:ok, entry}
          {:error, error} -> retry_on_conflict(error, attrs)
        end
    end
  end

  defp retry_on_conflict(error, attrs) do
    if unique_conflict?(error) do
      case fetch_existing(attrs) do
        {:ok, entry} -> {:ok, entry}
        :error -> {:error, error}
      end
    else
      {:error, error}
    end
  end

  defp fetch_existing(%{mr_ref: mr_ref, head_sha: head_sha, kind: kind}) do
    Entry
    |> Ash.Query.filter(mr_ref == ^mr_ref and head_sha == ^head_sha and kind == ^kind)
    |> Ash.read_one()
    |> case do
      {:ok, %Entry{} = entry} -> {:ok, entry}
      _ -> :error
    end
  end

  defp fetch_existing(_attrs), do: :error

  defp unique_conflict?(%Ash.Error.Invalid{errors: errors}), do: Enum.any?(errors, &conflict?/1)
  defp unique_conflict?(_), do: false

  # The identity's `eager_check?: true` raises this shape on a duplicate
  # {mr_ref, head_sha, kind}; a DB-level unique-index hit under a genuine
  # race surfaces the same struct via the sqlite adapter's constraint match.
  defp conflict?(%Ash.Error.Changes.InvalidChanges{fields: fields}),
    do: :mr_ref in fields and :head_sha in fields and :kind in fields

  defp conflict?(_), do: false

  @doc """
  The **authoring** task id for a coverage row about `mr_ref`, per §3.1
  ("`task_id` — the authoring task (not the reviewer/watchdog task)").

  A review engagement (`review_only: true`) is the *reviewer's* task, not the
  author's, so the reviewing sites cannot use their own id. When the fleet
  authored the PR there is a real task carrying it as `pr_ref`; that id is the
  answer. For a genuinely external PR — the common ReviewPatrol /
  ExternalReview case — no such task exists and `fallback` (the engagement) is
  used, which is the only durable handle we have on that review.

  Never raises: a failed read resolves to `fallback`, so a transient DB blip
  costs a less-precise `task_id`, not a lost coverage row.
  """
  @spec authoring_task_id(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  def authoring_task_id(mr_ref, workspace_id, fallback)
      when is_binary(mr_ref) and mr_ref != "" and is_binary(workspace_id) do
    Issue
    |> Ash.Query.filter(
      pr_ref == ^mr_ref and workspace_id == ^workspace_id and review_only != true
    )
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Issue{id: id} | _] -> id
      _ -> fallback
    end
  rescue
    _ -> fallback
  end

  def authoring_task_id(_mr_ref, _workspace_id, fallback), do: fallback
end
