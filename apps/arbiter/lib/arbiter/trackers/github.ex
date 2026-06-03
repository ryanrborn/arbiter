defmodule Arbiter.Trackers.GitHub do
  @moduledoc """
  GitHub Issues adapter implementing `Arbiter.Trackers.Tracker`.

  Wraps GitHub's REST API v3 (`https://api.github.com`) for issue
  fetch/update/transition flows, so directives can sync to GitHub Issues.

  ## Active-workspace contract

  The `Tracker` behaviour callbacks take a `ref` (the issue number as a
  string, e.g. `"42"`) with no workspace context. But GitHub needs an owner,
  repo, token, and a bead-status → state/label mapping — all workspace-scoped.
  We resolve those through `Arbiter.Trackers.GitHub.Config`, exactly as the
  Jira and Shortcut adapters do for their backends:

    1. Callers (request middleware, CLI command, scheduler job) call
       `Config.put_active(workspace)` to populate the per-process config.
    2. `Application.get_env(:arbiter, :github_tracker_default_config)` is the
       fallback for tools that run without a workspace context.
    3. With neither, callbacks return `{:error, %Error{kind: :config_missing}}`.

  ## `ref`

  The canonical ref is the bare issue number as a string (`"42"`). Owner / repo
  come from the resolved workspace config — the ref carries only the
  issue-local datum, mirroring how the Jira tracker's ref is the issue key with
  host / project resolved from config. `parse_ref/1` accepts the bare number,
  the `"github:"`/`"gh-"`/`"#"` prefixes, and full issue URLs.

  ## Auth

  GitHub uses **Bearer** auth (`Authorization: Bearer <token>`). The
  credentials reference lives in the tracker config; `credentials_ref` is a
  small DSL — currently only `"env:NAME"` is supported (looks up
  `System.get_env/1`); a bare string is treated as a literal token.

  ## Status mapping

  GitHub Issues have only two native states — `open` and `closed` — so the
  bead-vocabulary `:in_progress` is expressed as an open issue carrying a
  label (default `"in progress"`). `transition/2`:

    1. Resolves the target status to a `%{state, label}` pair via the
       workspace's `status_map` (see `Arbiter.Trackers.GitHub.Config`).
    2. Fetches the issue to read its current labels.
    3. Swaps the *managed* status labels — adds the target's label and removes
       the other statuses' labels — leaving any unrelated labels untouched.
    4. `PATCH`es the issue with the new `state` + `labels`.

  ## Tests

  Wired up to `Req.Test`: when
  `Application.get_env(:arbiter, :github_http_stub, false)` is true, every
  request injects `plug: {Req.Test, #{inspect(Arbiter.Trackers.GitHub.HTTP)}}`.
  This adapter **never** hits a real GitHub endpoint from tests.
  """

  @behaviour Arbiter.Trackers.Tracker

  alias Arbiter.Trackers.GitHub.{Config, Error}

  @stub_name Arbiter.Trackers.GitHub.HTTP

  # ---- Tracker behaviour ---------------------------------------------------

  @impl true
  def fetch(ref) when is_binary(ref) do
    with {:ok, cfg} <- Config.resolve() do
      request(cfg, :get, issue_path(cfg, ref), [])
      |> handle_json()
    end
  end

  @impl true
  def transition(ref, status) when is_binary(ref) and is_atom(status) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, %{state: state, label: label}} <- map_status(cfg, status),
         {:ok, issue} <- request(cfg, :get, issue_path(cfg, ref), []) |> handle_json() do
      payload = %{
        "state" => state,
        "labels" => next_labels(cfg, issue, label)
      }

      request(cfg, :patch, issue_path(cfg, ref), json: payload)
      |> expect_ok()
    end
  end

  @impl true
  def update_fields(ref, fields_map) when is_binary(ref) and is_map(fields_map) do
    with {:ok, cfg} <- Config.resolve() do
      payload = translate_fields(fields_map)

      request(cfg, :patch, issue_path(cfg, ref), json: payload)
      |> expect_ok()
    end
  end

  @impl true
  def link_for(ref) when is_binary(ref) do
    case Config.active_repo_slug() do
      slug when is_binary(slug) -> "https://github.com/#{slug}/issues/#{ref}"
      nil -> "https://github.com/owner/repo/issues/#{ref}"
    end
  end

  @impl true
  def parse_ref(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "github:") ->
        s |> String.replace_prefix("github:", "") |> integer_ref()

      String.starts_with?(s, "gh-") ->
        s |> String.replace_prefix("gh-", "") |> integer_ref()

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
         {:ok, login} <- resolve_assignee(opts) do
      case fetch_assigned_open_issues(cfg, login) do
        {:ok, issues} -> {:ok, Enum.map(issues, &summarize/1)}
        {:error, _} = err -> err
      end
    end
  end

  @impl true
  def list_transitions(ref) when is_binary(ref) do
    # GitHub imposes no transition state machine — an issue can move to any of
    # the mapped statuses at any time — so we validate the ref exists, then
    # return every bead status the workspace knows how to map.
    with {:ok, cfg} <- Config.resolve(),
         {:ok, _issue} <- request(cfg, :get, issue_path(cfg, ref), []) |> handle_json() do
      statuses =
        [:open, :in_progress, :closed]
        |> Enum.filter(&Map.has_key?(cfg.status_map, &1))

      {:ok, statuses}
    end
  end

  # ---- Public helpers ------------------------------------------------------

  @doc """
  Convenience: set the active workspace for the current process and run `fun`,
  restoring the previous config when `fun` returns. Useful in tests and
  one-shot scripts. Mirrors `Arbiter.Trackers.Jira.with_workspace/2`.
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

  @doc """
  Returns the authenticated user's login (the "viewer") associated with the
  active workspace's token. Used by `arb claim` and `arb sync` to enforce
  assignment-as-claim: a bead is only created for an issue assigned to *this*
  workspace's GitHub user.
  """
  @spec viewer_login() :: {:ok, String.t()} | {:error, Error.t()}
  def viewer_login do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, %{"login" => login}} when is_binary(login) <-
           request(cfg, :get, "/user", []) |> handle_json() do
      {:ok, login}
    else
      {:ok, _other} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: nil,
           message: "GET /user returned no login",
           raw: nil
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Lists open issues in the workspace's repo assigned to the given login.

  Pull requests are filtered out — GitHub's `/repos/:owner/:repo/issues`
  endpoint returns both, distinguished by a `"pull_request"` key.

  Paginated: walks `Link: <...>; rel="next"` headers until exhausted, so
  workspaces with >100 assigned issues still come back complete.
  """
  @spec list_assigned_open_issues(String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_assigned_open_issues(login) when is_binary(login) do
    with {:ok, cfg} <- Config.resolve() do
      fetch_assigned_open_issues(cfg, login)
    end
  end

  @doc """
  Extracts assignee logins from a fetched issue map. Tolerant of GitHub's two
  shapes: `"assignees"` (a list of user maps) and the legacy `"assignee"`
  (a single user map).
  """
  @spec assignee_logins(map()) :: [String.t()]
  def assignee_logins(%{"assignees" => list}) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"login" => login} when is_binary(login) -> [login]
      _ -> []
    end)
    |> Enum.uniq()
  end

  def assignee_logins(%{"assignee" => %{"login" => login}}) when is_binary(login), do: [login]
  def assignee_logins(_), do: []

  @doc """
  Returns the issue's bead-vocabulary status from its raw GitHub payload.

  GitHub Issues only have `"open"` / `"closed"` natively; this is sufficient
  for `arb sync`'s reconcile logic (which only cares whether to close a bead
  whose issue went to `"closed"`).
  """
  @spec issue_status(map()) :: :open | :closed
  def issue_status(%{"state" => "closed"}), do: :closed
  def issue_status(_), do: :open

  # ---- Internals: list_open / pagination ---------------------------------

  # Resolve the assignee opt to a concrete GitHub login. Default (`:viewer`)
  # asks GitHub for the token's authenticated user — keeps the caller from
  # having to thread "who am I" through the API.
  defp resolve_assignee(opts) do
    case Keyword.get(opts, :assignee, :viewer) do
      :viewer ->
        viewer_login()

      login when is_binary(login) and login != "" ->
        {:ok, login}

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

  # Paginated fetch: walks the Link header's rel="next" until exhausted.
  # Returns the accumulated list of issues, with PRs filtered out (GitHub's
  # /issues endpoint mixes them in).
  defp fetch_assigned_open_issues(cfg, login) do
    initial_path = "/repos/#{cfg.owner}/#{cfg.repo}/issues"
    initial_params = [assignee: login, state: "open", per_page: 100]

    paginate(cfg, initial_path, params: initial_params)
  end

  # Cap pages so a runaway response can't hammer the API. 50 pages × 100/page
  # = 5,000 issues, well above any human's claimable backlog.
  @max_pages 50

  defp paginate(cfg, path, req_opts) do
    do_paginate(cfg, path, req_opts, [], @max_pages)
  end

  defp do_paginate(_cfg, _path, _req_opts, acc, 0), do: {:ok, Enum.reverse(acc) |> List.flatten()}

  defp do_paginate(cfg, path, req_opts, acc, pages_left) do
    case request(cfg, :get, path, req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        page = if is_list(body), do: body, else: []
        filtered = Enum.reject(page, &Map.has_key?(&1, "pull_request"))

        case next_page_url(headers) do
          nil ->
            {:ok, Enum.reverse([filtered | acc]) |> List.flatten()}

          {next_path, next_params} ->
            do_paginate(cfg, next_path, [params: next_params], [filtered | acc], pages_left - 1)
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # Parses GitHub's RFC 5988 Link header. Returns the rel="next" URL split
  # into its path-relative-to-base + query params, or nil if no next page.
  defp next_page_url(headers) do
    headers
    |> link_header_value()
    |> parse_next_link()
  end

  defp link_header_value(headers) when is_map(headers) do
    case Map.get(headers, "link") || Map.get(headers, "Link") do
      [v | _] when is_binary(v) -> v
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp link_header_value(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {"link", v} -> v
      {"Link", v} -> v
      _ -> nil
    end)
  end

  defp link_header_value(_), do: nil

  defp parse_next_link(nil), do: nil

  defp parse_next_link(value) when is_binary(value) do
    case Regex.run(~r/<([^>]+)>\s*;\s*rel="next"/, value) do
      [_, url] -> split_url(url)
      _ -> nil
    end
  end

  defp split_url(url) do
    uri = URI.parse(url)

    params =
      case uri.query do
        nil -> []
        q -> URI.decode_query(q) |> Enum.to_list()
      end

    {uri.path || "/", params}
  end

  # Normalizes a raw issue payload into a Tracker.summary.
  defp summarize(%{"number" => number} = issue) do
    %{
      ref: to_string(number),
      title: title_or_default(issue),
      url: Map.get(issue, "html_url"),
      status: status_for(issue),
      assignees: assignee_logins(issue),
      raw: issue
    }
  end

  defp title_or_default(%{"title" => title}) when is_binary(title) and title != "", do: title
  defp title_or_default(_), do: "(no title)"

  # An "in progress" issue is an open issue carrying one of the in_progress
  # labels in the workspace's status_map. Anything else open is :open;
  # anything else closed is :closed.
  defp status_for(%{"state" => "closed"}), do: :closed

  defp status_for(issue) do
    cfg = active_status_map()

    in_progress_label =
      case Map.get(cfg, :in_progress) do
        %{label: label} when is_binary(label) -> label
        _ -> nil
      end

    if in_progress_label && in_progress_label in current_label_names(issue) do
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
      {:ok, %{state: state} = entry} when state in ["open", "closed"] ->
        {:ok, entry}

      _ ->
        {:error,
         %Error{
           kind: :transition_not_found,
           status: nil,
           message: "no GitHub state mapped for bead status #{inspect(status)}",
           raw: nil
         }}
    end
  end

  # Labels the adapter owns: every label named in the status_map. On a
  # transition we strip all of these, then add back the target's label — so
  # an issue never carries two status labels at once, and labels the adapter
  # didn't set are preserved.
  defp next_labels(cfg, issue, target_label) do
    managed =
      cfg.status_map
      |> Map.values()
      |> Enum.map(& &1.label)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    kept =
      issue
      |> current_label_names()
      |> Enum.reject(&MapSet.member?(managed, &1))

    case target_label do
      nil -> Enum.uniq(kept)
      label -> Enum.uniq(kept ++ [label])
    end
  end

  defp current_label_names(%{"labels" => labels}) when is_list(labels) do
    Enum.flat_map(labels, fn
      %{"name" => name} when is_binary(name) -> [name]
      name when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp current_label_names(_), do: []

  # ---- Internals: field translation ---------------------------------------

  # Bead-domain field keys -> GitHub issue attributes.
  @field_map %{
    title: "title",
    description: "body"
  }

  defp translate_fields(fields_map) do
    Enum.reduce(fields_map, %{}, fn {key, value}, acc ->
      atom_key = if is_atom(key), do: key, else: safe_atom(key)

      case Map.fetch(@field_map, atom_key) do
        {:ok, gh_key} -> Map.put(acc, gh_key, value)
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

  defp issue_path(cfg, ref), do: "/repos/#{cfg.owner}/#{cfg.repo}/issues/#{ref}"

  # ---- Internals: HTTP ----------------------------------------------------

  defp request(cfg, method, path, req_opts) do
    full_opts =
      [
        method: method,
        url: cfg.base_url <> path,
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
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
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

  defp error_message(%{"message" => msg}, _status) when is_binary(msg), do: msg
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
    if Application.get_env(:arbiter, :github_http_stub, false) do
      [plug: {Req.Test, @stub_name}]
    else
      []
    end
  end
end
