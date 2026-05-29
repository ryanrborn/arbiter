defmodule Arbiter.Mergers.Gitlab do
  @moduledoc """
  GitLab adapter implementing `Arbiter.Mergers.Merger`.

  Wraps GitLab's REST API v4 for merge-request open / inspect / merge /
  close / comment / review flows. This is the priority hosted-forge merger:
  the `tonic` and `tonic_device` projects live on GitLab.

  ## Active-workspace contract

  The `Merger` callbacks take an opaque `mr_ref` (e.g. `"!42"`) with no
  workspace context. But GitLab needs a host, project ID and token — all
  workspace-scoped. We resolve those through `Arbiter.Mergers.Gitlab.Config`,
  exactly as `Arbiter.Trackers.Jira` does:

    1. Callers call `Config.put_active(workspace)` to populate the
       per-process config.
    2. `Application.get_env(:arbiter, :gitlab_default_config)` is the
       fallback for tools that run without a workspace context.
    3. With neither, callbacks return `{:error, %Error{kind: :config_missing}}`.

  ## `mr_ref`

  GitLab identifies a merge request within a project by its `iid` (a
  per-project integer). We mint the `mr_ref` as the iid prefixed with `"!"`
  (GitLab's own MR shorthand), e.g. `"!42"`. `parse_ref/1` additionally
  accepts a bare integer (`"42"` / `42`) and a full GitLab MR URL.

  ## Auth

  GitLab uses a `Private-Token: <token>` header. The token comes from the
  workspace merger config's `credentials_ref` (`"env:NAME"` or a literal).

  ## `get/1` response

  Returns the bead-domain view of the MR:

      %{ref: mr_ref, status: :open | :merged | :closed, approved: boolean(), url: String.t()}

  GitLab states map as: `"opened" -> :open`, `"merged" -> :merged`,
  `"closed" | "locked" -> :closed`.

  ## Tests

  Wired up to `Req.Test`: when
  `Application.get_env(:arbiter, :gitlab_http_stub, false)` is true, every
  request injects `plug: {Req.Test, #{inspect(Arbiter.Mergers.Gitlab.HTTP)}}`.
  This adapter **never** hits a real GitLab endpoint from tests.
  """

  @behaviour Arbiter.Mergers.Merger

  alias Arbiter.Mergers.Gitlab.{Config, Error}

  @stub_name Arbiter.Mergers.Gitlab.HTTP

  # ---- Merger behaviour ----------------------------------------------------

  @impl true
  def open(branch, title, description, opts)
      when is_binary(branch) and is_binary(title) and is_binary(description) and is_map(opts) do
    with {:ok, cfg} <- Config.resolve() do
      payload =
        %{
          "source_branch" => branch,
          "target_branch" => Map.get(opts, :target_branch) || cfg.default_target_branch,
          "title" => title,
          "description" => description
        }
        |> maybe_put("reviewer_ids", reviewers(opts, cfg))
        |> maybe_put("labels", labels(opts))

      case request(cfg, :post, "/merge_requests", json: payload) do
        {:ok, %Req.Response{status: status, body: %{"iid" => iid}}}
        when status in 200..299 and is_integer(iid) ->
          {:ok, ref_for(iid)}

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: status,
             message: "merge-request response missing integer \"iid\"",
             raw: body
           }}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, http_error(status, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  @impl true
  def get(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref) do
      case request(cfg, :get, "/merge_requests/#{iid}", []) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok,
           %{
             ref: ref_for(iid),
             status: map_state(Map.get(body, "state")),
             approved: approved?(body),
             url: Map.get(body, "web_url") || link_for(ref_for(iid))
           }}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, http_error(status, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  @impl true
  def merge(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref) do
      request(cfg, :put, "/merge_requests/#{iid}/merge", json: %{})
      |> handle_ok()
    end
  end

  @impl true
  def close(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref) do
      request(cfg, :put, "/merge_requests/#{iid}", json: %{"state_event" => "close"})
      |> handle_ok()
    end
  end

  @impl true
  def add_comment(mr_ref, body) when is_binary(mr_ref) and is_binary(body) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref) do
      request(cfg, :post, "/merge_requests/#{iid}/notes", json: %{"body" => body})
      |> handle_ok()
    end
  end

  @impl true
  def request_review(mr_ref, reviewers) when is_binary(mr_ref) and is_list(reviewers) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref) do
      request(cfg, :put, "/merge_requests/#{iid}", json: %{"reviewer_ids" => reviewers})
      |> handle_ok()
    end
  end

  @impl true
  def link_for(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref) do
      "https://#{cfg.host}/#{cfg.project_id}/-/merge_requests/#{iid}"
    else
      _ -> ""
    end
  end

  # ---- Public helpers ------------------------------------------------------

  @doc """
  Parse a user- or system-supplied MR reference into the canonical
  `mr_ref` form (`"!<iid>"`).

  Accepts:

    * the `"!42"` shorthand,
    * a bare integer, as a binary (`"42"`) or an integer (`42`),
    * a full GitLab MR URL (`".../-/merge_requests/42"`).

  Returns `{:ok, mr_ref}` or `:error`.
  """
  @spec parse_ref(String.t() | integer()) :: {:ok, Arbiter.Mergers.Merger.mr_ref()} | :error
  def parse_ref(iid) when is_integer(iid) and iid > 0, do: {:ok, ref_for(iid)}

  def parse_ref(s) when is_binary(s) do
    s = String.trim(s)

    cond do
      String.starts_with?(s, "http://") or String.starts_with?(s, "https://") ->
        case Regex.run(~r{/-/merge_requests/(\d+)}, s) do
          [_, iid] -> {:ok, ref_for(iid)}
          _ -> :error
        end

      match?([_, _], Regex.run(~r/^!(\d+)$/, s)) ->
        [_, iid] = Regex.run(~r/^!(\d+)$/, s)
        {:ok, ref_for(iid)}

      Regex.match?(~r/^\d+$/, s) ->
        {:ok, ref_for(s)}

      true ->
        :error
    end
  end

  def parse_ref(_), do: :error

  @doc """
  Convenience: set the active workspace for the current process and run
  `fun`, restoring the previous config when `fun` returns. Useful in tests
  and one-shot scripts. Mirrors `Arbiter.Trackers.Jira.with_workspace/2`.
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

  # ---- Internals: ref handling --------------------------------------------

  defp ref_for(iid) when is_integer(iid), do: "!" <> Integer.to_string(iid)
  defp ref_for(iid) when is_binary(iid), do: "!" <> iid

  # The behaviour callbacks receive the canonical "!<iid>" form, but tolerate
  # a bare integer string too in case a caller hands one through directly.
  defp iid_from_ref(ref) do
    case parse_ref(ref) do
      {:ok, "!" <> iid} ->
        {:ok, iid}

      :error ->
        {:error,
         %Error{
           kind: :bad_ref,
           status: nil,
           message: "could not parse GitLab mr_ref #{inspect(ref)}",
           raw: ref
         }}
    end
  end

  # ---- Internals: payload helpers -----------------------------------------

  defp reviewers(opts, cfg) do
    case Map.get(opts, :reviewer_ids) do
      ids when is_list(ids) and ids != [] -> ids
      _ -> cfg.default_reviewers
    end
  end

  defp labels(opts) do
    case Map.get(opts, :labels) do
      labels when is_list(labels) and labels != [] -> Enum.join(labels, ",")
      _ -> nil
    end
  end

  # Omit empty/nil values so we send a minimal body (GitLab treats an empty
  # reviewer_ids list as "clear reviewers", which is not what `open` means).
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ---- Internals: response shaping ----------------------------------------

  defp map_state("opened"), do: :open
  defp map_state("merged"), do: :merged
  defp map_state("closed"), do: :closed
  defp map_state("locked"), do: :closed
  defp map_state(_), do: :open

  # `approved` is present when the project uses approval rules; absent
  # otherwise. Treat absence as "not approved".
  defp approved?(%{"approved" => approved}) when is_boolean(approved), do: approved
  defp approved?(_), do: false

  defp handle_ok({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp handle_ok({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, http_error(status, body)}

  defp handle_ok({:error, exception}), do: {:error, transport_error(exception)}

  # ---- Internals: HTTP ----------------------------------------------------

  defp request(cfg, method, path, req_opts) do
    url = "https://#{cfg.host}/api/v4/projects/#{cfg.project_id}" <> path

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
  defp kind_for_status(405), do: :conflict
  defp kind_for_status(406), do: :conflict
  defp kind_for_status(409), do: :conflict
  defp kind_for_status(422), do: :validation_failed
  defp kind_for_status(s) when s >= 500 and s < 600, do: :server_error
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
    %Error{kind: :network, status: nil, message: inspect(other), raw: other}
  end

  defp stub_opts do
    if Application.get_env(:arbiter, :gitlab_http_stub, false) do
      [plug: {Req.Test, @stub_name}]
    else
      []
    end
  end
end
