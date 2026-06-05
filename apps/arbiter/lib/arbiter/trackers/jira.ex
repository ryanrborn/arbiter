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

  This mirrors `Arbiter.Vernacular.put_active/1`. Two alternatives were
  considered and rejected:

    * **Extra `Workspace` argument**: breaks the behaviour signature and
      forces every caller to thread workspace through the stack.
    * **Resolve workspace from the bead via Ash inside the adapter**: the
      adapter takes only a `ref` (string), not the bead — and reaching back
      to Ash from inside a tracker callback couples the HTTP layer to the
      database. Worse for testability.

  ## Auth

  Jira Cloud uses **Basic auth** (NOT Bearer) with `email:api_token`. The
  email and the credentials reference both live in the workspace tracker
  config. `credentials_ref` is a small DSL — currently only `"env:NAME"`
  is supported (looks up `System.get_env/1`); a bare string is treated as
  a literal token.

  ## Status mapping

  Bead-vocabulary atoms (`:open | :in_progress | :closed`) map to Jira
  *transition names* (not status names — Jira's REST API moves issues by
  invoking a transition). Defaults are conservative ("To Do", "In Progress",
  "Done"); each workspace can override via `tracker.config.status_map`.

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
         {:ok, target_name} <- map_status(cfg, status),
         {:ok, transitions} <- list_raw_transitions(cfg, ref),
         {:ok, transition_id} <- find_transition_id(transitions, target_name) do
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
  def list_open(_opts) do
    # `arb list --tracker` currently only ships the GitHub backlog query.
    # When Jira's "open + assigned to currentUser()" JQL is wired up, this
    # returns the normalized summary list.
    {:error, :not_supported}
  end

  @impl true
  def create(_attrs) do
    # Outbound create not yet implemented for Jira — `arb create` on a
    # Jira-configured workspace currently only creates the local bead. Wire
    # this up when the Jira create path is needed (analogous to GitHub.create).
    {:error, :not_supported}
  end

  @impl true
  def list_transitions(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, jira_transitions} <- list_raw_transitions(cfg, ref) do
      # Reverse-map Jira transition names to bead-status atoms via the
      # workspace's status_map (which maps atom -> Jira name).
      reverse = Enum.into(cfg.status_map, %{}, fn {k, v} -> {v, k} end)

      atoms =
        jira_transitions
        |> Enum.map(fn %{"name" => name} -> Map.get(reverse, name) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, atoms}
    end
  end

  # ---- Public helpers ------------------------------------------------------

  @doc """
  Convenience: set the active workspace for the current process and run
  `fun`, clearing the config when `fun` returns. Useful in tests and
  one-shot scripts.
  """
  @spec with_workspace(map() | Arbiter.Beads.Workspace.t(), (-> result)) :: result
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

  defp map_status(%{status_map: map}, status) do
    case Map.fetch(map, status) do
      {:ok, name} when is_binary(name) and name != "" ->
        {:ok, name}

      _ ->
        {:error,
         %Error{
           kind: :transition_not_found,
           status: nil,
           message: "no Jira transition name mapped for bead status #{inspect(status)}",
           raw: nil
         }}
    end
  end

  defp find_transition_id(transitions, target_name) do
    case Enum.find(transitions, fn %{"name" => n} -> n == target_name end) do
      %{"id" => id} when is_binary(id) ->
        {:ok, id}

      _ ->
        {:error,
         %Error{
           kind: :transition_not_found,
           status: nil,
           message:
             "Jira transition #{inspect(target_name)} not available in current state; " <>
               "available: #{inspect(Enum.map(transitions, & &1["name"]))}",
           raw: transitions
         }}
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
