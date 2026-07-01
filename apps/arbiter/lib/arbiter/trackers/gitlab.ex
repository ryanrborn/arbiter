defmodule Arbiter.Trackers.Gitlab do
  @moduledoc """
  GitLab Issues adapter implementing `Arbiter.Trackers.Tracker`.

  Wraps GitLab's REST API v4 (`https://<host>/api/v4`) for issue
  fetch/create/update/transition flows, so directives can sync to GitLab
  Issues. `create/1` POSTs `/projects/:id/issues` and returns the new issue's
  `iid` as the canonical ref; used by `arb create` to mirror a new task into
  the workspace's GitLab project.

  This is the tracker (issues) half of GitLab support — the merger (MR) half
  lives in `Arbiter.Mergers.Gitlab`. Together they make GitLab a first-class
  provider usable as both `merge.strategy` and `tracker.type`. The design
  deliberately mirrors `Arbiter.Trackers.GitHub`, differing only where the
  GitLab API differs (auth header, issue `iid`, `state_event` transitions,
  numeric assignee IDs).

  ## Active-workspace contract

  The `Tracker` behaviour callbacks take a `ref` (the issue `iid` as a string,
  e.g. `"42"`) with no workspace context. But GitLab needs a host, project,
  token, and a task-status → state/label mapping — all workspace-scoped. We
  resolve those through `Arbiter.Trackers.Gitlab.Config`, exactly as the GitHub
  and Jira adapters do for their backends:

    1. Callers (request middleware, CLI command, scheduler job) call
       `Config.put_active(workspace)` to populate the per-process config.
    2. `Application.get_env(:arbiter, :gitlab_tracker_default_config)` is the
       fallback for tools that run without a workspace context.
    3. With neither, callbacks return `{:error, %Error{kind: :config_missing}}`.

  ## `ref`

  The canonical ref is the bare issue `iid` as a string (`"42"`). Host / project
  come from the resolved workspace config. `parse_ref/1` accepts the bare
  number, the `"gitlab:"`/`"gl-"`/`"#"` prefixes, and full issue URLs
  (`.../-/issues/42`).

  ## Auth

  GitLab uses a `PRIVATE-TOKEN` header. The credentials reference lives in the
  tracker config; `credentials_ref` is the shared small DSL — `"env:NAME"`
  looks up `System.get_env/1`, `"secret:KEY"` reads a workspace secret, and a
  bare string is treated as a literal token.

  ## Identity

  GitLab identifies users by numeric ID for assignment, but by `username` for
  display and filtering. This adapter uses **username** as the canonical
  identity string returned by `current_user/0` and extracted by `assignees/1`
  (mirroring GitHub's login model), and resolves username → numeric ID on
  demand when it must assign an issue (`signal_claim/3`, `create/1`).

  ## Status mapping

  GitLab Issues have only two native states — `opened` and `closed` — so the
  task-vocabulary `:in_progress` is expressed as an *opened* issue carrying a
  label (default `"in progress"`). `transition/2`:

    1. Resolves the target status to a `%{state, label}` pair via the
       workspace's `status_map` (see `Arbiter.Trackers.Gitlab.Config`).
    2. Fetches the issue to read its current state + labels.
    3. Swaps the *managed* status labels — adds the target's label and removes
       the other statuses' labels — leaving any unrelated labels untouched.
    4. `PUT`s the issue with the appropriate `state_event` (`close`/`reopen`)
       and the new `labels`.

  ## Tests

  Wired up to `Req.Test`: when
  `Application.get_env(:arbiter, :gitlab_http_stub, false)` is true, every
  request injects `plug: {Req.Test, #{inspect(Arbiter.Trackers.Gitlab.HTTP)}}`.
  This adapter **never** hits a real GitLab endpoint from tests.
  """

  @behaviour Arbiter.Trackers.Tracker

  alias Arbiter.Trackers.Gitlab.{Config, Error}

  @stub_name Arbiter.Trackers.Gitlab.HTTP

  @ownership_marker "Arbiter installation:"

  # ---- Tracker behaviour ---------------------------------------------------

  @impl true
  def fetch(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve() do
      request(cfg, :get, issue_path(ref), [])
      |> handle_json()
    end
  end

  @impl true
  def transition(ref, status) when is_binary(ref) and is_atom(status) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, %{state: state, label: label}} <- map_status(cfg, status),
         {:ok, issue} <- request(cfg, :get, issue_path(ref), []) |> handle_json() do
      if already_in_state?(issue, state, label) do
        :ok
      else
        payload =
          %{"labels" => Enum.join(next_labels(cfg, issue, label), ",")}
          |> maybe_put_state_event(issue, state)

        request(cfg, :put, issue_path(ref), json: payload)
        |> expect_ok()
      end
    end
  end

  @impl true
  def update_fields(ref, fields_map) when is_binary(ref) and is_map(fields_map) do
    with {:ok, cfg} <- Config.resolve() do
      payload = translate_fields(fields_map)

      if payload == %{} do
        :ok
      else
        request(cfg, :put, issue_path(ref), json: payload)
        |> expect_ok()
      end
    end
  end

  @impl true
  def link_for(ref) when is_binary(ref) do
    host = Config.active_host() || "gitlab.com"
    project = Config.active_project_id() || "group/project"
    "https://#{host}/#{project}/-/issues/#{ref}"
  end

  @impl true
  def add_comment(ref, body) when is_binary(ref) and is_binary(body) do
    post_comment(ref, body)
  end

  @impl true
  def add_remote_link(ref, url, title)
      when is_binary(ref) and is_binary(url) and is_binary(title) do
    with {:ok, _cfg} <- Config.resolve() do
      case list_notes(ref) do
        {:ok, notes} ->
          case Enum.find(notes, &String.contains?(&1["body"] || "", url)) do
            nil -> post_remote_link_comment(ref, url, title)
            _existing -> :ok
          end

        {:error, _} ->
          post_remote_link_comment(ref, url, title)
      end
    end
  end

  @impl true
  def parse_ref(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "gitlab:") ->
        s |> String.replace_prefix("gitlab:", "") |> integer_ref()

      String.starts_with?(s, "gl-") ->
        s |> String.replace_prefix("gl-", "") |> integer_ref()

      String.starts_with?(s, "#") ->
        s |> String.replace_prefix("#", "") |> integer_ref()

      String.starts_with?(s, "http://") or String.starts_with?(s, "https://") ->
        case Regex.run(~r{/issues/(\d+)}, s) do
          [_, id] -> {:ok, id}
          _ -> :error
        end

      true ->
        integer_ref(s)
    end
  end

  def parse_ref(_), do: :error

  @impl true
  def list_open(opts) when is_list(opts) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, username} <- resolve_assignee(opts) do
      case fetch_assigned_open_issues(cfg, username) do
        {:ok, issues} -> {:ok, Enum.map(issues, &summarize/1)}
        {:error, _} = err -> err
      end
    end
  end

  @impl true
  def list_transitions(ref) when is_binary(ref) do
    # GitLab imposes no transition state machine — an issue can move to any of
    # the mapped statuses at any time — so we validate the ref exists, then
    # return every task status the workspace knows how to map.
    with {:ok, cfg} <- Config.resolve(),
         {:ok, _issue} <- request(cfg, :get, issue_path(ref), []) |> handle_json() do
      statuses =
        [:open, :in_progress, :closed]
        |> Enum.filter(&Map.has_key?(cfg.status_map, &1))

      {:ok, statuses}
    end
  end

  @impl true
  def create(attrs) when is_map(attrs) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, title} <- fetch_title(attrs) do
      payload = build_create_payload(cfg, attrs, title)

      case request(cfg, :post, "/issues", json: payload) do
        {:ok, %Req.Response{status: status, body: %{"iid" => iid}}}
        when status in 200..299 and is_integer(iid) ->
          {:ok, Integer.to_string(iid)}

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: status,
             message: "GitLab create response missing \"iid\"",
             raw: body
           }}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, http_error(status, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  # ---- Tracker behaviour: claim callbacks ------------------------------------

  @impl true
  def current_user, do: viewer_username()

  @impl true
  def assignees(issue_map), do: assignee_usernames(issue_map)

  @impl true
  def issue_status(%{"state" => "closed"}), do: :closed
  def issue_status(_), do: :open

  @impl true
  def extract_title(%{"title" => title}) when is_binary(title) and title != "", do: title
  def extract_title(_), do: "(no title)"

  @impl true
  def extract_description(%{"description" => body}) when is_binary(body), do: body
  def extract_description(_), do: ""

  # Parse "priority: N" label written by create/1 for round-trip stability.
  @impl true
  def extract_priority(issue_map) do
    issue_map
    |> label_names()
    |> Enum.find_value(fn
      "priority: " <> rest -> parse_bucket(rest)
      _ -> nil
    end)
  end

  # Parse "difficulty: N" label — no outbound create uses this label today,
  # but the inbound path honours it if someone adds it manually.
  @impl true
  def extract_difficulty(issue_map) do
    issue_map
    |> label_names()
    |> Enum.find_value(fn
      "difficulty: " <> rest -> parse_bucket(rest)
      _ -> nil
    end)
  end

  defp parse_bucket(rest) do
    case Integer.parse(rest) do
      {n, ""} when n >= 0 and n <= 4 -> {:ok, n}
      _ -> nil
    end
  end

  @impl true
  def check_prior_claim(ref) do
    case list_notes(ref) do
      {:ok, notes} ->
        case Enum.find(notes, &String.contains?(&1["body"] || "", @ownership_marker)) do
          nil -> :ok
          %{"body" => body} -> {:error, {:already_claimed, body}}
        end

      {:error, _} ->
        :ok
    end
  end

  @impl true
  def signal_claim(ref, task_id, %{
        workspace_name: name,
        workspace_prefix: prefix,
        current_user: username,
        host: host
      }) do
    body =
      "Claimed as #{task_id} by #{name} (#{prefix}). #{@ownership_marker} #{host}."

    post_comment(ref, body)
    assign_user(ref, username)
    :ok
  end

  @impl true
  def search_by_title(title) when is_binary(title) do
    with {:ok, cfg} <- Config.resolve() do
      params = [search: title, in: "title", state: "opened", per_page: 25]

      case request(cfg, :get, "/issues", params: params) do
        {:ok, %Req.Response{status: status, body: items}}
        when status in 200..299 and is_list(items) ->
          norm = normalize_title(title)

          matches =
            items
            |> Enum.filter(fn item -> normalize_title(Map.get(item, "title", "")) == norm end)
            |> Enum.map(&summarize/1)

          {:ok, matches}

        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          {:ok, []}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, http_error(status, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  # ---- Public helpers ------------------------------------------------------

  @doc """
  Convenience: set the active workspace for the current process and run `fun`,
  restoring the previous config when `fun` returns. Useful in tests and
  one-shot scripts. Mirrors `Arbiter.Trackers.GitHub.with_workspace/2`.
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
  Returns the authenticated user's username (the "viewer") associated with the
  active workspace's token. Used by `arb claim` and `arb sync` to enforce
  assignment-as-claim: a task is only created for an issue assigned to *this*
  workspace's GitLab user.
  """
  @spec viewer_username() :: {:ok, String.t()} | {:error, Error.t()}
  def viewer_username do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, %{"username" => username}} when is_binary(username) <-
           root_request(cfg, :get, "/user", []) |> handle_json() do
      {:ok, username}
    else
      {:ok, _other} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: nil,
           message: "GET /user returned no username",
           raw: nil
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Post a note (comment) on a GitLab issue.
  """
  @spec post_comment(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def post_comment(ref, body) when is_binary(ref) and is_binary(body) do
    with {:ok, cfg} <- Config.resolve() do
      request(cfg, :post, issue_path(ref) <> "/notes", json: %{"body" => body})
      |> expect_ok()
    end
  end

  @doc """
  List notes (comments) on a GitLab issue (first page, up to 100).
  """
  @spec list_notes(String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_notes(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve() do
      request(cfg, :get, issue_path(ref) <> "/notes", params: [per_page: 100])
      |> handle_json()
    end
  end

  @doc """
  Assign a user (by username) to a GitLab issue. Non-fatal: callers should
  treat errors as soft failures (assignment requires project membership).

  GitLab assignment is by numeric user ID, so the username is resolved to an ID
  first via `GET /users?username=`.
  """
  @spec assign_user(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def assign_user(ref, username) when is_binary(ref) and is_binary(username) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, user_id} <- resolve_user_id(cfg, username) do
      request(cfg, :put, issue_path(ref), json: %{"assignee_ids" => [user_id]})
      |> expect_ok()
    end
  end

  @doc """
  Extracts assignee usernames from a fetched issue map. Tolerant of GitLab's
  two shapes: `"assignees"` (a list of user maps) and the legacy `"assignee"`
  (a single user map).
  """
  @spec assignee_usernames(map()) :: [String.t()]
  def assignee_usernames(%{"assignees" => list}) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"username" => username} when is_binary(username) -> [username]
      _ -> []
    end)
    |> Enum.uniq()
  end

  def assignee_usernames(%{"assignee" => %{"username" => username}}) when is_binary(username),
    do: [username]

  def assignee_usernames(_), do: []

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

  # Map task-domain attrs onto GitLab's POST /projects/:id/issues body. `title`
  # is required; `description`, `assignee_ids`, and `labels` are optional — we
  # skip them when the caller didn't supply them. Labels are a merged set of:
  # the initial-status label from the workspace status_map, a `"priority: N"`
  # label when `:priority` is set, and a `"type: T"` label when `:issue_type`
  # is set (comma-joined, as GitLab expects).
  defp build_create_payload(cfg, attrs, title) do
    description = pluck(attrs, [:description, "description"])
    assignee = pluck(attrs, [:assignee, "assignee"])
    status = pluck(attrs, [:status, "status"]) || :open
    priority = pluck(attrs, [:priority, "priority"])
    issue_type = pluck(attrs, [:issue_type, "issue_type"])

    %{"title" => title}
    |> maybe_put("description", description)
    |> maybe_put_labels(cfg, status, priority, issue_type)
    |> maybe_put_assignee(cfg, assignee)
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

  # Merge labels from three sources into a single comma-joined string, GitLab's
  # expected `labels` param format. Only sets "labels" if there is at least one.
  defp maybe_put_labels(payload, cfg, status, priority, issue_type) do
    status_label =
      case Map.get(cfg.status_map, status) do
        %{label: label} when is_binary(label) and label != "" -> [label]
        _ -> []
      end

    priority_label =
      case priority do
        p when is_integer(p) -> ["priority: #{p}"]
        _ -> []
      end

    type_label =
      case issue_type do
        t when is_binary(t) and t != "" -> ["type: #{t}"]
        _ -> []
      end

    case status_label ++ priority_label ++ type_label do
      [] -> payload
      labels -> Map.put(payload, "labels", Enum.join(labels, ","))
    end
  end

  # Best-effort: resolve the assignee username to a numeric id and set
  # assignee_ids. A resolution failure (unknown user, wire error) simply omits
  # the assignee rather than failing the whole create.
  defp maybe_put_assignee(payload, _cfg, nil), do: payload
  defp maybe_put_assignee(payload, _cfg, ""), do: payload

  defp maybe_put_assignee(payload, cfg, username) when is_binary(username) do
    case resolve_user_id(cfg, username) do
      {:ok, id} -> Map.put(payload, "assignee_ids", [id])
      {:error, _} -> payload
    end
  end

  defp maybe_put_assignee(payload, _cfg, _), do: payload

  # ---- Internals: user resolution -----------------------------------------

  # Resolve a username (or a numeric id, passed through) to a GitLab user id.
  defp resolve_user_id(_cfg, id) when is_integer(id), do: {:ok, id}

  defp resolve_user_id(cfg, username) when is_binary(username) do
    case Integer.parse(username) do
      {id, ""} ->
        {:ok, id}

      _ ->
        case root_request(cfg, :get, "/users", params: [username: username]) |> handle_json() do
          {:ok, [%{"id" => id} | _]} when is_integer(id) ->
            {:ok, id}

          {:ok, _} ->
            {:error,
             %Error{
               kind: :not_found,
               status: nil,
               message: "GitLab user #{inspect(username)} not found",
               raw: nil
             }}

          {:error, _} = err ->
            err
        end
    end
  end

  # ---- Internals: list_open / pagination ---------------------------------

  # Resolve the assignee opt to a concrete GitLab username. Default (`:viewer`)
  # asks GitLab for the token's authenticated user.
  defp resolve_assignee(opts) do
    case Keyword.get(opts, :assignee, :viewer) do
      :viewer ->
        viewer_username()

      username when is_binary(username) and username != "" ->
        {:ok, username}

      other ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: nil,
           message: "list_open: invalid :assignee option #{inspect(other)}",
           raw: nil
         }}
    end
  end

  # Paginated fetch of open issues assigned to the given username. GitLab
  # supports `assignee_username`; we walk the `x-next-page` header until
  # exhausted so workspaces with >100 assigned issues come back complete.
  defp fetch_assigned_open_issues(cfg, username) do
    params = [assignee_username: username, state: "opened", per_page: 100]
    paginate(cfg, "/issues", params: params)
  end

  # Cap pages so a runaway response can't hammer the API. 50 pages × 100/page
  # = 5,000 issues, well above any human's claimable backlog.
  @max_pages 50

  defp paginate(cfg, path, req_opts) do
    do_paginate(cfg, path, req_opts, [], @max_pages)
  end

  defp do_paginate(_cfg, _path, _req_opts, acc, 0),
    do: {:ok, acc |> Enum.reverse() |> List.flatten()}

  defp do_paginate(cfg, path, req_opts, acc, pages_left) do
    case request(cfg, :get, path, req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        page = if is_list(body), do: body, else: []

        case next_page(headers, req_opts) do
          nil ->
            {:ok, Enum.reverse([page | acc]) |> List.flatten()}

          next_req_opts ->
            do_paginate(cfg, path, next_req_opts, [page | acc], pages_left - 1)
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # GitLab paginates with an `x-next-page` header carrying the next page number
  # (empty when there is no next page). We thread it back into the same params.
  defp next_page(headers, req_opts) do
    case header_value(headers, "x-next-page") do
      v when is_binary(v) and v != "" ->
        params = Keyword.get(req_opts, :params, [])
        [params: Keyword.put(params, :page, v)]

      _ ->
        nil
    end
  end

  defp header_value(headers, key) when is_map(headers) do
    case Map.get(headers, key) do
      [v | _] when is_binary(v) -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp header_value(headers, key) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} -> if String.downcase(to_string(k)) == key, do: v
      _ -> nil
    end)
  end

  defp header_value(_, _), do: nil

  # Normalizes a raw issue payload into a Tracker.summary.
  defp summarize(%{"iid" => iid} = issue) do
    %{
      ref: to_string(iid),
      title: title_or_default(issue),
      url: Map.get(issue, "web_url"),
      status: status_for(issue),
      assignees: assignee_usernames(issue),
      raw: issue
    }
  end

  defp title_or_default(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp title_or_default(_), do: "(no title)"

  # An "in progress" issue is an opened issue carrying one of the in_progress
  # labels in the workspace's status_map. Anything else opened is :open;
  # anything closed is :closed.
  defp status_for(%{"state" => "closed"}), do: :closed

  defp status_for(issue) do
    cfg = active_status_map()

    in_progress_label =
      case Map.get(cfg, :in_progress) do
        %{label: label} when is_binary(label) -> label
        _ -> nil
      end

    if in_progress_label && in_progress_label in label_names(issue) do
      :in_progress
    else
      :open
    end
  end

  defp active_status_map do
    case Config.resolve() do
      {:ok, %{status_map: map}} -> map
      _ -> %{}
    end
  end

  # ---- Internals: status / labels -----------------------------------------

  defp map_status(%{status_map: map}, status) do
    case Map.fetch(map, status) do
      {:ok, %{state: state} = entry} when state in ["opened", "closed"] ->
        {:ok, entry}

      _ ->
        {:error,
         %Error{
           kind: :transition_not_found,
           status: nil,
           message: "no GitLab state mapped for task status #{inspect(status)}",
           raw: nil
         }}
    end
  end

  # Returns true when the issue is already in the desired target state and has
  # the correct label (or no label is needed). Skipping the PUT in this case
  # prevents redundant API calls when concurrent close actions race.
  defp already_in_state?(issue, target_state, target_label) do
    Map.get(issue, "state") == target_state and
      (target_label == nil or target_label in label_names(issue))
  end

  # GitLab moves state via the `state_event` param, not by setting `state`.
  # Only include it when the issue must actually change state.
  defp maybe_put_state_event(payload, issue, target_state) do
    case {Map.get(issue, "state"), target_state} do
      {same, same} -> payload
      {_, "closed"} -> Map.put(payload, "state_event", "close")
      {_, "opened"} -> Map.put(payload, "state_event", "reopen")
      _ -> payload
    end
  end

  # Labels the adapter owns: every label named in the status_map. On a
  # transition we strip all of these, then add back the target's label — so an
  # issue never carries two status labels at once, and labels the adapter didn't
  # set are preserved.
  defp next_labels(cfg, issue, target_label) do
    managed =
      cfg.status_map
      |> Map.values()
      |> Enum.map(& &1.label)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    kept =
      issue
      |> label_names()
      |> Enum.reject(&MapSet.member?(managed, &1))

    case target_label do
      nil -> Enum.uniq(kept)
      label -> Enum.uniq(kept ++ [label])
    end
  end

  # GitLab returns issue labels as a list of strings; tolerate the map shape
  # (`%{"name" => ...}`) too, in case a caller passes a richer payload.
  defp label_names(%{"labels" => labels}) when is_list(labels) do
    Enum.flat_map(labels, fn
      name when is_binary(name) -> [name]
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp label_names(_), do: []

  # ---- Internals: field translation ---------------------------------------

  # Task-domain field keys -> GitLab issue attributes.
  @field_map %{
    title: "title",
    description: "description"
  }

  defp translate_fields(fields_map) do
    Enum.reduce(fields_map, %{}, fn {key, value}, acc ->
      atom_key = if is_atom(key), do: key, else: safe_atom(key)

      case Map.fetch(@field_map, atom_key) do
        {:ok, gl_key} -> Map.put(acc, gl_key, value)
        :error -> acc
      end
    end)
  end

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__unknown__
  end

  # ---- Internals: ref parsing / helpers -----------------------------------

  defp integer_ref(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, Integer.to_string(n)}
      _ -> :error
    end
  end

  defp issue_path(ref), do: "/issues/#{ref}"

  defp normalize_title(title), do: title |> String.downcase() |> String.trim()

  defp post_remote_link_comment(ref, url, title)
       when is_binary(ref) and is_binary(url) and is_binary(title) do
    post_comment(ref, "**Remote Link:** [#{title}](#{url})")
  end

  # ---- Internals: HTTP ----------------------------------------------------

  # Project-scoped request: prepends /api/v4/projects/:project_id to `path`.
  defp request(cfg, method, path, req_opts) do
    url = "https://#{cfg.host}/api/v4/projects/#{cfg.project_id}" <> path
    do_request(cfg, method, url, req_opts)
  end

  # Root request: prepends /api/v4 to `path` (for /user, /users — not scoped
  # to a project).
  defp root_request(cfg, method, path, req_opts) do
    url = "https://#{cfg.host}/api/v4" <> path
    do_request(cfg, method, url, req_opts)
  end

  defp do_request(cfg, method, url, req_opts) do
    full_opts =
      [
        method: method,
        url: url,
        headers: headers(cfg),
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(req_opts)
      |> Keyword.merge(stub_opts())

    Req.request(full_opts)
  end

  defp handle_json({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_json({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, http_error(status, body)}

  defp handle_json({:error, exception}), do: {:error, transport_error(exception)}

  # For callbacks that only care about success vs failure (transition/update).
  defp expect_ok({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp expect_ok({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, http_error(status, body)}

  defp expect_ok({:error, exception}), do: {:error, transport_error(exception)}

  defp headers(%{token: token}) do
    [
      {"private-token", token},
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"user-agent", "arbiter"}
    ]
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

  # GitLab error bodies use "message" (string or map) or "error".
  defp error_message(%{"message" => msg}, _) when is_binary(msg), do: msg
  defp error_message(%{"message" => msg}, _) when is_map(msg) or is_list(msg), do: inspect(msg)
  defp error_message(%{"error" => msg}, _) when is_binary(msg), do: msg
  defp error_message(_, status), do: "HTTP #{status}"

  defp transport_error(%{reason: reason} = exception) do
    %Error{
      kind: :network,
      status: nil,
      message:
        case exception do
          %{__exception__: true} -> Exception.message(exception)
          _ -> inspect(reason)
        end,
      raw: exception
    }
  end

  defp transport_error(other) do
    %Error{
      kind: :network,
      status: nil,
      message: inspect(other),
      raw: other
    }
  end

  defp stub_opts do
    if Application.get_env(:arbiter, :gitlab_http_stub, false) do
      [plug: {Req.Test, @stub_name}]
    else
      []
    end
  end
end
