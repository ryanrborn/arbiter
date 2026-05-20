defmodule GtElixir.GitHub do
  @moduledoc """
  Thin HTTP wrapper around the GitHub REST API (plus one GraphQL call for
  resolving review threads) used by the polecat-orchestrator (gte-020/021/022)
  to open PRs, watch reviews, post comments, and merge.

  ## Design

    * Every public function returns `{:ok, value}` or
      `{:error, %GtElixir.GitHub.Error{}}`. The `Error.kind` is a small enum
      mapped from HTTP status (see `t:GtElixir.GitHub.Error.kind/0`).

    * The auth token is read from `GITHUB_TOKEN` by default; callers can
      override per-call via `opts[:token]`. The env var is only consulted at
      call time — not at module load — so the application can boot without it.
      A call with no token from either source raises `ArgumentError` (it is a
      programmer error, not a runtime failure mode).

    * Every response — successful or 4xx/5xx — updates a process-global
      rate-limit cache in `:persistent_term` keyed by
      `:gt_elixir_github_rate_limit`. Read it with `rate_limit/0`. This avoids
      complicating every success tuple with a third element.

    * `pr_resolve_thread/3` is the lone non-REST call. The REST API does not
      expose thread resolution; the GraphQL `resolveReviewThread` mutation is
      used instead.

  ## Tests

  In `:test`, application env `:gt_elixir, :github_http_stub, true` causes
  this module to inject `plug: {Req.Test, GtElixir.GitHub.HTTP}` into every
  request so tests can stub responses with `Req.Test.stub/2`.
  """

  alias GtElixir.GitHub.Error

  @type repo :: String.t()
  @type pr_number :: pos_integer()
  @type strategy :: :merge | :squash | :rebase
  @type opts :: keyword()
  @type result(t) :: {:ok, t} | {:error, Error.t()}

  @default_base_url "https://api.github.com"
  @rate_limit_key :gt_elixir_github_rate_limit
  @stub_name GtElixir.GitHub.HTTP

  # ---- Public API ----------------------------------------------------------

  @doc """
  Open a pull request. On success returns `{:ok, %{number: integer, ...}}`
  with the full GitHub PR payload merged into the map.
  """
  @spec pr_open(repo, String.t(), String.t(), String.t(), String.t(), opts) ::
          result(map())
  def pr_open(repo, branch, target, title, body, opts \\ []) do
    payload = %{
      "head" => branch,
      "base" => target,
      "title" => title,
      "body" => body
    }

    request(:post, "/repos/#{repo}/pulls", [json: payload], opts)
    |> handle_json()
  end

  @doc """
  Get a pull request by number. Returns the parsed JSON map on success
  (containing keys like `"state"`, `"mergeable"`, `"commits"`, etc.). The
  `reviewDecision` field is only exposed via the GraphQL API; callers who
  need it should combine this with `pr_list_reviews/3`.
  """
  @spec pr_get(repo, pr_number, opts) :: result(map())
  def pr_get(repo, pr_number, opts \\ []) do
    request(:get, "/repos/#{repo}/pulls/#{pr_number}", [], opts)
    |> handle_json()
  end

  @doc "List reviews (approvals, change-requests, comments) on a PR."
  @spec pr_list_reviews(repo, pr_number, opts) :: result([map()])
  def pr_list_reviews(repo, pr_number, opts \\ []) do
    request(:get, "/repos/#{repo}/pulls/#{pr_number}/reviews", [], opts)
    |> handle_json()
  end

  @doc "Post a top-level (issue-style) comment on a PR."
  @spec pr_comment(repo, pr_number, String.t(), opts) :: result(map())
  def pr_comment(repo, pr_number, body, opts \\ []) do
    request(
      :post,
      "/repos/#{repo}/issues/#{pr_number}/comments",
      [json: %{"body" => body}],
      opts
    )
    |> handle_json()
  end

  @doc """
  Post an inline (line-anchored) review comment on a PR.

  GitHub requires a `commit_id` (head SHA) on inline comments. Callers can
  pass it via `opts[:commit_id]`; otherwise this function fetches the PR
  first to read `head.sha`. Pre-fetching is the safe default but adds a
  round-trip — pass `:commit_id` if you already have it.
  """
  @spec pr_inline_comment(repo, pr_number, String.t(), pos_integer(), String.t(), opts) ::
          result(map())
  def pr_inline_comment(repo, pr_number, path, line, body, opts \\ []) do
    with {:ok, commit_id} <- fetch_commit_id(repo, pr_number, opts) do
      payload = %{
        "body" => body,
        "path" => path,
        "line" => line,
        "commit_id" => commit_id,
        "side" => "RIGHT"
      }

      request(
        :post,
        "/repos/#{repo}/pulls/#{pr_number}/comments",
        [json: payload],
        opts
      )
      |> handle_json()
    end
  end

  @doc """
  Resolve a review thread by its node ID. This is the lone GraphQL call in
  the module — the REST API does not support thread resolution. Returns
  `{:ok, thread_node}` on success.
  """
  @spec pr_resolve_thread(repo, String.t(), opts) :: result(map())
  def pr_resolve_thread(_repo, thread_id, opts \\ []) do
    query = """
    mutation ResolveReviewThread($id: ID!) {
      resolveReviewThread(input: {threadId: $id}) {
        thread { id isResolved }
      }
    }
    """

    payload = %{"query" => query, "variables" => %{"id" => thread_id}}

    case graphql_request(payload, opts) do
      {:ok, %{"errors" => [first | _] = errors}} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: 200,
           message: Map.get(first, "message", "graphql error"),
           raw: %{"errors" => errors}
         }}

      {:ok, %{"data" => %{"resolveReviewThread" => %{"thread" => thread}}}} ->
        {:ok, thread}

      {:ok, other} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: 200,
           message: "unexpected GraphQL response shape",
           raw: other
         }}

      {:error, _} = err ->
        err
    end
  end

  @typedoc """
  Verdict event for a PR review. Maps to GitHub's `event` field on
  `POST /repos/:owner/:repo/pulls/:number/reviews`:

    * `:approve`         → `APPROVE`
    * `:request_changes` → `REQUEST_CHANGES`
    * `:comment`         → `COMMENT`
  """
  @type review_event :: :approve | :request_changes | :comment

  @doc """
  Submit a top-level review on a PR with an approve / request-changes /
  comment verdict. This is the typed Elixir replacement for the Go GT's
  `gh pr review --approve / --request-changes` shell-out.

  `body` is the review summary; pass `""` for an approve-with-no-comment.

  Returns `{:ok, review_payload}` on success.
  """
  @spec pr_review(repo, pr_number, review_event, String.t(), opts) :: result(map())
  def pr_review(repo, pr_number, event, body \\ "", opts \\ [])
      when event in [:approve, :request_changes, :comment] do
    payload = %{
      "body" => body,
      "event" => event_to_github(event)
    }

    request(
      :post,
      "/repos/#{repo}/pulls/#{pr_number}/reviews",
      [json: payload],
      opts
    )
    |> handle_json()
  end

  defp event_to_github(:approve), do: "APPROVE"
  defp event_to_github(:request_changes), do: "REQUEST_CHANGES"
  defp event_to_github(:comment), do: "COMMENT"

  @doc """
  Merge a PR. `strategy` is one of `:merge`, `:squash`, `:rebase` and maps
  to GitHub's `merge_method` parameter.
  """
  @spec pr_merge(repo, pr_number, strategy, opts) :: result(map())
  def pr_merge(repo, pr_number, strategy, opts \\ [])
      when strategy in [:merge, :squash, :rebase] do
    payload = %{"merge_method" => Atom.to_string(strategy)}

    request(
      :put,
      "/repos/#{repo}/pulls/#{pr_number}/merge",
      [json: payload],
      opts
    )
    |> handle_json()
  end

  @doc """
  Return the most recent rate-limit state observed from any GitHub response,
  or `nil` if none has been seen yet in this VM. Map has shape:

      %{remaining: integer, limit: integer | nil, reset_at: DateTime.t() | nil}
  """
  @spec rate_limit() :: map() | nil
  def rate_limit do
    :persistent_term.get(@rate_limit_key, nil)
  end

  # ---- Internals -----------------------------------------------------------

  defp fetch_commit_id(repo, pr_number, opts) do
    case Keyword.get(opts, :commit_id) do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _ ->
        case pr_get(repo, pr_number, opts) do
          {:ok, %{"head" => %{"sha" => sha}}} when is_binary(sha) ->
            {:ok, sha}

          {:ok, _} ->
            {:error,
             %Error{
               kind: :validation_failed,
               status: 200,
               message: "PR payload missing head.sha",
               raw: nil
             }}

          {:error, _} = err ->
            err
        end
    end
  end

  defp request(method, path, req_opts, opts) do
    base = Keyword.get(opts, :base_url, @default_base_url)
    url = base <> path
    token = fetch_token!(opts)

    full_opts =
      [
        method: method,
        url: url,
        headers: github_headers(token),
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(req_opts)
      |> Keyword.merge(stub_opts(opts))

    Req.request(full_opts)
  end

  defp graphql_request(payload, opts) do
    base = Keyword.get(opts, :base_url, @default_base_url)
    url = base <> "/graphql"
    token = fetch_token!(opts)

    full_opts =
      [
        method: :post,
        url: url,
        headers: github_headers(token),
        json: payload,
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(stub_opts(opts))

    case Req.request(full_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}}
      when status in 200..299 ->
        update_rate_limit(headers)
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        update_rate_limit(headers)
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  defp handle_json({:ok, %Req.Response{status: status, body: body, headers: headers}})
       when status in 200..299 do
    update_rate_limit(headers)
    {:ok, body}
  end

  defp handle_json({:ok, %Req.Response{status: status, body: body, headers: headers}}) do
    update_rate_limit(headers)
    {:error, http_error(status, body)}
  end

  defp handle_json({:error, exception}) do
    {:error, transport_error(exception)}
  end

  defp http_error(status, body) do
    %Error{
      kind: kind_for_status(status),
      status: status,
      message: error_message(body, status),
      raw: body
    }
  end

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

  defp github_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "gt-elixir"}
    ]
  end

  defp fetch_token!(opts) do
    case Keyword.get(opts, :token) || System.get_env("GITHUB_TOKEN") do
      token when is_binary(token) and token != "" ->
        token

      _ ->
        raise ArgumentError,
              "GtElixir.GitHub: no token supplied (set GITHUB_TOKEN env var " <>
                "or pass opts[:token])"
    end
  end

  defp stub_opts(opts) do
    cond do
      Keyword.has_key?(opts, :plug) ->
        [plug: Keyword.fetch!(opts, :plug)]

      Application.get_env(:gt_elixir, :github_http_stub, false) ->
        [plug: {Req.Test, @stub_name}]

      true ->
        []
    end
  end

  defp update_rate_limit(headers) do
    remaining = header(headers, "x-ratelimit-remaining")
    limit = header(headers, "x-ratelimit-limit")
    reset = header(headers, "x-ratelimit-reset")

    if remaining || limit || reset do
      state = %{
        remaining: to_int(remaining),
        limit: to_int(limit),
        reset_at: to_datetime(reset)
      }

      :persistent_term.put(@rate_limit_key, state)
    end

    :ok
  end

  # Req normalises headers to a map of lists in 0.5+; cope with both shapes.
  defp header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [val | _] -> val
      val when is_binary(val) -> val
      _ -> nil
    end
  end

  defp header(headers, name) when is_list(headers) do
    case List.keyfind(headers, name, 0) do
      {_, val} -> val
      _ -> nil
    end
  end

  defp to_int(nil), do: nil

  defp to_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp to_int(val) when is_integer(val), do: val

  defp to_datetime(nil), do: nil

  defp to_datetime(val) when is_binary(val) do
    with {n, _} <- Integer.parse(val),
         {:ok, dt} <- DateTime.from_unix(n) do
      dt
    else
      _ -> nil
    end
  end
end
