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

  The opaque ref minted by `open/4` is one of:

    * `"<owner>/<repo>#<number>"` — when the target repo was derived per-rig
      from the rig's git remote (multi-repo workspaces where `merge.config`
      omits `repo`). The owner/repo are baked into the ref so later
      callbacks (`get/1`, `merge/1`, …) talk to the same repo without
      re-resolving.
    * `"#<number>"` — when the target repo came from workspace config
      (`merge.config.repo`). The legacy single-repo shape; owner/repo are
      re-read from the active workspace cfg on each callback.

  Callers should treat the ref as opaque — the shape is internal.

  ## Per-rig repo derivation

  When `workspace.config["merge"]["config"]` omits `repo` (a multi-rig
  workspace whose rigs live in *different* repos, e.g. the `leotech`
  workspace's four `leo-technologies-llc/*` rigs), `open/4` derives the
  target repo from the rig's `origin` remote via
  `Arbiter.Mergers.Github.RepoResolver` and bakes the result into the
  minted `mr_ref`. The caller passes the rig path through `opts.repo_path`
  (the same key the `Direct` adapter already requires; the Polecat seeds
  it from the rig's worktree).

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

  require Logger

  alias Arbiter.Mergers.Github.{Config, Error, RepoResolver}

  @stub_name Arbiter.Mergers.Github.HTTP

  # ---- Merger behaviour ----------------------------------------------------

  @impl true
  def open(branch, title, description, opts)
      when is_binary(branch) and is_binary(title) and is_map(opts) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, ref_form}} <- resolve_target(cfg, opts) do
      target = Map.get(opts, :target_branch) || cfg.default_target_branch

      payload = %{
        "head" => branch,
        "base" => target,
        "title" => title,
        "body" => description || "",
        "draft" => Map.get(opts, :draft, false)
      }

      case request(cfg, :post, "/repos/#{owner}/#{repo}/pulls", json: payload) do
        {:ok, %Req.Response{status: status, body: %{"number" => number}}}
        when status in 200..299 and is_integer(number) ->
          mr_ref = build_mr_ref(ref_form, owner, repo, number)
          maybe_request_reviewers(cfg, owner, repo, number, reviewers(cfg, opts))
          {:ok, mr_ref}

        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:error,
           %Error{
             kind: :validation_failed,
             status: status,
             message: "PR creation response missing \"number\"",
             raw: body
           }}

        {:ok, %Req.Response{status: 422, body: body}} ->
          # GitHub returns 422 when an open PR already exists for the head
          # branch. Treat open/4 as idempotent: resolve the existing PR
          # instead of failing the retry. Reviewer requests are skipped — the
          # existing PR may already have them, and the merge step is what
          # the caller actually wants on retry.
          if already_exists_error?(body) do
            case find_existing_open_pr_number(cfg, owner, repo, branch) do
              {:ok, number} -> {:ok, build_mr_ref(ref_form, owner, repo, number)}
              :none -> {:error, http_error(422, body)}
              {:error, _} -> {:error, http_error(422, body)}
            end
          else
            {:error, http_error(422, body)}
          end

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
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref),
         {:ok, pr} <-
           request(cfg, :get, "/repos/#{owner}/#{repo}/pulls/#{number}", [])
           |> handle_json(),
         {:ok, reviews} <-
           request(cfg, :get, "/repos/#{owner}/#{repo}/pulls/#{number}/reviews", [])
           |> handle_json() do
      head_sha = get_in(pr, ["head", "sha"])
      pipeline = fetch_pipeline_status(cfg, owner, repo, head_sha)

      {:ok,
       %{
         ref: mr_ref,
         status: pr_status(pr),
         approved: approved?(reviews),
         changes_requested: changes_requested?(reviews),
         latest_review_id: latest_changes_requested_id(reviews),
         pipeline: pipeline,
         ci_clean: Map.get(pr, "mergeStateStatus") == "clean",
         conflicting:
           Map.get(pr, "mergeable") == false or Map.get(pr, "mergeStateStatus") == "dirty",
         url: Map.get(pr, "html_url") || ""
       }}
    end
  end

  @impl true
  def list_review_feedback(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref),
         {:ok, reviews} <-
           request(cfg, :get, "/repos/#{owner}/#{repo}/pulls/#{number}/reviews", [])
           |> handle_json(),
         {:ok, comments} <-
           request(cfg, :get, "/repos/#{owner}/#{repo}/pulls/#{number}/comments", [])
           |> handle_json() do
      reviews = List.wrap(reviews)
      comments = List.wrap(comments)

      {:ok,
       %{
         changes_requested: changes_requested?(reviews),
         latest_review_id: latest_changes_requested_id(reviews),
         feedback: build_feedback(reviews, comments)
       }}
    end
  end

  @impl true
  def merge(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref) do
      payload = %{"merge_method" => Atom.to_string(cfg.merge_method)}

      request(cfg, :put, "/repos/#{owner}/#{repo}/pulls/#{number}/merge", json: payload)
      |> expect_ok()
    end
  end

  @impl true
  def close(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref) do
      payload = %{"state" => "closed"}

      request(cfg, :patch, "/repos/#{owner}/#{repo}/pulls/#{number}", json: payload)
      |> expect_ok()
    end
  end

  @impl true
  def add_comment(mr_ref, body) when is_binary(mr_ref) and is_binary(body) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref) do
      payload = %{"body" => body}

      request(cfg, :post, "/repos/#{owner}/#{repo}/issues/#{number}/comments", json: payload)
      |> expect_ok()
    end
  end

  @impl true
  def request_review(mr_ref, reviewers) when is_binary(mr_ref) and is_list(reviewers) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref) do
      do_request_reviewers(cfg, owner, repo, number, reviewers)
    end
  end

  @impl true
  def get_diff(mr_ref, _opts) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref) do
      request_diff(cfg, "/repos/#{owner}/#{repo}/pulls/#{number}")
    end
  end

  @impl true
  def post_inline_comment(mr_ref, finding, opts)
      when is_binary(mr_ref) and is_map(finding) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref),
         {:ok, commit_id} <- fetch_commit_id(cfg, owner, repo, number, opts) do
      %{severity: sev, file: file, line: line, message: msg} = finding

      payload = %{
        "body" => "**#{severity_label(sev)}**: #{msg}",
        "path" => file,
        "line" => line,
        "commit_id" => commit_id,
        "side" => "RIGHT"
      }

      request(cfg, :post, "/repos/#{owner}/#{repo}/pulls/#{number}/comments", json: payload)
      |> handle_json()
    end
  end

  @impl true
  def submit_review(mr_ref, verdict, body, _opts)
      when is_binary(mr_ref) and verdict in [:approve, :request_changes] do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref) do
      payload = %{
        "event" => verdict_event(verdict),
        "body" => body || ""
      }

      case request(cfg, :post, "/repos/#{owner}/#{repo}/pulls/#{number}/reviews", json: payload) do
        {:ok, %Req.Response{status: 422, body: err_body}} when is_map(err_body) ->
          if self_review_error?(err_body) do
            Logger.warning(
              "GitHub self-review: #{verdict} rejected (#{inspect(err_body["message"])}); " <>
                "falling back to issue comment for #{owner}/#{repo}##{number}"
            )

            fallback_self_review_comment(cfg, owner, repo, number, verdict, body)
          else
            {:error, http_error(422, err_body)}
          end

        other ->
          handle_json(other)
      end
    end
  end

  @impl true
  def link_for(mr_ref) when is_binary(mr_ref) do
    case parse_mr_ref(mr_ref) do
      {:embedded, owner, repo, number} ->
        "https://github.com/#{owner}/#{repo}/pull/#{number}"

      {:bare, number} ->
        case Config.active_repo_slug() do
          slug when is_binary(slug) -> "https://github.com/#{slug}/pull/#{number}"
          nil -> "https://github.com/owner/repo/pull/#{number}"
        end

      :invalid ->
        "https://github.com/owner/repo/pull/#{String.trim_leading(mr_ref, "#")}"
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
  defp maybe_request_reviewers(_cfg, _owner, _repo, _number, []), do: :ok

  defp maybe_request_reviewers(cfg, owner, repo, number, reviewers) do
    _ = do_request_reviewers(cfg, owner, repo, number, reviewers)
    :ok
  end

  defp do_request_reviewers(_cfg, _owner, _repo, _number, []), do: :ok

  defp do_request_reviewers(cfg, owner, repo, number, reviewers) do
    payload = %{"reviewers" => reviewers}

    request(
      cfg,
      :post,
      "/repos/#{owner}/#{repo}/pulls/#{number}/requested_reviewers",
      json: payload
    )
    |> expect_ok()
  end

  # ---- Internals: idempotent open ------------------------------------------

  # GitHub's 422 "already exists" payload looks like:
  #   %{"message" => "Validation Failed",
  #     "errors" => [%{"code" => "custom",
  #                    "message" => "A pull request already exists for owner:branch."}]}
  defp already_exists_error?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, fn
      %{"message" => msg} when is_binary(msg) -> String.contains?(msg, "already exists")
      _ -> false
    end)
  end

  defp already_exists_error?(_), do: false

  defp find_existing_open_pr_number(cfg, owner, repo, branch) do
    head = "#{owner}:#{branch}"

    case request(cfg, :get, "/repos/#{owner}/#{repo}/pulls", params: [head: head, state: "open"]) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case body do
          [%{"number" => number} | _] when is_integer(number) -> {:ok, number}
          _ -> :none
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # ---- Internals: response interpretation ----------------------------------

  # GitHub PR JSON: "state" is "open" | "closed"; "merged" (bool) and
  # "merged_at" distinguish a merged-closed PR from a plain-closed one.
  defp pr_status(%{"merged" => true}), do: :merged
  defp pr_status(%{"merged_at" => at}) when is_binary(at), do: :merged
  defp pr_status(%{"state" => "closed"}), do: :closed
  defp pr_status(_), do: :open

  # Approved when the *latest* verdict per reviewer settles on APPROVED with no
  # outstanding CHANGES_REQUESTED. Using the latest-per-reviewer state (rather
  # than "any APPROVED ever") is what lets a re-review APPROVE clear an earlier
  # CHANGES_REQUESTED that still lives in the PR's review history — the
  # post-revise re-approval the MergeQueue relies on (bd-95lsjb).
  defp approved?(reviews) when is_list(reviews) do
    states = latest_review_states(reviews)
    "APPROVED" in states and "CHANGES_REQUESTED" not in states
  end

  defp approved?(_), do: false

  # True when the latest verdict from any reviewer is CHANGES_REQUESTED — the
  # signal the MergeQueue turns into an auto-revise pass.
  defp changes_requested?(reviews) when is_list(reviews) do
    "CHANGES_REQUESTED" in latest_review_states(reviews)
  end

  defp changes_requested?(_), do: false

  # The verdict state of each reviewer's most recent verdict review. GitHub
  # returns reviews in chronological order, so the last entry per author is the
  # current one. Non-verdict reviews (COMMENTED, PENDING) don't change approval
  # state and are dropped; DISMISSED is retained so a dismissed verdict can
  # supersede an earlier APPROVED/CHANGES_REQUESTED (and is then itself ignored
  # by the approve/changes checks above).
  defp latest_review_states(reviews) do
    reviews
    |> Enum.filter(&(Map.get(&1, "state") in ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]))
    |> Enum.group_by(&review_author/1)
    |> Enum.map(fn {_author, group} -> group |> List.last() |> Map.get("state") end)
  end

  defp review_author(review), do: get_in(review, ["user", "login"])

  # An opaque debounce handle for the most recent CHANGES_REQUESTED review:
  # its numeric id when present, else its submitted_at timestamp. nil when no
  # CHANGES_REQUESTED review exists.
  defp latest_changes_requested_id(reviews) when is_list(reviews) do
    reviews
    |> Enum.filter(&(Map.get(&1, "state") == "CHANGES_REQUESTED"))
    |> List.last()
    |> case do
      nil -> nil
      review -> Map.get(review, "id") || Map.get(review, "submitted_at")
    end
  end

  defp latest_changes_requested_id(_), do: nil

  # Assemble the feedback list the revise worker is briefed with: every review
  # that carries a non-blank summary body, plus every inline review comment.
  defp build_feedback(reviews, comments) do
    review_items =
      reviews
      |> Enum.filter(fn r -> present_body?(Map.get(r, "body")) end)
      |> Enum.map(fn r ->
        %{
          kind: :review,
          author: review_author(r),
          state: Map.get(r, "state"),
          body: Map.get(r, "body")
        }
      end)

    comment_items =
      comments
      |> Enum.filter(fn c -> present_body?(Map.get(c, "body")) end)
      |> Enum.map(fn c ->
        %{
          kind: :comment,
          author: get_in(c, ["user", "login"]),
          path: Map.get(c, "path"),
          line: Map.get(c, "line") || Map.get(c, "original_line"),
          body: Map.get(c, "body")
        }
      end)

    review_items ++ comment_items
  end

  defp present_body?(body) when is_binary(body), do: String.trim(body) != ""
  defp present_body?(_), do: false

  # Fetch CI status via the check-runs API for the head commit SHA.
  # Returns nil when the SHA is absent or no check-runs exist (no CI configured)
  # or the request fails (best-effort — a transient API error must not block the
  # MR poll).
  defp fetch_pipeline_status(_cfg, _owner, _repo, nil), do: nil
  defp fetch_pipeline_status(_cfg, _owner, _repo, ""), do: nil

  defp fetch_pipeline_status(cfg, owner, repo, sha) do
    case request(cfg, :get, "/repos/#{owner}/#{repo}/commits/#{sha}/check-runs", [])
         |> handle_json() do
      {:ok, %{"check_runs" => [_ | _] = runs}} ->
        map_check_run_status(runs)

      _ ->
        nil
    end
  end

  defp map_check_run_status(runs) do
    conclusions = Enum.map(runs, &Map.get(&1, "conclusion"))
    statuses = Enum.map(runs, &Map.get(&1, "status"))

    cond do
      Enum.any?(conclusions, &(&1 in ["failure", "timed_out", "action_required", "cancelled"])) ->
        :failed

      Enum.all?(statuses, &(&1 == "completed")) and
          Enum.all?(conclusions, &(&1 == "success")) ->
        :success

      Enum.any?(statuses, &(&1 in ["in_progress", "queued", "waiting", "requested", "pending"])) ->
        :running

      true ->
        :pending
    end
  end

  # ---- Internals: target / ref resolution ----------------------------------

  # Resolve the {owner, repo, ref_form} target for a fresh open/4. ref_form
  # determines whether the minted mr_ref will embed owner/repo (per-rig
  # derivation) or just carry the PR number (single-repo workspace).
  defp resolve_target(cfg, opts) do
    cond do
      is_binary(cfg.repo) ->
        {:ok, {cfg.owner, cfg.repo, :bare}}

      path = Map.get(opts, :repo_path) ->
        with {:ok, {owner, repo}} <- RepoResolver.from_remote(path) do
          {:ok, {owner, repo, :embedded}}
        end

      true ->
        {:error,
         %Error{
           kind: :config_missing,
           status: nil,
           message:
             "GitHub merger config missing \"repo\" and no :repo_path in opts to derive it from. " <>
               "Set workspace.config[\"merge\"][\"config\"][\"repo\"] for single-repo workspaces, " <>
               "or pass :repo_path so the adapter can derive owner/repo from the rig's git remote.",
           raw: nil
         }}
    end
  end

  # Resolve {owner, repo, number} for a callback that takes an existing mr_ref.
  # An embedded mr_ref ("<owner>/<repo>#<n>") is self-describing; a bare
  # ("#<n>") falls back to the active workspace cfg's owner/repo.
  defp resolve_ref(cfg, mr_ref) do
    case parse_mr_ref(mr_ref) do
      {:embedded, owner, repo, number} ->
        {:ok, {owner, repo, number}}

      {:bare, number} ->
        case cfg.repo do
          repo when is_binary(repo) ->
            {:ok, {cfg.owner, repo, number}}

          _ ->
            {:error,
             %Error{
               kind: :config_missing,
               status: nil,
               message:
                 "mr_ref #{inspect(mr_ref)} omits owner/repo and workspace cfg has no \"repo\"",
               raw: nil
             }}
        end

      :invalid ->
        {:error, %Error{kind: :validation_failed, message: "invalid mr_ref: #{inspect(mr_ref)}"}}
    end
  end

  defp build_mr_ref(:bare, _owner, _repo, number), do: "#" <> Integer.to_string(number)

  defp build_mr_ref(:embedded, owner, repo, number),
    do: "#{owner}/#{repo}##{number}"

  defp parse_mr_ref(mr_ref) do
    case String.split(mr_ref, "#", parts: 2) do
      ["", num_str] ->
        case parse_pos_int(num_str) do
          {:ok, n} -> {:bare, n}
          :error -> :invalid
        end

      [slug, num_str] when slug != "" ->
        with [owner, repo] when owner != "" and repo != "" <- String.split(slug, "/", parts: 2),
             {:ok, n} <- parse_pos_int(num_str) do
          {:embedded, owner, repo, n}
        else
          _ -> :invalid
        end

      [num_str] ->
        # Bare integer string — backward compat with old MergeQueue pr_ref storage ("42").
        case parse_pos_int(num_str) do
          {:ok, n} -> {:bare, n}
          :error -> :invalid
        end
    end
  end

  defp parse_pos_int(str) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  # ---- Internals: review helpers -------------------------------------------

  defp severity_label(:info), do: "INFO"
  defp severity_label(:warning), do: "WARNING"
  defp severity_label(:error), do: "ERROR"
  defp severity_label(other), do: other |> to_string() |> String.upcase()

  defp verdict_event(:approve), do: "APPROVE"
  defp verdict_event(:request_changes), do: "REQUEST_CHANGES"

  # GitHub returns HTTP 422 with "Can not approve your own pull request." or
  # "You can not request changes on your own pull request." when reviewer and
  # PR author share the same identity. Both contain "your own pull request".
  defp self_review_error?(%{"message" => msg}) when is_binary(msg) do
    msg |> String.downcase() |> String.contains?("your own pull request")
  end

  defp self_review_error?(_), do: false

  # Post the verdict as a top-level issue comment when a formal review
  # submission is rejected because the reviewer is the PR author. The fleet
  # merge gate uses the internal polecat verdict, not GitHub's review state,
  # so this comment is for human visibility only.
  defp fallback_self_review_comment(cfg, owner, repo, number, verdict, body) do
    verdict_label = if verdict == :approve, do: "APPROVE", else: "REQUEST_CHANGES"
    text = "VERDICT: #{verdict_label}\n\n#{body || ""}" |> String.trim()
    payload = %{"body" => text}

    case request(cfg, :post, "/repos/#{owner}/#{repo}/issues/#{number}/comments", json: payload) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status, body: err_body}} ->
        {:error, http_error(status, err_body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # Inline review comments require the head SHA of the PR (GitHub's API
  # anchors the comment to a specific commit). Callers can short-circuit
  # the lookup by passing `:commit_id` in opts.
  defp fetch_commit_id(_cfg, _owner, _repo, _number, %{commit_id: id})
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp fetch_commit_id(cfg, owner, repo, number, _opts) do
    case request(cfg, :get, "/repos/#{owner}/#{repo}/pulls/#{number}", []) |> handle_json() do
      {:ok, %{"head" => %{"sha" => sha}}} when is_binary(sha) and sha != "" ->
        {:ok, sha}

      {:ok, _} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: nil,
           message: "PR payload missing head.sha",
           raw: nil
         }}

      {:error, _} = err ->
        err
    end
  end

  # GitHub returns the raw unified diff when Accept negotiates for it. We
  # piggy-back on the existing `request/4` plumbing but swap headers so the
  # response body is a string, not JSON. Stub plugs see the same path; tests
  # can stub-text-body the response.
  defp request_diff(cfg, path) do
    url = cfg.base_url <> path

    diff_headers = [
      {"authorization", "Bearer " <> cfg.token},
      {"accept", "application/vnd.github.v3.diff"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "arbiter"}
    ]

    full_opts =
      [
        method: :get,
        url: url,
        headers: diff_headers,
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(stub_opts())

    case Req.request(full_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, to_string(body)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
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
