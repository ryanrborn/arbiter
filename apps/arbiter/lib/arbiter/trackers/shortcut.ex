defmodule Arbiter.Trackers.Shortcut do
  @moduledoc """
  Shortcut adapter implementing `Arbiter.Trackers.Tracker`.

  Wraps Shortcut's REST API v3 (`api.app.shortcut.com/api/v3`) for story
  fetch/update/transition flows. Used by the Emricare domains (Varek/tonic,
  Soren/tonic_device) to sync tasks with their Shortcut board.

  ## Active-workspace contract

  Like the Jira adapter, the `Tracker` callbacks take only a `ref` (a story id)
  with no workspace context. Shortcut needs an API token and a task-status →
  workflow-state mapping, both workspace-scoped. We resolve those through
  `Arbiter.Trackers.Shortcut.Config`:

    1. Callers (request middleware, CLI command, scheduler job) call
       `Config.put_active(workspace)` to populate the per-process config.
    2. `Application.get_env(:arbiter, :shortcut_default_config)` is the fallback
       for tools that run without a workspace context.
    3. With neither, callbacks return `{:error, %Error{kind: :config_missing}}`.

  ## Auth

  Shortcut authenticates with a `Shortcut-Token: <token>` header (NOT Basic
  auth like Jira, NOT Bearer). The token comes from the workspace's
  `credentials_ref` (`"env:NAME"` or a bare literal).

  ## Status mapping

  Task-vocabulary atoms (`:open | :in_progress | :closed`) map to Shortcut
  workflow *state names*. Shortcut moves a story between states by PUT-ing its
  `workflow_state_id`, so we resolve the mapped state name to a concrete state
  id via `GET /workflows`. Defaults are conservative ("Unstarted", "In
  Progress", "Done"); each workspace can override via `tracker.config.status_map`.

  An optional `workflow_id` narrows the state search (and `list_transitions/1`)
  to a single workflow — useful when a workspace has multiple workflows that
  share state names.

  ## Tests

  Wired up to `Req.Test`: when
  `Application.get_env(:arbiter, :shortcut_http_stub, false)` is true, every
  request injects `plug: {Req.Test, #{inspect(Arbiter.Trackers.Shortcut.HTTP)}}`.
  This adapter **never** hits a real Shortcut endpoint from tests.
  """

  @behaviour Arbiter.Trackers.Tracker

  alias Arbiter.Trackers.Shortcut.{Config, Error}

  @base_url "https://api.app.shortcut.com/api/v3"
  @stub_name Arbiter.Trackers.Shortcut.HTTP

  # ---- Tracker behaviour ---------------------------------------------------

  @impl true
  def fetch(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve() do
      request(cfg, :get, "/stories/#{ref}", [])
      |> handle_json()
    end
  end

  @impl true
  def transition(ref, status) when is_binary(ref) and is_atom(status) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, target_name} <- map_status(cfg, status),
         {:ok, workflows} <- list_workflows(cfg),
         {:ok, state_id} <- find_state_id(cfg, workflows, target_name) do
      payload = %{"workflow_state_id" => state_id}

      case request(cfg, :put, "/stories/#{ref}", json: payload) do
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
  def update_fields(ref, fields_map) when is_binary(ref) and is_map(fields_map) do
    with {:ok, cfg} <- Config.resolve() do
      payload = translate_fields(fields_map)

      case request(cfg, :put, "/stories/#{ref}", json: payload) do
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
    post_comment(ref, body)
  end

  @impl true
  def add_remote_link(ref, url, title)
      when is_binary(ref) and is_binary(url) and is_binary(title) do
    with {:ok, cfg} <- Config.resolve() do
      payload = %{
        "url" => url,
        "description" => title
      }

      case request(cfg, :post, "/stories/#{ref}/external_links", json: payload) do
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
  def link_for(ref) when is_binary(ref), do: "https://app.shortcut.com/story/#{ref}"

  @impl true
  def parse_ref(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "shortcut:") ->
        s |> String.replace_prefix("shortcut:", "") |> integer_ref()

      String.starts_with?(s, "sc-") ->
        s |> String.replace_prefix("sc-", "") |> integer_ref()

      String.starts_with?(s, "http://") or String.starts_with?(s, "https://") ->
        case Regex.run(~r{/story/(\d+)}, s) do
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
    with {:ok, cfg} <- Config.resolve() do
      case Keyword.get(opts, :assignee, :viewer) do
        :viewer ->
          with {:ok, member_id} <- current_user() do
            fetch_stories_by_owner(cfg, member_id)
          end

        id when is_binary(id) and id != "" ->
          fetch_stories_by_owner(cfg, id)

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
  end

  @impl true
  def create(attrs) when is_map(attrs) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, title} <- fetch_title(attrs),
         {:ok, workflows} <- list_workflows(cfg),
         {:ok, state_id} <- resolve_initial_state(cfg, workflows, attrs),
         {:ok, payload} <- build_create_payload(title, state_id, attrs) do
      case request(cfg, :post, "/stories", json: payload) do
        {:ok, %Req.Response{status: status_code, body: %{"id" => id}}}
        when status_code in 200..299 and is_integer(id) ->
          {:ok, Integer.to_string(id)}

        {:ok, %Req.Response{status: status_code, body: body}} when status_code in 200..299 ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: status_code,
             message: "Shortcut create response missing \"id\"",
             raw: body
           }}

        {:ok, %Req.Response{status: status_code, body: body}} ->
          {:error, http_error(status_code, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

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

  defp resolve_initial_state(cfg, workflows, attrs) do
    status = pluck(attrs, [:status, "status"]) || :open
    target_name = Map.get(cfg.status_map, status)

    case target_name do
      name when is_binary(name) and name != "" ->
        find_state_id(cfg, workflows, name)

      _ ->
        find_state_id(cfg, workflows, Map.get(cfg.status_map, :open, "Unstarted"))
    end
  end

  defp build_create_payload(title, state_id, attrs) do
    description = pluck(attrs, [:description, "description"])
    assignee = pluck(attrs, [:assignee, "assignee"])

    payload =
      %{"name" => title, "workflow_state_id" => state_id}
      |> maybe_put_description(description)
      |> maybe_put_owner_ids(assignee)

    {:ok, payload}
  end

  defp pluck(map, keys) do
    Enum.find_value(keys, fn k ->
      case Map.fetch(map, k) do
        {:ok, v} -> v
        :error -> nil
      end
    end)
  end

  defp maybe_put_description(payload, nil), do: payload
  defp maybe_put_description(payload, ""), do: payload
  defp maybe_put_description(payload, desc), do: Map.put(payload, "description", desc)

  defp maybe_put_owner_ids(payload, nil), do: payload
  defp maybe_put_owner_ids(payload, ""), do: payload

  defp maybe_put_owner_ids(payload, id) when is_binary(id),
    do: Map.put(payload, "owner_ids", [id])

  defp maybe_put_owner_ids(payload, _), do: payload

  @impl true
  def search_by_title(title) when is_binary(title) do
    with {:ok, cfg} <- Config.resolve() do
      escaped = String.replace(title, "\"", "\\\"")
      query = "title:\"#{escaped}\""

      case request(cfg, :get, "/search/stories", params: [query: query, page_size: 25]) do
        {:ok, %Req.Response{status: status_code, body: %{"data" => stories}}}
        when status_code in 200..299 and is_list(stories) ->
          norm = normalize_title(title)

          matches =
            stories
            |> Enum.filter(fn story ->
              normalize_title(Map.get(story, "name", "")) == norm
            end)
            |> Enum.map(&summarize_story/1)

          {:ok, matches}

        {:ok, %Req.Response{status: status_code}} when status_code in 200..299 ->
          {:ok, []}

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
         {:ok, workflows} <- list_workflows(cfg) do
      # Reverse-map Shortcut state names to task-status atoms via the
      # workspace's status_map (which maps atom -> state name).
      reverse = Enum.into(cfg.status_map, %{}, fn {k, v} -> {v, k} end)

      atoms =
        cfg
        |> states_for(workflows)
        |> Enum.map(fn %{"name" => name} -> Map.get(reverse, name) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, atoms}
    end
  end

  # ---- Tracker behaviour: claim callbacks ------------------------------------

  @ownership_marker "Arbiter installation:"

  @impl true
  def check_prior_claim(ref) when is_binary(ref) do
    case list_comments(ref) do
      {:ok, comments} ->
        case Enum.find(comments, &String.contains?(&1["text"] || "", @ownership_marker)) do
          nil -> :ok
          %{"text" => body} -> {:error, {:already_claimed, body}}
        end

      {:error, _} ->
        :ok
    end
  end

  @impl true
  def signal_claim(ref, task_id, %{
        workspace_name: name,
        workspace_prefix: prefix,
        current_user: member_id,
        host: host
      }) do
    body =
      "Claimed as #{task_id} by #{name} (#{prefix}). #{@ownership_marker} #{host}."

    post_comment(ref, body)
    assign_user(ref, member_id)
    :ok
  end

  @impl true
  def current_user do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, %{"id" => id}} when is_binary(id) <-
           request(cfg, :get, "/member", []) |> handle_json() do
      {:ok, id}
    else
      {:ok, _other} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: nil,
           message: "GET /member returned no id",
           raw: nil
         }}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def assignees(%{"owner_ids" => ids}) when is_list(ids), do: ids
  def assignees(_), do: []

  @impl true
  def issue_status(%{"completed" => true}), do: :closed
  def issue_status(%{"started" => true}), do: :in_progress
  def issue_status(_), do: :open

  @impl true
  def extract_title(%{"name" => name}) when is_binary(name) and name != "", do: name
  def extract_title(_), do: "(no title)"

  @impl true
  def extract_description(%{"description" => desc}) when is_binary(desc), do: desc
  def extract_description(_), do: ""

  # ---- Public helpers ------------------------------------------------------

  @doc """
  Convenience: set the active workspace for the current process and run `fun`,
  clearing the config when `fun` returns. Useful in tests and one-shot scripts.
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

  # ---- Internals: title search --------------------------------------------

  defp normalize_title(title), do: title |> String.downcase() |> String.trim()

  # ---- Internals: list_open -----------------------------------------------

  defp fetch_stories_by_owner(cfg, member_id) do
    payload = %{
      "owner_ids" => [member_id],
      "completed" => false,
      "archived" => false
    }

    case request(cfg, :post, "/stories/search", json: payload) do
      {:ok, %Req.Response{status: status_code, body: stories}}
      when status_code in 200..299 and is_list(stories) ->
        {:ok, Enum.map(stories, &summarize_story/1)}

      {:ok, %Req.Response{status: status_code, body: _body}} when status_code in 200..299 ->
        {:ok, []}

      {:ok, %Req.Response{status: status_code, body: body}} ->
        {:error, http_error(status_code, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  defp summarize_story(%{"id" => id} = story) do
    %{
      ref: to_string(id),
      title: Map.get(story, "name") || "(no title)",
      url: Map.get(story, "app_url"),
      status: issue_status(story),
      assignees: assignees(story),
      raw: story
    }
  end

  # ---- Internals: claim helpers -------------------------------------------

  defp list_comments(ref) do
    with {:ok, cfg} <- Config.resolve() do
      case request(cfg, :get, "/stories/#{ref}/comments", []) do
        {:ok, %Req.Response{status: status_code, body: list}}
        when status_code in 200..299 and is_list(list) ->
          {:ok, list}

        {:ok, %Req.Response{status: status_code, body: body}} when status_code in 200..299 ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: status_code,
             message: "comments response was not a list",
             raw: body
           }}

        {:ok, %Req.Response{status: status_code, body: body}} ->
          {:error, http_error(status_code, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  defp post_comment(ref, text) do
    with {:ok, cfg} <- Config.resolve() do
      case request(cfg, :post, "/stories/#{ref}/comments", json: %{"text" => text}) do
        {:ok, %Req.Response{status: status_code}} when status_code in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status_code, body: body}} ->
          {:error, http_error(status_code, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  defp assign_user(ref, member_id) do
    with {:ok, cfg} <- Config.resolve() do
      current_ids =
        case request(cfg, :get, "/stories/#{ref}", []) |> handle_json() do
          {:ok, %{"owner_ids" => ids}} when is_list(ids) -> ids
          _ -> []
        end

      new_ids = Enum.uniq([member_id | current_ids])

      case request(cfg, :put, "/stories/#{ref}", json: %{"owner_ids" => new_ids}) do
        {:ok, %Req.Response{status: status_code}} when status_code in 200..299 ->
          :ok

        {:ok, %Req.Response{status: status_code, body: body}} ->
          {:error, http_error(status_code, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  # ---- Internals: workflows / states --------------------------------------

  defp list_workflows(cfg) do
    case request(cfg, :get, "/workflows", []) do
      {:ok, %Req.Response{status: status_code, body: list}}
      when status_code in 200..299 and is_list(list) ->
        {:ok, list}

      {:ok, %Req.Response{status: status_code, body: body}} when status_code in 200..299 ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: status_code,
           message: "workflows response was not a list",
           raw: body
         }}

      {:ok, %Req.Response{status: status_code, body: body}} ->
        {:error, http_error(status_code, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # All workflow states, narrowed to the configured workflow_id when set.
  defp states_for(%{workflow_id: workflow_id}, workflows) do
    workflows
    |> Enum.filter(fn wf ->
      is_nil(workflow_id) or Map.get(wf, "id") == workflow_id
    end)
    |> Enum.flat_map(fn wf -> Map.get(wf, "states") || [] end)
  end

  defp map_status(%{status_map: map}, status) do
    case Map.fetch(map, status) do
      {:ok, name} when is_binary(name) and name != "" ->
        {:ok, name}

      _ ->
        {:error,
         %Error{
           kind: :transition_not_found,
           status: nil,
           message: "no Shortcut state name mapped for task status #{inspect(status)}",
           raw: nil
         }}
    end
  end

  defp find_state_id(cfg, workflows, target_name) do
    states = states_for(cfg, workflows)

    case Enum.find(states, fn %{"name" => n} -> n == target_name end) do
      %{"id" => id} when is_integer(id) ->
        {:ok, id}

      _ ->
        {:error,
         %Error{
           kind: :transition_not_found,
           status: nil,
           message:
             "Shortcut state #{inspect(target_name)} not found; " <>
               "available: #{inspect(Enum.map(states, & &1["name"]))}",
           raw: workflows
         }}
    end
  end

  # ---- Internals: field translation ---------------------------------------

  # Task-domain field keys -> Shortcut story attributes.
  @field_map %{
    title: "name",
    description: "description"
  }

  defp translate_fields(fields_map) do
    Enum.reduce(fields_map, %{}, fn {key, value}, acc ->
      atom_key = if is_atom(key), do: key, else: safe_atom(key)

      case Map.fetch(@field_map, atom_key) do
        {:ok, sc_key} -> Map.put(acc, sc_key, value)
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

  defp integer_ref(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> {:ok, Integer.to_string(n)}
      _ -> :error
    end
  end

  # ---- Internals: HTTP ----------------------------------------------------

  defp request(cfg, method, path, req_opts) do
    full_opts =
      [
        method: method,
        url: @base_url <> path,
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

  defp headers(%{token: token}) do
    [
      {"shortcut-token", token},
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

  defp error_message(%{"message" => msg}, _) when is_binary(msg), do: msg

  defp error_message(%{"errors" => errors}, status_code),
    do: "HTTP #{status_code}: #{inspect(errors)}"

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
    if Application.get_env(:arbiter, :shortcut_http_stub, false) do
      [plug: {Req.Test, @stub_name}]
    else
      []
    end
  end
end
