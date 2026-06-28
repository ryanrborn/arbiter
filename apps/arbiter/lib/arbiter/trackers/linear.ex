defmodule Arbiter.Trackers.Linear do
  @moduledoc """
  Linear adapter implementing `Arbiter.Trackers.Tracker`.

  Wraps Linear's GraphQL API (`https://api.linear.app/graphql`) for issue
  fetch/create/update/transition flows, so directives can sync to Linear
  issues. `create/1` uses the `issueCreate` mutation and returns the new
  issue's identifier (e.g. `"ENG-123"`) as the canonical ref.

  ## Active-workspace contract

  The `Tracker` behaviour callbacks take a `ref` (the issue identifier, e.g.
  `"ENG-123"`) with no workspace context. Linear needs an API token, an
  optional team ID, and a task-status → state-name mapping — all
  workspace-scoped. We resolve those through `Arbiter.Trackers.Linear.Config`:

    1. Callers (request middleware, CLI command, scheduler job) call
       `Config.put_active(workspace)` to populate the per-process config.
    2. `Application.get_env(:arbiter, :linear_tracker_default_config)` is the
       fallback for tools that run without a workspace context.
    3. With neither, callbacks return `{:error, %Error{kind: :config_missing}}`.

  ## `ref`

  The canonical ref is the issue identifier as a string (e.g. `"ENG-123"`),
  which is the team key + hyphen + number. Linear also exposes a UUID per
  issue, but the identifier is more ergonomic for humans and is stable.
  `parse_ref/1` accepts the identifier, `"linear:"` / `"lin-"` prefixes, and
  full Linear issue URLs.

  ## Auth

  Linear authenticates with a plain `Authorization: <token>` header — no
  `Bearer` prefix for API keys. OAuth tokens can be passed with the
  `Bearer` prefix embedded in the token value when using `credentials_ref`.

  ## Status mapping

  Linear workflow states are team-scoped and named. The adapter resolves the
  target state for a transition in two stages:

    1. If the workspace's `status_map` names a state for the task status, look
       up a state with that name in the team's workflow states.
    2. Otherwise, fall back to the Linear state `type` field:
         * `:open` → type `"unstarted"` or `"backlog"` (first match)
         * `:in_progress` / `:pr_opened` / `:approved_unmerged` → `"started"`
         * `:closed` / `:merged` → `"completed"`

  States with type `"triage"` or `"cancelled"` have no task-vocabulary
  equivalent and are never selected by the type-fallback path; they remain
  reachable via an explicit `status_map` entry.

  ## Optional callbacks

  * `add_comment/2` — posts a comment on the issue (Linear accepts Markdown
    natively, so no format conversion is needed).
  * `add_remote_link/3` — attaches a URL to the issue via Linear's
    `attachmentCreate` mutation (the canonical way to link a PR to a Linear
    ticket).
  * `check_prior_claim/1` — scans issue comments for the Arbiter ownership
    marker.
  * `signal_claim/3` — posts the ownership comment and assigns the viewer.

  ## Tests

  Wired up to `Req.Test`: when
  `Application.get_env(:arbiter, :linear_http_stub, false)` is true, every
  request injects `plug: {Req.Test, #{inspect(Arbiter.Trackers.Linear.HTTP)}}`.
  This adapter **never** hits the real Linear endpoint from tests.
  """

  @behaviour Arbiter.Trackers.Tracker

  alias Arbiter.Trackers.Linear.{Config, Error}

  @stub_name Arbiter.Trackers.Linear.HTTP

  # Linear state types that map to task-vocabulary atoms (used as fallback
  # when no explicit status_map entry is configured).
  @type_to_status %{
    "unstarted" => :open,
    "backlog" => :open,
    "started" => :in_progress,
    "completed" => :closed,
    "cancelled" => :closed
  }

  # Which Linear state types to prefer for each task status, in priority order.
  @status_type_preference %{
    open: ["unstarted", "backlog"],
    in_progress: ["started"],
    closed: ["completed"],
    pr_opened: ["started"],
    approved_unmerged: ["started"],
    merged: ["completed"]
  }

  # ---- Tracker behaviour ---------------------------------------------------

  @impl true
  def fetch(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve() do
      graphql(cfg, issue_query(), %{"id" => ref})
      |> extract_data(["issue"])
    end
  end

  @impl true
  def transition(ref, status) when is_binary(ref) and is_atom(status) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, raw_issue} <- fetch(ref),
         team_id = get_in(raw_issue, ["team", "id"]),
         {:ok, states} <- fetch_team_states(cfg, team_id),
         {:ok, state_id} <- resolve_state_id(cfg, states, status) do
      vars = %{"id" => raw_issue["id"], "stateId" => state_id}

      graphql(cfg, update_issue_mutation(), vars)
      |> extract_success(["issueUpdate"])
    end
  end

  @impl true
  def update_fields(ref, fields_map) when is_binary(ref) and is_map(fields_map) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, raw_issue} <- fetch(ref),
         payload <- translate_fields(fields_map),
         false <- map_size(payload) == 0 do
      vars = %{"id" => raw_issue["id"], "input" => payload}

      graphql(cfg, update_issue_mutation_fields(), vars)
      |> extract_success(["issueUpdate"])
    else
      true -> :ok
      err -> err
    end
  end

  @impl true
  def link_for(ref) when is_binary(ref) do
    case Config.resolve() do
      {:ok, %{org_url_key: key}} when is_binary(key) ->
        "https://linear.app/#{key}/issue/#{ref}"

      _ ->
        "https://linear.app/issue/#{ref}"
    end
  end

  @impl true
  def add_comment(ref, body) when is_binary(ref) and is_binary(body) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, raw_issue} <- fetch(ref) do
      vars = %{"issueId" => raw_issue["id"], "body" => body}

      graphql(cfg, create_comment_mutation(), vars)
      |> extract_success(["commentCreate"])
    end
  end

  @impl true
  def add_remote_link(ref, url, title)
      when is_binary(ref) and is_binary(url) and is_binary(title) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, raw_issue} <- fetch(ref) do
      vars = %{"issueId" => raw_issue["id"], "url" => url, "title" => title}

      graphql(cfg, create_attachment_mutation(), vars)
      |> extract_success(["attachmentCreate"])
    end
  end

  @impl true
  def parse_ref(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "linear:") ->
        s |> String.replace_prefix("linear:", "") |> validate_identifier()

      String.starts_with?(s, "lin-") ->
        s |> String.replace_prefix("lin-", "") |> validate_identifier()

      String.starts_with?(s, "http://") or String.starts_with?(s, "https://") ->
        case Regex.run(~r{/issue/([A-Z][A-Z0-9]*-\d+)}, s) do
          [_, id] -> {:ok, id}
          _ -> :error
        end

      true ->
        validate_identifier(s)
    end
  end

  def parse_ref(_), do: :error

  @impl true
  def list_open(opts) when is_list(opts) do
    with {:ok, cfg} <- Config.resolve() do
      filter = build_list_open_filter(cfg, opts)
      vars = %{"filter" => filter, "teamId" => cfg.team_id}

      case graphql(cfg, list_open_query(), vars) |> extract_data(["issues", "nodes"]) do
        {:ok, nodes} when is_list(nodes) ->
          {:ok, Enum.map(nodes, &summarize/1)}

        {:ok, _} ->
          {:ok, []}

        {:error, _} = err ->
          err
      end
    end
  end

  @impl true
  def list_transitions(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, raw_issue} <- fetch(ref),
         team_id = get_in(raw_issue, ["team", "id"]),
         {:ok, states} <- fetch_team_states(cfg, team_id) do
      atoms =
        states
        |> Enum.map(fn %{"type" => type} -> Map.get(@type_to_status, type) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, atoms}
    end
  end

  @impl true
  def create(attrs) when is_map(attrs) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, title} <- fetch_title(attrs),
         {:ok, team_id} <- resolve_team_id(cfg),
         {:ok, input} <- build_create_input(cfg, team_id, title, attrs) do
      case graphql(cfg, create_issue_mutation(), %{"input" => input}) do
        {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}} ->
          {:ok, issue["identifier"]}

        {:ok, %{"data" => %{"issueCreate" => %{"success" => false}}}} ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: nil,
             message: "Linear issueCreate returned success=false",
             raw: nil
           }}

        {:ok, %{"errors" => errors}} ->
          {:error, graphql_error(errors)}

        {:ok, resp} ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: nil,
             message: "unexpected issueCreate response",
             raw: resp
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  @impl true
  def current_user do
    with {:ok, cfg} <- Config.resolve() do
      case graphql(cfg, viewer_query(), %{}) |> extract_data(["viewer"]) do
        {:ok, %{"id" => id}} when is_binary(id) ->
          {:ok, id}

        {:ok, _other} ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: nil,
             message: "Linear viewer query returned no id",
             raw: nil
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  @impl true
  def assignees(%{"assignees" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.flat_map(fn
      %{"id" => id} when is_binary(id) -> [id]
      _ -> []
    end)
    |> Enum.uniq()
  end

  def assignees(_), do: []

  @impl true
  def issue_status(%{"state" => %{"type" => type}}) do
    Map.get(@type_to_status, type, :open)
  end

  def issue_status(_), do: :open

  @impl true
  def extract_title(%{"title" => title}) when is_binary(title) and title != "", do: title
  def extract_title(_), do: "(no title)"

  @impl true
  def extract_description(%{"description" => desc}) when is_binary(desc), do: desc
  def extract_description(_), do: ""

  @ownership_marker "Arbiter installation:"

  @impl true
  def check_prior_claim(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, raw_issue} <- fetch(ref) do
      case graphql(cfg, issue_comments_query(), %{"id" => raw_issue["id"]})
           |> extract_data(["issue", "comments", "nodes"]) do
        {:ok, comments} when is_list(comments) ->
          case Enum.find(comments, &String.contains?(&1["body"] || "", @ownership_marker)) do
            nil -> :ok
            %{"body" => body} -> {:error, {:already_claimed, body}}
          end

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  @impl true
  def signal_claim(ref, task_id, %{
        workspace_name: name,
        workspace_prefix: prefix,
        current_user: user_id,
        host: host
      }) do
    body = "Claimed as #{task_id} by #{name} (#{prefix}). #{@ownership_marker} #{host}."
    add_comment(ref, body)
    assign_user(ref, user_id)
    :ok
  end

  # ---- Public helpers ------------------------------------------------------

  @doc """
  Convenience: set the active workspace for the current process and run `fun`,
  restoring the previous config when `fun` returns. Mirrors
  `Arbiter.Trackers.GitHub.with_workspace/2`.
  """
  @spec with_workspace(map() | Arbiter.Tasks.Workspace.t(), (-> result)) :: result
        when result: any()
  def with_workspace(workspace_or_config, fun) when is_function(fun, 0) do
    prev = Process.get({Config, :active_workspace_config})
    Config.put_active(workspace_or_config)

    try do
      fun.()
    after
      if prev, do: Config.put_active(prev), else: Config.clear()
    end
  end

  @doc """
  Assign a user (by Linear user ID) to an issue.
  """
  @spec assign_user(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def assign_user(ref, user_id) when is_binary(ref) and is_binary(user_id) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, raw_issue} <- fetch(ref) do
      vars = %{"id" => raw_issue["id"], "assigneeId" => user_id}

      graphql(cfg, assign_user_mutation(), vars)
      |> extract_success(["issueUpdate"])
    end
  end

  # ---- Internals: status resolution ---------------------------------------

  defp resolve_state_id(cfg, states, status) do
    target_name = Map.get(cfg.status_map, status)
    preferred_types = Map.get(@status_type_preference, status, [])

    cond do
      is_binary(target_name) and target_name != "" ->
        case Enum.find(states, fn %{"name" => name} -> name == target_name end) do
          %{"id" => id} ->
            {:ok, id}

          nil ->
            {:error,
             %Error{
               kind: :transition_not_found,
               status: nil,
               message:
                 "no Linear state named #{inspect(target_name)} found in team's workflow states " <>
                   "(configured via status_map for #{inspect(status)})",
               raw: nil
             }}
        end

      preferred_types != [] ->
        case find_state_by_types(states, preferred_types) do
          {:ok, id} ->
            {:ok, id}

          :error ->
            {:error,
             %Error{
               kind: :transition_not_found,
               status: nil,
               message:
                 "no Linear state with type in #{inspect(preferred_types)} found " <>
                   "in team's workflow states for task status #{inspect(status)}",
               raw: nil
             }}
        end

      true ->
        {:error,
         %Error{
           kind: :transition_not_found,
           status: nil,
           message: "no state mapping for task status #{inspect(status)}",
           raw: nil
         }}
    end
  end

  defp find_state_by_types(states, types) do
    Enum.find_value(types, :error, fn type ->
      case Enum.find(states, fn %{"type" => t} -> t == type end) do
        %{"id" => id} -> {:ok, id}
        nil -> nil
      end
    end)
  end

  defp fetch_team_states(cfg, nil) do
    # No team_id — fetch states from the first available team
    case graphql(cfg, all_teams_states_query(), %{}) |> extract_data(["teams", "nodes"]) do
      {:ok, [%{"states" => %{"nodes" => states}} | _]} when is_list(states) ->
        {:ok, states}

      {:ok, []} ->
        {:error,
         %Error{
           kind: :not_found,
           status: nil,
           message: "no teams found in Linear organization",
           raw: nil
         }}

      {:ok, _} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  defp fetch_team_states(cfg, team_id) when is_binary(team_id) do
    case graphql(cfg, team_states_query(), %{"teamId" => team_id})
         |> extract_data(["team", "states", "nodes"]) do
      {:ok, states} when is_list(states) -> {:ok, states}
      {:ok, _} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  # ---- Internals: list_open -----------------------------------------------

  defp build_list_open_filter(cfg, opts) do
    base_filter = %{
      "state" => %{"type" => %{"nin" => ["completed", "cancelled"]}}
    }

    case Keyword.get(opts, :assignee, :viewer) do
      :viewer ->
        Map.put(base_filter, "assignee", %{"isMe" => %{"eq" => true}})

      login when is_binary(login) and login != "" ->
        Map.put(base_filter, "assignee", %{"id" => %{"eq" => login}})

      _ ->
        base_filter
    end
    |> maybe_filter_team(cfg.team_id)
  end

  defp maybe_filter_team(filter, nil), do: filter

  defp maybe_filter_team(filter, team_id) when is_binary(team_id),
    do: Map.put(filter, "team", %{"id" => %{"eq" => team_id}})

  defp summarize(%{"identifier" => identifier} = issue) do
    %{
      ref: identifier,
      title: Map.get(issue, "title", "(no title)"),
      url: Map.get(issue, "url"),
      status: issue_status(issue),
      assignees: assignees(issue),
      raw: issue
    }
  end

  defp summarize(issue) do
    %{
      ref: Map.get(issue, "id", ""),
      title: Map.get(issue, "title", "(no title)"),
      url: Map.get(issue, "url"),
      status: issue_status(issue),
      assignees: assignees(issue),
      raw: issue
    }
  end

  # ---- Internals: create --------------------------------------------------

  defp fetch_title(%{title: title}) when is_binary(title) and title != "", do: {:ok, title}
  defp fetch_title(%{"title" => title}) when is_binary(title) and title != "", do: {:ok, title}

  defp fetch_title(_),
    do:
      {:error,
       %Error{
         kind: :validation_failed,
         status: nil,
         message: "create requires a non-empty :title",
         raw: nil
       }}

  defp resolve_team_id(%{team_id: id}) when is_binary(id) and id != "", do: {:ok, id}

  defp resolve_team_id(cfg) do
    case graphql(cfg, all_teams_states_query(), %{}) |> extract_data(["teams", "nodes"]) do
      {:ok, [%{"id" => id} | _]} when is_binary(id) ->
        {:ok, id}

      {:ok, []} ->
        {:error,
         %Error{
           kind: :not_found,
           status: nil,
           message:
             "no team_id configured and no teams found in Linear organization. " <>
               "Set workspace.config[\"tracker\"][\"config\"][\"team_id\"].",
           raw: nil
         }}

      {:ok, _} ->
        {:error,
         %Error{
           kind: :config_missing,
           status: nil,
           message: "team_id not set in Linear config. " <>
             "Set workspace.config[\"tracker\"][\"config\"][\"team_id\"].",
           raw: nil
         }}

      {:error, _} = err ->
        err
    end
  end

  defp build_create_input(cfg, team_id, title, attrs) do
    description = pluck(attrs, [:description, "description"])
    assignee_id = pluck(attrs, [:assignee, "assignee"])
    status = pluck(attrs, [:status, "status"]) || :open
    priority = pluck(attrs, [:priority, "priority"])

    input =
      %{"teamId" => team_id, "title" => title}
      |> maybe_put("description", description)
      |> maybe_put("assigneeId", assignee_id)
      |> maybe_put_priority(priority)

    # Resolve initial state if a status_map entry or type mapping exists
    case resolve_initial_state(cfg, team_id, status) do
      {:ok, state_id} -> {:ok, Map.put(input, "stateId", state_id)}
      {:error, _} -> {:ok, input}
    end
  end

  defp resolve_initial_state(cfg, team_id, status) do
    with {:ok, states} <- fetch_team_states(cfg, team_id) do
      resolve_state_id(cfg, states, status)
    end
  end

  defp pluck(map, keys) do
    Enum.find_value(keys, fn k ->
      case Map.fetch(map, k) do
        {:ok, v} -> v
        :error -> nil
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Linear priority: 0=No priority, 1=Urgent, 2=High, 3=Medium, 4=Low
  # Task priority: 0..4 (0 highest). Map directly — the scales match closely.
  defp maybe_put_priority(payload, p) when is_integer(p) and p >= 0 and p <= 4,
    do: Map.put(payload, "priority", p)

  defp maybe_put_priority(payload, _), do: payload

  # ---- Internals: field translation ---------------------------------------

  @field_map %{
    title: "title",
    description: "description"
  }

  defp translate_fields(fields_map) do
    Enum.reduce(fields_map, %{}, fn {key, value}, acc ->
      atom_key = if is_atom(key), do: key, else: safe_atom(key)

      case Map.fetch(@field_map, atom_key) do
        {:ok, linear_key} -> Map.put(acc, linear_key, value)
        :error -> acc
      end
    end)
  end

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__unknown__
  end

  # ---- Internals: ref parsing ---------------------------------------------

  # Linear identifiers follow the pattern TEAM-123 where TEAM is 1+ uppercase
  # letters/digits (starting with a letter) and 123 is a positive integer.
  @identifier_re ~r/^[A-Z][A-Z0-9]*-\d+$/

  defp validate_identifier(s) when is_binary(s) do
    if Regex.match?(@identifier_re, s), do: {:ok, s}, else: :error
  end

  # ---- Internals: GraphQL -------------------------------------------------

  defp issue_query do
    """
    query Issue($id: String!) {
      issue(id: $id) {
        id
        identifier
        title
        description
        url
        state {
          id
          name
          type
        }
        assignees {
          nodes {
            id
            name
            email
          }
        }
        team {
          id
          key
        }
        comments(first: 0) {
          nodes {
            id
          }
        }
      }
    }
    """
  end

  defp issue_comments_query do
    """
    query IssueComments($id: String!) {
      issue(id: $id) {
        comments(first: 50) {
          nodes {
            id
            body
          }
        }
      }
    }
    """
  end

  defp viewer_query do
    """
    query {
      viewer {
        id
        name
        email
      }
    }
    """
  end

  defp team_states_query do
    """
    query TeamStates($teamId: String!) {
      team(id: $teamId) {
        states {
          nodes {
            id
            name
            type
          }
        }
      }
    }
    """
  end

  defp all_teams_states_query do
    """
    query {
      teams {
        nodes {
          id
          key
          name
          states {
            nodes {
              id
              name
              type
            }
          }
        }
      }
    }
    """
  end

  defp list_open_query do
    """
    query ListIssues($filter: IssueFilter) {
      issues(filter: $filter, first: 100) {
        nodes {
          id
          identifier
          title
          url
          state {
            id
            name
            type
          }
          assignees {
            nodes {
              id
              name
              email
            }
          }
        }
      }
    }
    """
  end

  defp update_issue_mutation do
    """
    mutation UpdateIssue($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) {
        success
        issue {
          id
          identifier
          state {
            id
            name
            type
          }
        }
      }
    }
    """
  end

  defp update_issue_mutation_fields do
    """
    mutation UpdateIssueFields($id: String!, $input: IssueUpdateInput!) {
      issueUpdate(id: $id, input: $input) {
        success
        issue {
          id
          identifier
        }
      }
    }
    """
  end

  defp create_issue_mutation do
    """
    mutation CreateIssue($input: IssueCreateInput!) {
      issueCreate(input: $input) {
        success
        issue {
          id
          identifier
        }
      }
    }
    """
  end

  defp create_comment_mutation do
    """
    mutation CreateComment($issueId: String!, $body: String!) {
      commentCreate(input: { issueId: $issueId, body: $body }) {
        success
        comment {
          id
        }
      }
    }
    """
  end

  defp create_attachment_mutation do
    """
    mutation CreateAttachment($issueId: String!, $url: String!, $title: String!) {
      attachmentCreate(input: { issueId: $issueId, url: $url, title: $title }) {
        success
        attachment {
          id
        }
      }
    }
    """
  end

  defp assign_user_mutation do
    """
    mutation AssignUser($id: String!, $assigneeId: String!) {
      issueUpdate(id: $id, input: { assigneeId: $assigneeId }) {
        success
      }
    }
    """
  end

  # ---- Internals: HTTP / GraphQL ------------------------------------------

  defp graphql(cfg, query, variables) do
    body = %{"query" => query, "variables" => variables}

    full_opts =
      [
        method: :post,
        url: cfg.base_url,
        headers: headers(cfg),
        json: body,
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(stub_opts())

    case Req.request(full_opts) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, http_error(status, resp_body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # Unwrap a successful GraphQL response body along a key path, returning the
  # value at the path or an error if any key is missing or GraphQL errors exist.
  defp extract_data({:ok, %{"errors" => [_ | _] = errors}}, _path) do
    {:error, graphql_error(errors)}
  end

  defp extract_data({:ok, %{"data" => data}}, path) when is_map(data) do
    case get_in(data, path) do
      nil ->
        {:error,
         %Error{
           kind: :graphql_error,
           status: nil,
           message: "GraphQL response missing data at #{inspect(path)}",
           raw: data
         }}

      value ->
        {:ok, value}
    end
  end

  defp extract_data({:ok, resp}, path) do
    {:error,
     %Error{
       kind: :graphql_error,
       status: nil,
       message: "unexpected GraphQL response shape; expected data at #{inspect(path)}",
       raw: resp
     }}
  end

  defp extract_data({:error, _} = err, _path), do: err

  # Check that a mutation response has `success: true`.
  defp extract_success({:ok, %{"errors" => [_ | _] = errors}}, _path) do
    {:error, graphql_error(errors)}
  end

  defp extract_success({:ok, %{"data" => data}}, path) when is_map(data) do
    case get_in(data, path) do
      %{"success" => true} ->
        :ok

      %{"success" => false} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: nil,
           message: "Linear mutation at #{inspect(path)} returned success=false",
           raw: get_in(data, path)
         }}

      nil ->
        {:error,
         %Error{
           kind: :graphql_error,
           status: nil,
           message: "GraphQL response missing mutation result at #{inspect(path)}",
           raw: data
         }}

      other ->
        {:error,
         %Error{
           kind: :graphql_error,
           status: nil,
           message: "unexpected mutation result shape",
           raw: other
         }}
    end
  end

  defp extract_success({:ok, resp}, path) do
    {:error,
     %Error{
       kind: :graphql_error,
       status: nil,
       message: "unexpected GraphQL response; expected mutation result at #{inspect(path)}",
       raw: resp
     }}
  end

  defp extract_success({:error, _} = err, _path), do: err

  defp headers(%{token: token}) do
    [
      {"authorization", token},
      {"content-type", "application/json"},
      {"user-agent", "arbiter"}
    ]
  end

  defp graphql_error([%{"message" => msg} | _]) do
    %Error{kind: :graphql_error, status: nil, message: msg, raw: nil}
  end

  defp graphql_error(errors) do
    %Error{kind: :graphql_error, status: nil, message: "GraphQL error", raw: errors}
  end

  defp http_error(status, body) do
    %Error{
      kind: kind_for_status(status),
      status: status,
      message: error_message(body, status),
      raw: body
    }
  end

  defp kind_for_status(400), do: :validation_failed
  defp kind_for_status(401), do: :unauthenticated
  defp kind_for_status(403), do: :forbidden
  defp kind_for_status(404), do: :not_found
  defp kind_for_status(422), do: :validation_failed
  defp kind_for_status(status) when status >= 500 and status < 600, do: :server_error
  defp kind_for_status(_), do: :http

  defp error_message(%{"errors" => [%{"message" => msg} | _]}, _) when is_binary(msg), do: msg
  defp error_message(%{"message" => msg}, _) when is_binary(msg), do: msg
  defp error_message(_, status), do: "HTTP #{status}"

  defp transport_error(%{reason: _reason} = exception) do
    %Error{
      kind: :network,
      status: nil,
      message:
        if(match?(%{__exception__: true}, exception),
          do: Exception.message(exception),
          else: inspect(exception)
        ),
      raw: exception
    }
  end

  defp transport_error(other) do
    %Error{kind: :network, status: nil, message: inspect(other), raw: other}
  end

  defp stub_opts do
    if Application.get_env(:arbiter, :linear_http_stub, false) do
      [plug: {Req.Test, @stub_name}]
    else
      []
    end
  end
end
