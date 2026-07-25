defmodule Arbiter.Tasks.Dedup do
  @moduledoc """
  Duplicate-title pre-check shared by every front door that files a new issue.

  Filing the same issue twice is easy to do and annoying to undo (two ids, two
  tracker issues, possibly two workers). Before creating, we look for an
  already-open issue with the same title in the same workspace, and — when the
  workspace has a tracker and we're about to mirror into it — for an open
  upstream issue with the same title.

  This started as private helpers inside `ArbiterWeb.Api.IssueController`; it
  lives here so the REST API and the dashboard's create form apply the exact
  same rule rather than drifting apart.

  Returns:

    * `:ok` — no duplicate found, or the check doesn't apply (blank title /
      workspace, `force: true`).
    * `{:local_dup, [Issue.t()]}` — open local issues with the same title.
    * `{:tracker_dup, [map()]}` — open upstream issues with the same title.
      Each map has `:ref`, `:title` and `:url` keys.

  A duplicate is advisory, not fatal: every caller offers a `force` escape
  hatch (`--force` on the CLI, `"force" => true` on the REST API, the "Create
  anyway" button on the dashboard).

  The tracker leg makes a network call, so callers on a latency-sensitive path
  (a LiveView) should run `check/3` off the caller process.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Trackers

  require Ash.Query

  @type result :: :ok | {:local_dup, [Issue.t()]} | {:tracker_dup, [map()]}

  @doc """
  Check `title` for duplicates in `workspace_id`.

  Options:

    * `:force` — skip the check entirely (default `false`).
    * `:skip_upstream_create` — the caller isn't mirroring upstream, so the
      tracker leg is pointless (default `false`).
    * `:tracker_ref` — the caller is binding to an existing upstream issue, so
      the tracker leg is pointless.
  """
  @spec check(String.t() | nil, String.t() | nil, keyword()) :: result()
  def check(title, workspace_id, opts \\ []) do
    if Keyword.get(opts, :force, false) do
      :ok
    else
      with :ok <- check_local(title, workspace_id) do
        check_tracker(title, workspace_id, opts)
      end
    end
  end

  @doc """
  Open local issues in `workspace_id` whose title matches `title`
  case-insensitively (after trimming). `[]` when the check doesn't apply.
  """
  @spec local_matches(String.t() | nil, String.t() | nil) :: [Issue.t()]
  def local_matches(title, workspace_id) when is_binary(title) and is_binary(workspace_id) do
    norm = normalize_title(title)

    query =
      Issue
      |> Ash.Query.new()
      |> Ash.Query.filter(status in [:open, :in_progress] and workspace_id == ^workspace_id)

    case Ash.read(query) do
      {:ok, issues} -> Enum.filter(issues, &(normalize_title(&1.title) == norm))
      {:error, _} -> []
    end
  end

  def local_matches(_title, _workspace_id), do: []

  defp check_local(title, workspace_id) do
    case local_matches(title, workspace_id) do
      [] -> :ok
      matches -> {:local_dup, matches}
    end
  end

  defp check_tracker(title, workspace_id, opts)
       when is_binary(title) and is_binary(workspace_id) do
    cond do
      Keyword.get(opts, :skip_upstream_create, false) == true ->
        :ok

      is_binary(Keyword.get(opts, :tracker_ref)) and Keyword.get(opts, :tracker_ref) != "" ->
        :ok

      true ->
        search_tracker(title, workspace_id)
    end
  end

  defp check_tracker(_title, _workspace_id, _opts), do: :ok

  defp search_tracker(title, workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, workspace} ->
        case Trackers.search_by_title_for_workspace(workspace, title) do
          {:ok, []} -> :ok
          {:ok, matches} -> {:tracker_dup, matches}
          _ -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  @doc "Describe a dedup result as one operator-facing line. `nil` for `:ok`."
  @spec message(result()) :: String.t() | nil
  def message(:ok), do: nil

  def message({:local_dup, matches}) do
    ids = Enum.map_join(matches, ", ", & &1.id)
    "an open issue with this title already exists (#{ids})"
  end

  def message({:tracker_dup, matches}) do
    refs = Enum.map_join(matches, ", ", &(Map.get(&1, :url) || Map.get(&1, :ref) || "?"))
    "an open tracker issue with this title already exists (#{refs})"
  end

  defp normalize_title(title), do: title |> String.downcase() |> String.trim()
end
