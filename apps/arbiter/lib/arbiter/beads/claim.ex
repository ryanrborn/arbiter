defmodule Arbiter.Beads.Claim do
  @moduledoc """
  Bridges GitHub issues ↔ beads via the "claim then bead" model.

  GitHub issues are the shared backlog; *assignment is the claim*. A bead is
  created only for an issue assigned to the workspace's GitHub user — so the
  fleet never beads work someone else owns.

  Two operations:

    * `claim/3` — fetch one issue by ref and create a linked bead (idempotent).
    * `plan/1` + `apply_plan/3` — reconcile assigned-to-viewer open issues
      against open beads, in both directions.

  Both no-op cleanly when the workspace's tracker is anything other than
  `:github`.
  """

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Trackers.GitHub

  require Ash.Query

  @typedoc "Outcome of a single claim attempt."
  @type claim_result ::
          {:ok, :created | :existing, Issue.t()}
          | {:error, atom() | String.t() | map()}

  @typedoc "A planned reconciliation action."
  @type action ::
          {:create, ref :: String.t(), summary :: map()}
          | {:close, issue_id :: String.t(), reason :: String.t()}

  @typedoc "Outcome of applying a single planned action."
  @type action_result ::
          {:created, Issue.t()}
          | {:closed, Issue.t()}
          | {:error, action(), term()}

  @doc """
  Claim a GitHub issue: fetch it via the workspace tracker, refuse unless it
  is assigned to the workspace's GitHub user (overridable with `force: true`),
  and create a bead linked by `tracker_ref`. Idempotent: returns the existing
  bead if one already references the issue.

  Options:

    * `:force` — when `true`, skip the assignment-as-claim check.

  Returns:

    * `{:ok, :created, %Issue{}}` — a new bead was inserted.
    * `{:ok, :existing, %Issue{}}` — a bead for this ref already existed.
    * `{:error, :tracker_not_github}` — the workspace's tracker is not GitHub.
    * `{:error, :not_assigned, login}` — the issue isn't assigned to the
      workspace viewer.
    * `{:error, term}` — surface from the tracker adapter or Ash.
  """
  @spec claim(Workspace.t(), String.t(), keyword()) :: claim_result
  def claim(%Workspace{} = workspace, ref, opts \\ []) when is_binary(ref) do
    force? = Keyword.get(opts, :force, false)

    with :ok <- ensure_github_tracker(workspace),
         {:ok, ref} <- normalize_ref(ref),
         {:ok, issue_map} <- in_workspace(workspace, fn -> GitHub.fetch(ref) end),
         :ok <- check_assignment(workspace, issue_map, force?) do
      case find_existing(workspace, ref) do
        {:ok, bead} ->
          {:ok, :existing, bead}

        :none ->
          create_bead(workspace, ref, issue_map)
      end
    end
  end

  @doc """
  Build a reconcile plan for the workspace. Two directions:

    * issue assigned to viewer + open + no open bead → `{:create, ref, summary}`.
    * open bead with a github ref whose issue is unassigned (or closed) →
      `{:close, bead_id, reason}`.

  Returns `{:ok, plan}` or `{:error, reason}`. `plan` is an empty list when
  the workspace tracker isn't GitHub.
  """
  @spec plan(Workspace.t()) :: {:ok, [action()]} | {:error, term()}
  def plan(%Workspace{} = workspace) do
    case ensure_github_tracker(workspace) do
      :ok -> build_plan(workspace)
      {:error, :tracker_not_github} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  @doc """
  Execute a previously-built `plan/1`. Each action is attempted independently;
  failures are reported per-action but do not halt the rest of the plan.

  Returns `{:ok, [action_result]}` — the per-action results in the same order
  as the input plan.
  """
  @spec apply_plan(Workspace.t(), [action()], keyword()) :: {:ok, [action_result]}
  def apply_plan(%Workspace{} = workspace, plan, _opts \\ []) when is_list(plan) do
    results =
      in_workspace(workspace, fn ->
        Enum.map(plan, &apply_action(workspace, &1))
      end)

    {:ok, results}
  end

  # ---- internals: claim ----------------------------------------------------

  defp create_bead(workspace, ref, issue_map) do
    attrs = %{
      title: title_for(issue_map),
      description: description_for(issue_map),
      tracker_type: :github,
      tracker_ref: ref,
      workspace_id: workspace.id
    }

    case Ash.create(Issue, attrs) do
      {:ok, bead} -> {:ok, :created, bead}
      {:error, err} -> {:error, err}
    end
  end

  defp title_for(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp title_for(_), do: "(no title)"

  defp description_for(%{"body" => body}) when is_binary(body), do: body
  defp description_for(_), do: ""

  defp find_existing(workspace, ref) do
    query =
      Issue
      |> Ash.Query.filter(
        workspace_id == ^workspace.id and tracker_type == :github and tracker_ref == ^ref
      )

    case Ash.read(query) do
      {:ok, [bead | _]} -> {:ok, bead}
      {:ok, []} -> :none
      {:error, _} = err -> err
    end
  end

  defp check_assignment(_workspace, _issue_map, true), do: :ok

  defp check_assignment(workspace, issue_map, false) do
    case viewer_login_cached(workspace) do
      {:ok, login} ->
        if login in GitHub.assignee_logins(issue_map) do
          :ok
        else
          {:error, {:not_assigned, login}}
        end

      {:error, _} = err ->
        err
    end
  end

  # ---- internals: plan -----------------------------------------------------

  defp build_plan(workspace) do
    with {:ok, login} <- viewer_login_cached(workspace),
         {:ok, assigned_issues} <-
           in_workspace(workspace, fn -> GitHub.list_assigned_open_issues(login) end) do
      assigned_by_ref =
        Map.new(assigned_issues, fn issue ->
          {to_string(issue["number"]), issue}
        end)

      open_github_beads = read_open_github_beads(workspace)
      bead_by_ref = Map.new(open_github_beads, &{&1.tracker_ref, &1})

      creates =
        for {ref, issue} <- assigned_by_ref, not Map.has_key?(bead_by_ref, ref) do
          {:create, ref,
           %{
             number: issue["number"],
             title: title_for(issue),
             html_url: issue["html_url"]
           }}
        end

      closes =
        for {ref, bead} <- bead_by_ref, not Map.has_key?(assigned_by_ref, ref) do
          # The bead's ref isn't in the assigned-to-viewer open set. Either the
          # issue was closed on GitHub, or it was reassigned away from the
          # viewer. Either way: the bead should close. We re-fetch the issue
          # to capture the precise reason for the audit trail.
          reason =
            case in_workspace(workspace, fn -> GitHub.fetch(ref) end) do
              {:ok, issue} ->
                cond do
                  GitHub.issue_status(issue) == :closed ->
                    "tracker issue ##{ref} closed"

                  GitHub.assignee_logins(issue) == [] ->
                    "tracker issue ##{ref} unassigned"

                  true ->
                    "tracker issue ##{ref} reassigned to #{Enum.join(GitHub.assignee_logins(issue), ", ")}"
                end

              {:error, _} ->
                "tracker issue ##{ref} no longer assigned"
            end

          {:close, bead.id, reason}
        end

      {:ok, Enum.sort(creates ++ closes, &action_order/2)}
    end
  end

  defp action_order({:create, a, _}, {:create, b, _}), do: a <= b
  defp action_order({:close, a, _}, {:close, b, _}), do: a <= b
  defp action_order({:create, _, _}, {:close, _, _}), do: true
  defp action_order({:close, _, _}, {:create, _, _}), do: false

  defp read_open_github_beads(workspace) do
    query =
      Issue
      |> Ash.Query.filter(
        workspace_id == ^workspace.id and tracker_type == :github and status != :closed and
          not is_nil(tracker_ref)
      )

    case Ash.read(query) do
      {:ok, list} -> list
      _ -> []
    end
  end

  # ---- internals: apply ---------------------------------------------------

  defp apply_action(workspace, {:create, ref, _summary} = action) do
    case claim(workspace, ref) do
      {:ok, :created, bead} -> {:created, bead}
      {:ok, :existing, bead} -> {:created, bead}
      {:error, reason} -> {:error, action, reason}
    end
  end

  defp apply_action(_workspace, {:close, bead_id, reason} = action) do
    with {:ok, bead} <- Ash.get(Issue, bead_id),
         {:ok, closed} <-
           Ash.update(bead, %{reason: reason}, action: :close) do
      {:closed, closed}
    else
      {:error, reason} -> {:error, action, reason}
    end
  end

  # ---- internals: viewer caching ------------------------------------------

  # The viewer login is workspace-scoped (resolves against the workspace's
  # token) and stable for the duration of a request, so we look it up once and
  # cache in the process dict to avoid hitting /user multiple times during a
  # single sync.
  defp viewer_login_cached(workspace) do
    key = {__MODULE__, :viewer_login, workspace.id}

    case Process.get(key) do
      {:ok, login} ->
        {:ok, login}

      _ ->
        case in_workspace(workspace, &GitHub.viewer_login/0) do
          {:ok, login} = ok ->
            Process.put(key, ok)
            {:ok, login}

          {:error, _} = err ->
            err
        end
    end
  end

  # ---- internals: helpers --------------------------------------------------

  defp ensure_github_tracker(%Workspace{config: config}) do
    case get_in(config || %{}, ["tracker", "type"]) do
      "github" -> :ok
      _ -> {:error, :tracker_not_github}
    end
  end

  defp normalize_ref(ref) when is_binary(ref) do
    case GitHub.parse_ref(ref) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_ref, ref}}
    end
  end

  defp in_workspace(workspace, fun), do: GitHub.with_workspace(workspace, fun)
end
