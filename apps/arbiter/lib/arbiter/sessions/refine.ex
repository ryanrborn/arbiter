defmodule Arbiter.Sessions.Refine do
  @moduledoc """
  The **Refine** entry point: launch (or reopen) *the* agent session bound to
  one Backlog issue (bd-1lszsc, child 3 of epic bd-cksar2).

  An unrefined issue is a sentence someone typed. Turning it into something a
  worker can be dispatched at — a real description, acceptance criteria that
  can be checked, a difficulty, the children it should be split into, the
  edges that order them — is a conversation, and this is where that
  conversation gets an agent. `open/2` is the one door: the issue detail page's
  Refine button and the board card's both call it, and so would anything else
  that wants one.

  ## One live session per issue

  Two things hold that rule, at two different distances from the operator:

    1. `live_session/1` — the fast path. A second click finds the session the
       first one launched and reopens it in the dock.
    2. `sessions_live_issue_binding_index` — a partial unique index on
       `sessions.issue_id WHERE status != 'ended'`. A *concurrent* double
       click, where both requests read "no session" before either writes one,
       loses the race at the database instead. The loser re-reads and returns
       the winner's session, so both clicks still end up in the same place.

  Ending a session drops its row out of that index, which is what makes a
  killed refine session re-openable rather than a permanent lockout.

  ## What the session gets, and why

    * **A `:refine`-tier MCP token, bound to this issue and workspace** (child 1,
      bd-3uy2hn). Not a decision made here — `Arbiter.Sessions.Provisioning.mint_token/2`
      takes it from the row's `issue_id`, so the binding and the token cannot
      drift apart. A refine token can read broadly, write only inside the bound
      issue's `parent_of` subtree, and never dispatch.
    * **Child 2's refine instructions** (bd-980x89), rendered into the session's
      cwd as `CLAUDE.md` and `AGENTS.md` with this issue, its epic, its edges,
      its workspace and its checkout path filled in.
    * **A read-only checkout of the issue's repo**
      (`Arbiter.Sessions.RepoCheckout`) — for grep and read grounding, nothing
      else. An issue with no repo, or a repo this workspace never registered,
      simply gets no checkout and instructions that say so.

  ## Premium tier, never flagship, thinking `high`

  The model is pinned here rather than routed. `Arbiter.Agents.Routing` exists
  to price *dispatched work* by difficulty, and a refine session has no
  difficulty — the whole point of the conversation is to work out what the
  difficulty is. Running it through the routing policies would mean a D5 issue
  refines on the flagship tier, which is precisely the escalation the epic
  rules out: flagship is a deliberate operator choice for one expensive
  dispatch, not the default rung for an open-ended chat.

  So `model/1` asks the workspace for its `premium` tier model (falling back to
  the built-in default) and nothing else. `"flagship"` is never a tier this
  module looks up, under any config — the workspace's routing rules are not
  consulted at all, so there is no path by which they could select it.

  Thinking is `high`, chosen over `xhigh`/`max`: refinement is
  reasoning-heavy in bursts — decomposing an epic, arguing about what
  acceptance can actually be checked — but it is also a conversation, and most
  turns in it are short. `xhigh`/`max` pay the deepest reasoning budget on
  every turn including "yes, that one", which burns a quota window on an
  interactive session that may run for an hour. `high` is the level that is
  still genuinely deliberative on the turns that need it.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Agents.Claude.Config, as: ClaudeConfig
  alias Arbiter.Sessions
  alias Arbiter.Sessions.Session
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace

  # See the moduledoc's last section for why this level and not a higher one.
  @thinking "high"

  # The tier a refine session runs on. A module attribute rather than a literal
  # at the call site so the one thing this must never be — `"flagship"` — is
  # visible in one place.
  @model_tier "premium"

  @typedoc "What `open/2` hands back: the session, and whether it already existed."
  @type opened :: %{session: Session.t(), reopened?: boolean()}

  @doc """
  Whether `issue` can be refined — the predicate both UI entry points render
  from, so "where the button appears" has exactly one definition.

  Backlog only: an issue that has been promoted (`refined`) has already had
  this conversation, one that is `in_progress` has a worker on it, and a closed
  or awaiting-verification one is past the point where shaping it means
  anything.
  """
  @spec eligible?(Issue.t() | nil) :: boolean()
  def eligible?(%Issue{status: :open, refined: false}), do: true
  def eligible?(_issue), do: false

  @doc """
  The live refine session bound to `issue_id`, if there is one.

  "Live" means the row is not `:ended` — `:starting` counts, because a session
  whose scope is still coming up is exactly the one a second click must not
  duplicate.
  """
  @spec live_session(String.t() | nil) :: {:ok, Session.t()} | :none
  def live_session(nil), do: :none
  def live_session(""), do: :none

  def live_session(issue_id) when is_binary(issue_id) do
    Session
    |> Ash.Query.filter(issue_id == ^issue_id and status != :ended)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [session] -> {:ok, session}
      [] -> :none
    end
  end

  @doc """
  Open the refine session for `issue`: reopen the live one if there is one,
  otherwise launch it.

  Returns `{:ok, %{session: session, reopened?: boolean}}`. `reopened?` is what
  the caller needs to tell the operator whether they are looking at a fresh
  session or the one they left — the dock does the same thing either way.

  `{:error, :not_refinable}` for an issue outside Backlog, and
  `{:error, :no_workspace}` for one with no workspace: a refine token is bound
  to a workspace *and* an issue, and neither binding is optional (child 1
  refuses to decode a token missing either).

  Every other option is passed straight through to `Arbiter.Sessions.launch/1`
  — `:runner` for tests, and anything a future caller needs — except the ones
  this function owns: `:name`, `:issue_id`, `:workspace_id`, `:can_dispatch`,
  `:refine`, `:model` and `:thinking`.
  """
  @spec open(Issue.t() | String.t(), keyword()) :: {:ok, opened()} | {:error, term()}
  def open(issue, opts \\ [])

  def open(issue_id, opts) when is_binary(issue_id) do
    case Ash.get(Issue, issue_id) do
      {:ok, issue} -> open(issue, opts)
      {:error, _} -> {:error, :issue_not_found}
    end
  end

  def open(%Issue{} = issue, opts) do
    cond do
      not eligible?(issue) -> {:error, :not_refinable}
      blank?(issue.workspace_id) -> {:error, :no_workspace}
      true -> open_eligible(issue, opts)
    end
  end

  @doc """
  The session's display name — `Refine <id>: <title>`.

  Passed through to `claude --name` at launch, so the dock's title bar, the
  `/sessions` list and the CLI's own `/resume` picker all agree on what this
  session is for without anybody having to open it.
  """
  @spec display_name(Issue.t()) :: String.t()
  def display_name(%Issue{id: id, title: title}) do
    case title do
      t when is_binary(t) and t != "" -> "Refine #{id}: #{t}"
      _ -> "Refine #{id}"
    end
  end

  @doc """
  The concrete model a refine session runs on: `workspace`'s `premium` tier
  model, or the built-in default when it defines none.

  Never consults `"flagship"`, and never consults the workspace's routing
  rules — see the moduledoc.
  """
  @spec model(Workspace.t() | nil) :: String.t() | nil
  def model(nil), do: default_model()

  def model(%Workspace{} = workspace) do
    # `put_active/1` writes the process dictionary, and this runs inside a
    # LiveView (or whatever else clicked Refine). Resolving in a throwaway task
    # keeps the caller's own active-agent config — whatever it is — untouched.
    #
    # A workspace whose agent config cannot be read at all (undecryptable
    # secrets, say) must not take the caller down with it: the whole answer
    # this function owes is "which premium model", and the built-in default is
    # a correct one. So the task's exit is caught rather than propagated.
    resolved =
      try do
        Task.async(fn ->
          ClaudeConfig.put_active(workspace)
          ClaudeConfig.model_for_tier(@model_tier)
        end)
        |> Task.await(5_000)
      catch
        :exit, reason ->
          Logger.warning(
            "Sessions.Refine: could not resolve the #{@model_tier} model for workspace " <>
              "#{workspace.id} (#{inspect(reason)}); falling back to the built-in default"
          )

          nil
      end

    resolved || default_model()
  end

  @doc "The thinking level a refine session runs at. See the moduledoc."
  @spec thinking() :: String.t()
  def thinking, do: @thinking

  # ---- internals ----------------------------------------------------------

  defp open_eligible(%Issue{} = issue, opts) do
    case live_session(issue.id) do
      {:ok, session} -> {:ok, %{session: session, reopened?: true}}
      :none -> launch(issue, opts)
    end
  end

  defp launch(%Issue{} = issue, opts) do
    workspace = workspace(issue.workspace_id)

    launch_opts =
      opts
      |> Keyword.drop([
        :name,
        :issue_id,
        :workspace_id,
        :can_dispatch,
        :refine,
        :model,
        :thinking
      ])
      |> Keyword.merge(
        name: display_name(issue),
        issue_id: issue.id,
        workspace_id: issue.workspace_id,
        can_dispatch: false,
        refine: refine_context(issue, workspace),
        model: model(workspace),
        thinking: thinking()
      )

    case safe_launch(launch_opts) do
      {:ok, session} ->
        {:ok, %{session: session, reopened?: false}}

      {:error, reason} ->
        # The one error worth a second look: a concurrent click that lost the
        # race at `sessions_live_issue_binding_index`. The winner's row is
        # committed by the time our insert was refused, so re-reading is not a
        # retry loop — it is reading the answer that now exists.
        case live_session(issue.id) do
          {:ok, session} ->
            {:ok, %{session: session, reopened?: true}}

          :none ->
            {:error, reason}
        end
    end
  end

  # An insert refused by a plain database index (rather than by a declared Ash
  # identity) surfaces as a raise, not an `{:error, _}`. Both shapes mean the
  # same thing here, so both are funnelled into one.
  defp safe_launch(launch_opts) do
    Sessions.launch(launch_opts)
  rescue
    error -> {:error, error}
  end

  defp workspace(nil), do: nil

  defp workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, workspace} -> workspace
      {:error, _} -> nil
    end
  end

  # The `:refine` map `Arbiter.Sessions.Instructions.render/2` renders from
  # (child 2), plus the two keys `Arbiter.Sessions.Provisioning` needs to build
  # the checkout it then reports back as `:repo_checkout`.
  defp refine_context(%Issue{} = issue, workspace) do
    groups = Dependencies.for_issue(issue.id)
    {repo_path, repo_branch} = repo_target(workspace, issue.repo)

    %{
      issue: issue,
      epic: epic(groups),
      edges: edges(groups),
      workspace: workspace,
      repo_path: repo_path,
      repo_branch: repo_branch
    }
  end

  # The parent this issue hangs under. An epic-typed parent wins where there is
  # one, since that is the thing the refine instructions call "the parent
  # epic"; otherwise the first parent, which is still the context the agent
  # needs.
  defp epic(groups) do
    parents = groups |> Map.get(:parents, []) |> Enum.map(& &1.issue) |> Enum.reject(&is_nil/1)

    Enum.find(parents, &(&1.issue_type == :epic)) || List.first(parents)
  end

  # `Dependencies.for_issue/1` groups edges by the **role** the other endpoint
  # plays (`:blocked_by`, `:children`, …) rather than by raw row direction,
  # precisely because direction alone is misleading — an epic's `:parent_of`
  # children and its `:depends_on` blockers are both outbound rows and mean
  # opposite things. So the role is what goes in `:type`, and `:direction`
  # carries a plain arrow rather than re-exposing the raw direction the
  # grouping just finished hiding: "`blocked_by` → `bd-x`" is unambiguous,
  # where "`blocked_by` outbound `bd-x`" invites the reader to work out which
  # of the two facts wins.
  defp edges(groups) do
    groups
    |> Enum.flat_map(fn {group, entries} ->
      Enum.map(entries, fn entry ->
        %{
          type: group,
          direction: "→",
          id: entry.issue_id,
          title: (entry.issue && entry.issue.title) || "(unreadable)"
        }
      end)
    end)
  end

  # `{path, branch}` for the issue's repo as this workspace registers it, or
  # `{nil, nil}` — an unregistered repo is a gap in config, not a launch
  # failure. `Arbiter.Sessions.RepoCheckout` treats a nil path as "no
  # checkout", which is the same outcome as an issue with no repo at all.
  defp repo_target(nil, _repo), do: {nil, nil}
  defp repo_target(_workspace, repo) when not is_binary(repo) or repo == "", do: {nil, nil}

  defp repo_target(%Workspace{config: config}, repo) do
    paths = Map.get(config || %{}, "repo_paths") || %{}

    case RepoConfig.find_entry(paths, repo) do
      nil ->
        {nil, nil}

      entry ->
        case RepoConfig.repo_path_from_config(entry) do
          nil -> {nil, nil}
          path -> {path, RepoConfig.repo_target_from_config(entry) || "main"}
        end
    end
  end

  defp default_model, do: Map.get(ClaudeConfig.default_tier_models(), @model_tier)

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")
end
