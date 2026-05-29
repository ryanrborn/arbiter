defmodule Arbiter.Mergers.Github do
  @moduledoc """
  GitHub adapter implementing `Arbiter.Mergers.Merger`.

  Wraps GitHub's REST API v3 for pull-request open / get / merge / close /
  comment / request-review flows. This is the hosted-forge merge path for
  GitHub-hosted warships (and for Arbiter's own repo).

  ## Active-workspace contract

  The `Merger` behaviour callbacks take an opaque `mr_ref` with no workspace
  context. But GitHub needs an owner, repo, token, and default settings — all
  workspace-scoped. We resolve those through `Arbiter.Mergers.Github.Config`,
  exactly as `Arbiter.Trackers.Jira` does for the tracker side:

    1. Callers (request middleware, CLI command, scheduler job) call
       `Config.put_active(workspace)` to populate the per-process config.
    2. `Application.get_env(:arbiter, :github_merger_default_config)` is the
       fallback for tools that run without a workspace context.
    3. With neither, callbacks return `{:error, %Error{kind: :config_missing}}`.

  ## `mr_ref`

  The opaque ref minted by `open/4` is the PR number prefixed with `#`, e.g.
  `"#42"`. Owner / repo / token come from the resolved workspace config — the
  ref carries only the PR-local datum, mirroring how the Jira tracker's ref is
  just the issue key with host / project resolved from config.

  ## Config selection

  The `Arbiter.Mergers` dispatcher resolves this adapter when a workspace's
  `config["merge"]["strategy"]` is `"github"`. The adapter's own settings live
  under `config["merge"]["config"]` — see `Arbiter.Mergers.Github.Config`.

  ## Auth

  GitHub uses **Bearer** auth. The credentials reference lives in the merger
  config; `credentials_ref` is a small DSL — currently only `"env:NAME"` is
  supported (looks up `System.get_env/1`); a bare string is treated as a
  literal token.

  ## Tests

  Wired up to `Req.Test`: when
  `Application.get_env(:arbiter, :github_http_stub, false)` is true, every
  request injects `plug: {Req.Test, #{inspect(Arbiter.Mergers.Github.HTTP)}}`.
  This adapter **never** hits a real GitHub endpoint from tests.
  """

  @behaviour Arbiter.Mergers.Merger

  alias Arbiter.Mergers.Github.{Config, Error}

  @stub_name Arbiter.Mergers.Github.HTTP

  # ---- Merger behaviour ----------------------------------------------------

  @impl true
  def open(branch, title, description, opts)
      when is_binary(branch) and is_binary(title) and is_map(opts) do
    with {:ok, cfg} <- Config.resolve() do
      target = Map.get(opts, :target_branch) || cfg.default_target_branch

      payload = %{
        "head" => branch,
        "base" => target,
        "title" => title,
        "body" => description || "",
        "draft" => Map.get(opts, :draft, false)
      }

      case request(cfg, :post, "/repos/#{cfg.owner}/#{cfg.repo}/pulls", json: payload) do
        {:ok, %Req.Response{status: status, body: %{"number" => number}}}
        when status in 200..299 and is_integer(number) ->
          mr_ref = "#" <> Integer.to_string(number)
          maybe_request_reviewers(cfg, number, reviewers(cfg, opts))
          {:ok, mr_ref}

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: status,
             message: "PR creation response missing \"number\"",
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
         {:ok, number} <- parse_number(mr_ref),
         {:ok, pr} <-
           request(cfg, :get, "/repos/#{cfg.owner}/#{cfg.repo}/pulls/#{number}", [])
           |> handle_json(),
         {:ok, reviews} <-
           request(cfg, :get, "/repos/#{cfg.owner}/#{cfg.repo}/pulls/#{number}/reviews", [])
           |> handle_json() do
      {:ok,
       %{
         ref: mr_ref,
         status: pr_status(pr),
         approved: approved?(reviews),
         url: Map.get(pr, "html_url") || ""
       }}
    end
  end

  @impl true
  def merge(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, number} <- parse_number(mr_ref) do
      payload = %{"merge_method" => Atom.to_string(cfg.merge_method)}

      request(cfg, :put, "/repos/#{cfg.owner}/#{cfg.repo}/pulls/#{number}/merge", json: payload)
      |> expect_ok()
    end
  end

  @impl true
  def close(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, number} <- parse_number(mr_ref) do
      payload = %{"state" => "closed"}

      request(cfg, :patch, "/repos/#{cfg.owner}/#{cfg.repo}/pulls/#{number}", json: payload)
      |> expect_ok()
    end
  end

  @impl true
  def add_comment(mr_ref, body) when is_binary(mr_ref) and is_binary(body) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, number} <- parse_number(mr_ref) do
      payload = %{"body" => body}

      request(cfg, :post, "/repos/#{cfg.owner}/#{cfg.repo}/issues/#{number}/comments",
        json: payload
      )
      |> expect_ok()
    end
  end

  @impl true
  def request_review(mr_ref, reviewers) when is_binary(mr_ref) and is_list(reviewers) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, number} <- parse_number(mr_ref) do
      do_request_reviewers(cfg, number, reviewers)
    end
  end

  @impl true
  def link_for(mr_ref) when is_binary(mr_ref) do
    number = String.trim_leading(mr_ref, "#")

    case Config.active_repo_slug() do
      slug when is_binary(slug) -> "https://github.com/#{slug}/pull/#{number}"
      nil -> "https://github.com/owner/repo/pull/#{number}"
    end
  end

  # ---- Public helpers ------------------------------------------------------

  @doc """
  Convenience: set the active workspace for the current process and run
  `fun`, restoring the previous config when `fun` returns. Useful in tests and
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

  # ---- Internals: reviewers ------------------------------------------------

  defp reviewers(cfg, opts) do
    case Map.get(opts, :reviewer_ids) do
      list when is_list(list) -> list
      _ -> cfg.default_reviewers
    end
  end

  # On open, requesting reviewers is best-effort: the PR already exists, so a
  # failed reviewer request must not orphan it by surfacing as an open/4 error.
  defp maybe_request_reviewers(_cfg, _number, []), do: :ok

  defp maybe_request_reviewers(cfg, number, reviewers) do
    _ = do_request_reviewers(cfg, number, reviewers)
    :ok
  end

  defp do_request_reviewers(_cfg, _number, []), do: :ok

  defp do_request_reviewers(cfg, number, reviewers) do
    payload = %{"reviewers" => reviewers}

    request(
      cfg,
      :post,
      "/repos/#{cfg.owner}/#{cfg.repo}/pulls/#{number}/requested_reviewers",
      json: payload
    )
    |> expect_ok()
  end

  # ---- Internals: response interpretation ----------------------------------

  # GitHub PR JSON: "state" is "open" | "closed"; "merged" (bool) and
  # "merged_at" distinguish a merged-closed PR from a plain-closed one.
  defp pr_status(%{"merged" => true}), do: :merged
  defp pr_status(%{"merged_at" => at}) when is_binary(at), do: :merged
  defp pr_status(%{"state" => "closed"}), do: :closed
  defp pr_status(_), do: :open

  # approved when at least one APPROVED review exists and none are
  # CHANGES_REQUESTED (per the bead's contract).
  defp approved?(reviews) when is_list(reviews) do
    states = Enum.map(reviews, &Map.get(&1, "state"))
    "APPROVED" in states and "CHANGES_REQUESTED" not in states
  end

  defp approved?(_), do: false

  defp parse_number(mr_ref) do
    case Integer.parse(String.trim_leading(mr_ref, "#")) do
      {n, ""} when n > 0 ->
        {:ok, n}

      _ ->
        {:error, %Error{kind: :validation_failed, message: "invalid mr_ref: #{inspect(mr_ref)}"}}
    end
  end

  # ---- Internals: HTTP -----------------------------------------------------

  defp request(cfg, method, path, req_opts) do
    url = cfg.base_url <> path

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

  # For callbacks that only care about success vs failure (merge/close/comment).
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
  defp kind_for_status(405), do: :not_mergeable
  defp kind_for_status(409), do: :conflict
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
