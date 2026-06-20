defmodule Arbiter.Trackers.Jira do
  @moduledoc """
  Jira adapter implementing `Arbiter.Trackers.Tracker`.

  Wraps Jira Cloud's REST API v3 for issue fetch/update/transition flows.

  ## Active-workspace contract

  The `Tracker` behaviour callbacks take a `ref` (e.g. `"VR-17585"`) with no
  workspace context. But Jira needs a host, project key, email + token, and
  field-id / status-name mappings — all workspace-scoped. We resolve those
  through `Arbiter.Trackers.Jira.Config`:

    1. Callers (request middleware, CLI command, scheduler job) call
       `Config.put_active(workspace)` to populate the per-process config.
    2. `Application.get_env(:arbiter, :jira_default_config)` is the
       fallback for tools that run without a workspace context.
    3. With neither, callbacks return `{:error, %Error{kind: :config_missing}}`.

  This uses a per-process active config populated by the caller. Two
  alternatives were considered and rejected:

    * **Extra `Workspace` argument**: breaks the behaviour signature and
      forces every caller to thread workspace through the stack.
    * **Resolve workspace from the task via Ash inside the adapter**: the
      adapter takes only a `ref` (string), not the task — and reaching back
      to Ash from inside a tracker callback couples the HTTP layer to the
      database. Worse for testability.

  ## Auth

  Jira Cloud uses **Basic auth** (NOT Bearer) with `email:api_token`. The
  email and the credentials reference both live in the workspace tracker
  config. `credentials_ref` is a small DSL — currently only `"env:NAME"`
  is supported (looks up `System.get_env/1`); a bare string is treated as
  a literal token.

  ## Status mapping & path-finding

  Task lifecycle atoms (`:open | :in_progress | :closed`, plus the richer
  `:pr_opened | :approved_unmerged | :merged`) map to a Jira target **status
  name** (NOT a transition name) via `tracker.config.status_map`. Jira's REST
  API moves issues by invoking transitions, so `transition/2` resolves a *path*
  to the target:

    * **Single-hop fast path** — if a live transition's `to` already equals the
      target status, invoke it directly (no graph needed).
    * **Multi-hop** — otherwise fetch the issue's current status and BFS the
      configured `transition_graph` (e.g. Backlog → To Do → In Progress),
      executing each hop and re-listing the available transitions between hops.

  A lifecycle event with no `status_map` entry yields `:status_unmapped` (a
  benign "this tracker doesn't model that" skip); a *mapped* target that can't
  be reached yields `:no_transition_path` / `:transition_not_found`, which the
  sync layer surfaces loudly. See `Arbiter.Trackers.Jira.Config` and
  `Arbiter.Trackers.Sync`.

  ## Tests

  Wired up to `Req.Test`: when
  `Application.get_env(:arbiter, :jira_http_stub, false)` is true, every
  request injects `plug: {Req.Test, #{inspect(Arbiter.Trackers.Jira.HTTP)}}`.
  This adapter **never** hits a real Atlassian endpoint from tests.
  """

  @behaviour Arbiter.Trackers.Tracker

  alias Arbiter.Trackers.Jira.{ADF, Config, Error}

  @stub_name Arbiter.Trackers.Jira.HTTP

  # ---- Tracker behaviour ---------------------------------------------------

  @impl true
  def fetch(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve() do
      request(cfg, :get, "/issue/#{ref}", [])
      |> handle_json()
    end
  end

  @impl true
  def transition(ref, status) when is_binary(ref) and is_atom(status) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, target_status} <- map_status(cfg, status),
         {:ok, transitions} <- list_raw_transitions(cfg, ref) do
      case direct_transition_id(transitions, target_status) do
        {:ok, id} ->
          # Single-hop fast path: a live transition lands directly on the
          # target status (its `to` already equals the target).
          post_transition(cfg, ref, id)

        :none ->
          # No direct edge — fetch the current status and walk the workflow
          # graph (multi-hop, e.g. Backlog -> … -> In Progress).
          resolve_multi_hop(cfg, ref, target_status)
      end
    end
  end

  @impl true
  def update_fields(ref, fields_map) when is_binary(ref) and is_map(fields_map) do
    with {:ok, cfg} <- Config.resolve() do
      translated = translate_fields(cfg, fields_map)
      payload = %{"fields" => translated}

      case request(cfg, :put, "/issue/#{ref}", json: payload) do
        {:ok, %Req.Response{status: status_code}} when status_code in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status_code, body: body}} ->
          {:error, http_error(status_code, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  @impl true
  def link_for(ref) when is_binary(ref) do
    case Config.resolve() do
      {:ok, %{host: host}} -> "https://#{host}/browse/#{ref}"
      {:error, _} -> "https://example.atlassian.net/browse/#{ref}"
    end
  end

  @impl true
  def add_remote_link(ref, url, title)
      when is_binary(ref) and is_binary(url) and is_binary(title) do
    with {:ok, cfg} <- Config.resolve() do
      # `globalId` makes the link idempotent: re-posting the same PR URL
      # updates the existing remote link rather than creating a duplicate.
      payload = %{
        "globalId" => "arbiter-pr=#{url}",
        "object" => %{"url" => url, "title" => title}
      }

      case request(cfg, :post, "/issue/#{ref}/remotelink", json: payload) do
        {:ok, %Req.Response{status: status_code}} when status_code in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status_code, body: body}} ->
          {:error, http_error(status_code, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  @impl true
  def add_comment(ref, body) when is_binary(ref) and is_binary(body) do
    with {:ok, cfg} <- Config.resolve() do
      # v3 comment endpoint takes the body as an ADF document.
      payload = %{"body" => ADF.from_markdown(body)}

      case request(cfg, :post, "/issue/#{ref}/comment", json: payload) do
        {:ok, %Req.Response{status: status_code}} when status_code in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status_code, body: resp_body}} ->
          {:error, http_error(status_code, resp_body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  @impl true
  def parse_ref(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "jira:") ->
        rest = String.replace_prefix(s, "jira:", "")

        if issue_key?(rest), do: {:ok, rest}, else: :error

      String.starts_with?(s, "http://") or String.starts_with?(s, "https://") ->
        case Regex.run(~r{/browse/([A-Z][A-Z0-9_]*-\d+)}, s) do
          [_, key] -> {:ok, key}
          _ -> :error
        end

      issue_key?(s) ->
        case Config.active_project_key() do
          nil ->
            # No active workspace — can't know which project this belongs to,
            # so we refuse rather than guess.
            :error

          project_key ->
            if String.starts_with?(s, project_key <> "-"), do: {:ok, s}, else: :error
        end

      true ->
        :error
    end
  end

  def parse_ref(_), do: :error

  @impl true
  def list_open(opts) when is_list(opts) do
    with {:ok, cfg} <- Config.resolve() do
      assignee_jql =
        case Keyword.get(opts, :assignee, :viewer) do
          :viewer -> "currentUser()"
          id when is_binary(id) and id != "" -> "\"#{id}\""
          _ -> "currentUser()"
        end

      jql = "assignee = #{assignee_jql} AND resolution = Unresolved ORDER BY updated DESC"

      fetch_search_pages(cfg, jql, nil, [])
    end
  end

  # Jira requires an issue type on create; "Task" is present in every
  # default Jira project scheme. Workspaces with a different scheme pass
  # `:issue_type` through `arb create`.
  @default_issue_type "Task"

  @impl true
  def create(attrs) when is_map(attrs) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, title} <- fetch_title(attrs),
         {:ok, payload} <- build_create_payload(cfg, attrs, title) do
      case request(cfg, :post, "/issue", json: payload) do
        {:ok, %Req.Response{status: status_code, body: %{"key" => key}}}
        when status_code in 200..299 and is_binary(key) ->
          {:ok, key}

        {:ok, %Req.Response{status: status_code, body: body}} when status_code in 200..299 ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: status_code,
             message: "Jira create response missing \"key\"",
             raw: body
           }}

        {:ok, %Req.Response{status: status_code, body: body}} ->
          {:error, http_error(status_code, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  @impl true
  def list_transitions(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, jira_transitions} <- list_raw_transitions(cfg, ref) do
      # status_map maps task lifecycle atom -> target STATUS name. Reverse it
      # and key each available transition by the status it lands on (`to`),
      # falling back to the transition name for payloads without a `to`.
      reverse = Enum.into(cfg.status_map, %{}, fn {k, v} -> {v, k} end)

      atoms =
        jira_transitions
        |> Enum.map(fn t -> Map.get(reverse, transition_target(t) || t["name"]) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, atoms}
    end
  end

  # ---- Tracker behaviour: claim callbacks ------------------------------------

  @impl true
  def current_user do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, %{"accountId" => id}} when is_binary(id) <-
           request(cfg, :get, "/myself", []) |> handle_json() do
      {:ok, id}
    else
      {:ok, _other} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: nil,
           message: "GET /myself returned no accountId",
           raw: nil
         }}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def assignees(%{"fields" => %{"assignee" => %{"accountId" => id}}}) when is_binary(id),
    do: [id]

  def assignees(_), do: []

  @impl true
  def issue_status(%{"fields" => %{"status" => %{"statusCategory" => %{"key" => key}}}}) do
    case key do
      "done" -> :closed
      "indeterminate" -> :in_progress
      _ -> :open
    end
  end

  def issue_status(_), do: :open

  @impl true
  def extract_title(%{"fields" => %{"summary" => title}}) when is_binary(title) and title != "",
    do: title

  def extract_title(%{"key" => key}) when is_binary(key), do: key
  def extract_title(_), do: "(no title)"

  @impl true
  def extract_description(%{"fields" => %{"description" => description}}),
    do: description_to_text(description)

  def extract_description(_), do: ""

  # Jira v3 returns `description` as an ADF document (a map); legacy/v2
  # payloads or plain-text fields come through as a string. We flatten ADF
  # to plain text (block boundaries become blank lines) — good enough for
  # mirroring the body into a task; we don't attempt a full round-trip.
  defp description_to_text(nil), do: ""
  defp description_to_text(text) when is_binary(text), do: text

  defp description_to_text(%{"type" => "doc", "content" => content}) when is_list(content) do
    content
    |> Enum.map(&adf_block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp description_to_text(_), do: ""

  defp adf_block_text(%{"content" => content}) when is_list(content),
    do: content |> Enum.map(&adf_inline_text/1) |> Enum.join("")

  defp adf_block_text(%{"text" => text}) when is_binary(text), do: text
  defp adf_block_text(_), do: ""

  defp adf_inline_text(%{"text" => text}) when is_binary(text), do: text

  defp adf_inline_text(%{"content" => content}) when is_list(content),
    do: content |> Enum.map(&adf_inline_text/1) |> Enum.join("")

  defp adf_inline_text(_), do: ""

  # ---- Public helpers ------------------------------------------------------

  @doc """
  Convenience: set the active workspace for the current process and run
  `fun`, clearing the config when `fun` returns. Useful in tests and
  one-shot scripts.
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

  # ---- Internals: list_open -----------------------------------------------

  # Atlassian removed the old `GET /search` (CHANGE-2046). The replacement
  # `POST /search/jql` takes a JSON body and paginates with an opaque
  # `nextPageToken` (the old `startAt`/`total`/`maxResults`-offset paging is
  # gone). We follow the token until the response omits it, accumulating one
  # page of summaries at a time. `fields` is explicit because the new
  # endpoint returns only `id`/`key` by default — we ask for exactly what
  # `summarize_issue/2` reads.
  @search_fields ["summary", "status", "assignee"]
  @search_page_size 100

  defp fetch_search_pages(cfg, jql, next_token, acc) do
    body =
      %{
        "jql" => jql,
        "maxResults" => @search_page_size,
        "fields" => @search_fields
      }
      |> maybe_put_token(next_token)

    case request(cfg, :post, "/search/jql", json: body) do
      {:ok, %Req.Response{status: status_code, body: %{"issues" => issues} = resp}}
      when status_code in 200..299 and is_list(issues) ->
        acc = [Enum.map(issues, &summarize_issue(&1, cfg)) | acc]

        case resp["nextPageToken"] do
          token when is_binary(token) and token != "" ->
            fetch_search_pages(cfg, jql, token, acc)

          _ ->
            {:ok, acc |> Enum.reverse() |> Enum.concat()}
        end

      {:ok, %Req.Response{status: status_code, body: _body}} when status_code in 200..299 ->
        {:ok, acc |> Enum.reverse() |> Enum.concat()}

      {:ok, %Req.Response{status: status_code, body: body}} ->
        {:error, http_error(status_code, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  defp maybe_put_token(body, token) when is_binary(token) and token != "",
    do: Map.put(body, "nextPageToken", token)

  defp maybe_put_token(body, _), do: body

  defp summarize_issue(%{"key" => key} = issue, cfg) do
    fields = Map.get(issue, "fields") || %{}

    %{
      ref: key,
      title: Map.get(fields, "summary") || "(no title)",
      url: "https://#{cfg.host}/browse/#{key}",
      status: issue_status(issue),
      assignees: assignees(issue),
      raw: issue
    }
  end

  # ---- Internals: transitions ---------------------------------------------

  defp list_raw_transitions(cfg, ref) do
    case request(cfg, :get, "/issue/#{ref}/transitions", []) do
      {:ok, %Req.Response{status: status_code, body: %{"transitions" => list}}}
      when status_code in 200..299 and is_list(list) ->
        {:ok, list}

      {:ok, %Req.Response{status: status_code, body: body}} when status_code in 200..299 ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: status_code,
           message: "transitions response missing \"transitions\" key",
           raw: body
         }}

      {:ok, %Req.Response{status: status_code, body: body}} ->
        {:error, http_error(status_code, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # status_map maps a task lifecycle atom -> target STATUS name. A missing or
  # blank entry is NOT an error here: it means "this tracker doesn't model that
  # lifecycle event". Callers (e.g. `Arbiter.Trackers.Sync`) treat
  # `:status_unmapped` as a benign skip, while a *mapped* status that can't be
  # reached surfaces loudly.
  defp map_status(%{status_map: map}, status) do
    case Map.fetch(map, status) do
      {:ok, name} when is_binary(name) and name != "" ->
        {:ok, name}

      _ ->
        {:error,
         %Error{
           kind: :status_unmapped,
           status: nil,
           message: "no Jira target status mapped for task lifecycle event #{inspect(status)}",
           raw: nil
         }}
    end
  end

  # A live transition that lands directly on the target status (its `to`
  # already equals the target). The common single-hop case — needs no graph.
  defp direct_transition_id(transitions, target_status) do
    case Enum.find(transitions, fn t -> transition_target(t) == target_status end) do
      %{"id" => id} when is_binary(id) -> {:ok, id}
      _ -> :none
    end
  end

  defp transition_target(%{"to" => %{"name" => name}}) when is_binary(name), do: name
  defp transition_target(_), do: nil

  # No direct edge to the target — fetch the issue's current status and BFS the
  # configured transition graph for a path, executing each hop in turn.
  defp resolve_multi_hop(cfg, ref, target_status) do
    with {:ok, current_status} <- current_status_name(cfg, ref) do
      cond do
        current_status == target_status ->
          # Already there — nothing to do.
          :ok

        true ->
          case plan_transition_path(cfg.transition_graph, current_status, target_status) do
            {:ok, names} -> execute_path(cfg, ref, names)
            {:error, _} = err -> err
          end
      end
    end
  end

  @doc """
  BFS over a transition graph for the shortest sequence of transition names
  that moves an issue from `from` status to `to` status.

  `graph` is `%{from_status => [%{"transition" => name, "to" => to_status}]}`.
  Returns `{:ok, [transition_name, ...]}` (empty list when already there) or
  `{:error, %Error{kind: :no_transition_path}}` when no path exists. Pure — the
  graph is the only input, so multi-hop planning is testable without HTTP.
  """
  @spec plan_transition_path(map(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def plan_transition_path(_graph, from, to) when from == to, do: {:ok, []}

  def plan_transition_path(graph, from, to) when is_map(graph) do
    bfs(graph, to, [{from, []}], MapSet.new([from]))
  end

  defp bfs(_graph, to, [], _visited) do
    {:error,
     %Error{
       kind: :no_transition_path,
       status: nil,
       message: "no transition path to #{inspect(to)} in the configured workflow graph",
       raw: nil
     }}
  end

  defp bfs(graph, to, [{node, path} | rest], visited) do
    edges = Map.get(graph, node, [])

    case Enum.find(edges, fn e -> e["to"] == to end) do
      %{"transition" => name} ->
        {:ok, Enum.reverse([name | path])}

      nil ->
        {queue, visited} =
          Enum.reduce(edges, {rest, visited}, fn %{"transition" => t, "to" => next}, {q, v} ->
            if MapSet.member?(v, next) do
              {q, v}
            else
              {q ++ [{next, [t | path]}], MapSet.put(v, next)}
            end
          end)

        bfs(graph, to, queue, visited)
    end
  end

  # Execute a planned path one hop at a time. Each hop re-lists the live
  # transitions (the available set changes after every move), matches the
  # planned transition by NAME, and POSTs it. A failed hop halts loudly.
  defp execute_path(_cfg, _ref, []), do: :ok

  defp execute_path(cfg, ref, names) do
    Enum.reduce_while(names, :ok, fn name, _acc ->
      with {:ok, transitions} <- list_raw_transitions(cfg, ref),
           {:ok, id} <- find_transition_id(transitions, name),
           :ok <- post_transition(cfg, ref, id) do
        {:cont, :ok}
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp find_transition_id(transitions, name) do
    case Enum.find(transitions, fn t -> t["name"] == name end) do
      %{"id" => id} when is_binary(id) ->
        {:ok, id}

      _ ->
        {:error,
         %Error{
           kind: :transition_not_found,
           status: nil,
           message:
             "Jira transition #{inspect(name)} not available in current state; " <>
               "available: #{inspect(Enum.map(transitions, & &1["name"]))}",
           raw: transitions
         }}
    end
  end

  defp post_transition(cfg, ref, transition_id) do
    payload = %{"transition" => %{"id" => transition_id}}

    case request(cfg, :post, "/issue/#{ref}/transitions", json: payload) do
      {:ok, %Req.Response{status: status_code}} when status_code in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status_code, body: body}} ->
        {:error, http_error(status_code, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  defp current_status_name(cfg, ref) do
    case request(cfg, :get, "/issue/#{ref}", params: [fields: "status"]) do
      {:ok, %Req.Response{status: status_code, body: body}} when status_code in 200..299 ->
        case get_in(body, ["fields", "status", "name"]) do
          name when is_binary(name) and name != "" ->
            {:ok, name}

          _ ->
            {:error,
             %Error{
               kind: :validation_failed,
               status: status_code,
               message: "issue #{ref} response missing fields.status.name",
               raw: body
             }}
        end

      {:ok, %Req.Response{status: status_code, body: body}} ->
        {:error, http_error(status_code, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # ---- Internals: field translation ---------------------------------------

  # Markdown fields (the rich-text ones we ship). Other fields pass through
  # as-is.
  @markdown_fields ~w(description qa_notes deployment_notes)a

  defp translate_fields(cfg, fields_map) do
    fields_map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      atom_key = if is_atom(key), do: key, else: String.to_atom(to_string(key))

      case Map.fetch(cfg.field_ids, atom_key) do
        {:ok, jira_id} ->
          Map.put(acc, jira_id, encode_value(atom_key, value))

        :error ->
          # Allow callers to pass raw Jira field IDs (e.g. "customfield_10999")
          # through unchanged for one-off needs.
          if is_binary(key) and String.starts_with?(key, "customfield_") do
            Map.put(acc, key, value)
          else
            acc
          end
      end
    end)
  end

  defp encode_value(atom_key, value) when atom_key in @markdown_fields and is_binary(value) do
    ADF.from_markdown(value)
  end

  defp encode_value(_atom_key, value), do: value

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

  # Build the `POST /issue` body. `project` and `issuetype` are create-only
  # required fields (not part of `field_ids`); `summary` / `description` and
  # any other configured rich-text fields go through `translate_fields/2` so
  # they pick up the workspace's field-id mapping and ADF encoding — exactly
  # like `update_fields/2`.
  defp build_create_payload(cfg, attrs, title) do
    issue_type = pluck(attrs, [:issue_type, "issue_type"]) || @default_issue_type
    description = pluck(attrs, [:description, "description"])

    domain_fields =
      %{title: title}
      |> maybe_put(:description, description)

    fields =
      %{
        "project" => %{"key" => cfg.project_key},
        "issuetype" => %{"name" => issue_type}
      }
      |> Map.merge(translate_fields(cfg, domain_fields))

    {:ok, %{"fields" => fields}}
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

  # ---- Internals: HTTP ----------------------------------------------------

  defp request(cfg, method, path, req_opts) do
    url = "https://#{cfg.host}/rest/api/3" <> path

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

  defp handle_json({:ok, %Req.Response{status: status_code, body: body}})
       when status_code in 200..299,
       do: {:ok, body}

  defp handle_json({:ok, %Req.Response{status: status_code, body: body}}),
    do: {:error, http_error(status_code, body)}

  defp handle_json({:error, exception}), do: {:error, transport_error(exception)}

  defp headers(%{email: email, token: token}) do
    auth =
      case email do
        e when is_binary(e) and e != "" -> Base.encode64(e <> ":" <> token)
        # Some workspaces (rare) use a bare API token without an email
        # prefix; let Jira reject it cleanly rather than 401 here.
        _ -> Base.encode64(":" <> token)
      end

    [
      {"authorization", "Basic " <> auth},
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"user-agent", "arbiter"}
    ]
  end

  defp http_error(status_code, body) do
    %Error{
      kind: kind_for_status(status_code),
      status: status_code,
      message: error_message(body, status_code),
      raw: body
    }
  end

  defp kind_for_status(400), do: :validation_failed
  defp kind_for_status(401), do: :unauthenticated
  defp kind_for_status(403), do: :forbidden
  defp kind_for_status(404), do: :not_found
  defp kind_for_status(422), do: :validation_failed
  defp kind_for_status(s) when s >= 500 and s < 600, do: :server_error
  defp kind_for_status(_), do: :http

  defp error_message(%{"errorMessages" => [msg | _]}, _) when is_binary(msg), do: msg
  defp error_message(%{"message" => msg}, _) when is_binary(msg), do: msg
  defp error_message(_, status_code), do: "HTTP #{status_code}"

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
    if Application.get_env(:arbiter, :jira_http_stub, false) do
      [plug: {Req.Test, @stub_name}]
    else
      []
    end
  end

  # ---- Misc ---------------------------------------------------------------

  defp issue_key?(s), do: Regex.match?(~r/^[A-Z][A-Z0-9_]*-\d+$/, s)
end
