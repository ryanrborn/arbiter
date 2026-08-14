defmodule Arbiter.Mergers.Github do
  @moduledoc """
  GitHub adapter implementing `Arbiter.Mergers.Merger`.

  Wraps GitHub's REST API v3 for pull-request open / get / merge / close /
  comment / request-review flows. This is the hosted-forge merge path for
  GitHub-hosted rigs (and for Arbiter's own repo).

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

    * `"<owner>/<repo>#<number>"` — when the target repo was derived per-repo
      from the repo's git remote (multi-repo workspaces where `merge.config`
      omits `repo`). The owner/repo are baked into the ref so later
      callbacks (`get/1`, `merge/1`, …) talk to the same repo without
      re-resolving.
    * `"#<number>"` — when the target repo came from workspace config
      (`merge.config.repo`). The legacy single-repo shape; owner/repo are
      re-read from the active workspace cfg on each callback.

  Callers should treat the ref as opaque — the shape is internal.

  ## Per-repo repo derivation

  When `workspace.config["merge"]["config"]` omits `repo` (a multi-repo
  workspace whose repos live in *different* repos, e.g. the `leotech`
  workspace's four `leo-technologies-llc/*` repos), `open/4` derives the
  target repo from the repo's `origin` remote via
  `Arbiter.Mergers.Github.RepoResolver` and bakes the result into the
  minted `mr_ref`. The caller passes the repo path through `opts.repo_path`
  (the same key the `Direct` adapter already requires; the worker seeds
  it from the repo's worktree).

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

  alias Arbiter.GitHub.Limiter
  alias Arbiter.Mergers.{Merger, Github.Config, Github.Error, Github.RepoResolver}

  @stub_name Arbiter.Mergers.Github.HTTP

  # Check-run conclusions that count as a CI failure (shared by the pipeline
  # classifier and the `:ci_failed` log fetch).
  @failing_conclusions ["failure", "timed_out", "action_required", "cancelled"]

  # How much of each failing check's output to keep in the fix-pass briefing.
  @log_tail_limit 4_000

  # GraphQL query for a PR's review threads with their full comment history.
  # REST has no `isResolved` field, so unresolved-thread detection (bd-823q7e)
  # goes through GraphQL. `databaseId` is the integer comment id used as a
  # high-watermark cursor (find replies newer than `last_seen_comment_id`).
  # `first: 100` on both threads and comments covers all but pathological PRs;
  # we don't paginate (PRPatrol's follow-up worker re-reads as needed).
  @review_threads_query """
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            path
            line
            comments(first: 100) {
              nodes {
                databaseId
                body
                author { login }
              }
            }
          }
        }
      }
    }
  }
  """

  # GraphQL mutation to close a review thread (bd-76ydsu) — the author-side
  # follow-up worker's counterpart to reply_to_review_comment/4, used after a
  # bot/Copilot thread has been addressed and replied to.
  @resolve_review_thread_mutation """
  mutation($id: ID!) {
    resolveReviewThread(input: {threadId: $id}) {
      thread { id isResolved }
    }
  }
  """

  # GraphQL query for the PR head commit's status-check rollup, used by
  # `list_required_check_failures/1` (bd-ayetel) to tell a required check
  # apart from an optional/informational one. REST's check-runs API (used by
  # `failing_check_logs/1`) has no notion of "required for merge" — that only
  # exists via GraphQL's `isRequired` field on each rollup context, which
  # works for both a `CheckRun` (Actions / most CI) and a legacy
  # `StatusContext` (external CI posting via the Statuses API). `isRequired`
  # takes the PR number so GitHub can resolve it against that PR's branch
  # protection rule.
  @required_checks_query """
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                contexts(first: 100) {
                  nodes {
                    __typename
                    ... on CheckRun {
                      name
                      status
                      conclusion
                      detailsUrl
                      isRequired(pullRequestNumber: $number)
                    }
                    ... on StatusContext {
                      context
                      state
                      targetUrl
                      description
                      isRequired(pullRequestNumber: $number)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  """

  # `CheckRun.conclusion` values (GraphQL enum, upper snake case) that count as
  # a settled failure — the GraphQL-side counterpart to `@failing_conclusions`.
  @failing_check_run_conclusions ["FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "CANCELLED"]

  # `StatusContext.state` values that count as a settled failure. Legacy
  # commit statuses have no separate "still running" status field — PENDING
  # already means "not settled" and is excluded by omission.
  @failing_status_context_states ["FAILURE", "ERROR"]

  # ---- Merger behaviour ----------------------------------------------------

  @impl true
  def open(branch, title, description, opts)
      when is_binary(branch) and is_binary(title) and is_map(opts) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, ref_form}} <- resolve_target(cfg, opts) do
      # Look-before-create (bd-8rrn9t): a re-entry into open/4 for a branch
      # that already has an open PR — e.g. a worker opened the PR itself
      # earlier in its run, or finalize is re-run after a restart — should
      # adopt that PR rather than race a create against it. The 422
      # "already exists" handling below stays as a fallback for the case
      # where the PR is created concurrently between this lookup and the
      # POST (or the lookup itself fails).
      case find_existing_open_pr_number(cfg, owner, repo, branch) do
        {:ok, number} ->
          {:ok, build_mr_ref(ref_form, owner, repo, number)}

        _ ->
          create_pr(cfg, owner, repo, ref_form, branch, title, description, opts)
      end
    end
  end

  defp create_pr(cfg, owner, repo, ref_form, branch, title, description, opts) do
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
        # branch — the look-before-create GET above raced the PR's creation
        # (or itself failed). Treat open/4 as idempotent: resolve the
        # existing PR instead of failing the retry. Reviewer requests are
        # skipped — the existing PR may already have them, and the merge
        # step is what the caller actually wants on retry.
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
      status = pr_status(pr)
      approved = approved?(reviews)
      changes_requested = changes_requested?(reviews)

      {:ok,
       %{
         ref: mr_ref,
         status: status,
         # PR head commit SHA — ReviewPatrol records this into an engagement's
         # `last_reviewed_sha` so it can detect new commits on later ticks.
         head_sha: head_sha,
         # The PR's target branch — used to build a local `git diff
         # base_ref..HEAD` against a Tier-2 checkout worktree, sidestepping
         # GitHub's REST diff endpoint 20k-line cap (bd-5yp6yn).
         base_ref: get_in(pr, ["base", "ref"]),
         # The PR author's login — ReviewPatrol uses this to tell an author's
         # reply on a review thread apart from another reviewer's comment
         # (phase-2 author-reply handling, bd-8fg64x).
         author: get_in(pr, ["user", "login"]),
         # PR title/body — folded into the reviewer prompt (bd-adpwl0) so the
         # reviewer sees the author's own account of the change's intent.
         title: Map.get(pr, "title"),
         body: Map.get(pr, "body"),
         approved: approved,
         changes_requested: changes_requested,
         latest_review_id: latest_changes_requested_id(reviews),
         pipeline: pipeline,
         ci_clean: Map.get(pr, "mergeStateStatus") == "clean",
         conflicting:
           Map.get(pr, "mergeable") == false or Map.get(pr, "mergeStateStatus") == "dirty",
         block_reason: block_reason(cfg, pr, status, pipeline, approved, changes_requested),
         url: Map.get(pr, "html_url") || ""
       }}
    end
  end

  @doc """
  Whether the authenticated token's own identity already has a *current*
  APPROVED verdict on the PR — i.e. the login this adapter posts reviews under
  has approved it. Used by the external-review dispatch guard (bd-7z5pi5) to
  avoid double-posting an approval under our own identity.

  Returns `{:ok, boolean()}` or `{:error, term()}`. When the token's own login
  can't be resolved (a GitHub App token with no user, a `/user` failure), returns
  `{:ok, false}` — we can't attribute an approval to ourselves, so we don't block.

  Not part of the `Merger` behaviour: an optional capability the guard probes
  via `function_exported?/3`, so an adapter without it (e.g. GitLab) fails open.
  """
  @spec self_approved?(String.t()) :: {:ok, boolean()} | {:error, term()}
  def self_approved?(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref),
         {:ok, reviews} <-
           request(cfg, :get, "/repos/#{owner}/#{repo}/pulls/#{number}/reviews", [])
           |> handle_json() do
      case authenticated_login(cfg) do
        login when is_binary(login) and login != "" ->
          {:ok, latest_state_for(reviews, login) == "APPROVED"}

        _ ->
          {:ok, false}
      end
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
  def update_branch(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref) do
      # GitHub's update-branch merges the base into the PR head (202 Accepted,
      # async). A 422 here means the update can't be performed cleanly (e.g. the
      # base advanced in a way that conflicts); the queue treats that as
      # non-fatal and lets the next `get/1` poll surface the conflict.
      request(cfg, :put, "/repos/#{owner}/#{repo}/pulls/#{number}/update-branch", json: %{})
      |> expect_ok()
    end
  end

  @impl true
  def failing_check_logs(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref),
         {:ok, pr} <-
           request(cfg, :get, "/repos/#{owner}/#{repo}/pulls/#{number}", []) |> handle_json() do
      fetch_failing_checks(cfg, owner, repo, get_in(pr, ["head", "sha"]))
    end
  end

  @impl true
  def list_required_check_failures(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref),
         {:ok, body} <- graphql_required_checks(cfg, owner, repo, number) do
      contexts =
        body
        |> get_in(["data", "repository", "pullRequest", "commits", "nodes"])
        |> List.wrap()
        |> List.first()
        |> case do
          %{"commit" => %{"statusCheckRollup" => %{"contexts" => %{"nodes" => nodes}}}}
          when is_list(nodes) ->
            nodes

          _ ->
            []
        end

      {:ok,
       contexts
       |> Enum.reject(&is_nil/1)
       |> Enum.filter(&required_settled_failure?/1)
       |> Enum.map(&summarize_required_check/1)}
    end
  end

  # Batch all three PRPatrol trigger signals for many PRs (across many repos)
  # into ONE aliased GraphQL request (bd-3byp1n), replacing the ~3 per-PR calls
  # (`list_review_feedback/1` + `list_open_review_threads/1` +
  # `list_required_check_failures/1`). The per-PR decomposition reuses the exact
  # same extractors as those callbacks — `changes_requested?/1`,
  # `normalize_review_thread/1`, `required_settled_failure?/1`,
  # `summarize_required_check/1` — so trigger semantics are bit-for-bit
  # identical; only the transport changes.
  #
  # One credential per batch: `Config.resolve/0` yields a single token for the
  # calling process (workspace-scoped, NOT per-repo), so every repo aliased into
  # one query is read with that one token and bills one GraphQL points pool.
  # There is no per-repo credential to diverge, so nothing to split — a PRPatrol
  # tick, which is per-repo anyway, always batches one repo under one token.
  @impl true
  def batch_pr_signals(refs) when is_list(refs) do
    with {:ok, cfg} <- Config.resolve() do
      case batch_entries(cfg, refs) do
        [] ->
          # Nothing resolvable (empty input, or every ref unparseable) — no
          # request, empty map. The caller falls back per-PR for any ref it
          # passed that isn't in the result.
          {:ok, %{}}

        entries ->
          {query, variables} = build_batch_query(entries)

          case graphql_batch(cfg, query, variables) do
            {:ok, data} -> {:ok, extract_batch(entries, data)}
            {:error, _} = err -> err
          end
      end
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
  def get_diff(mr_ref, opts) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref) do
      case diff_range(opts) do
        {base, head} ->
          # A bounded diff since a prior SHA — ReviewPatrol's "new-diff-only"
          # re-review (bd-f3fg22) diffs the commits pushed SINCE `last_reviewed_sha`
          # rather than the whole PR. GitHub's compare endpoint returns exactly
          # `base..head` in the same unified-diff media type as the PR diff.
          request_diff(cfg, "/repos/#{owner}/#{repo}/compare/#{base}...#{head}")

        nil ->
          request_diff(cfg, "/repos/#{owner}/#{repo}/pulls/#{number}")
      end
    end
  end

  # Extract a `{base, head}` compare range from the caller's opts, or nil to fall
  # back to the whole-PR diff. Both endpoints must be non-empty binaries; a
  # missing/blank head or base means "no bounded range requested". Keys are read
  # both as atoms (the ReviewPatrol call site) and strings (defensive).
  defp diff_range(opts) when is_map(opts) do
    base = opts[:base] || opts["base"]
    head = opts[:head] || opts["head"]

    if is_binary(base) and base != "" and is_binary(head) and head != "" do
      {base, head}
    else
      nil
    end
  end

  defp diff_range(_opts), do: nil

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

  @impl true
  def list_open do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, owner} <- require_owner_repo(cfg, :owner),
         {:ok, repo} <- require_owner_repo(cfg, :repo),
         {:ok, prs} <-
           request(cfg, :get, "/repos/#{owner}/#{repo}/pulls",
             params: [state: "open", per_page: 100]
           )
           |> handle_json() do
      mrs =
        prs
        |> List.wrap()
        |> Enum.map(fn pr ->
          number = pr["number"]

          %{
            ref: build_mr_ref(:embedded, owner, repo, number),
            number: number,
            title: pr["title"] || "",
            url: pr["html_url"] || "",
            author: get_in(pr, ["user", "login"])
          }
        end)

      {:ok, mrs}
    end
  end

  # The unresolved review threads on a PR. GitHub only exposes per-thread
  # resolution state through GraphQL (`pullRequest.reviewThreads { isResolved }`);
  # the REST `/pulls/:n/comments` surface `list_review_feedback/1` uses has no
  # `isResolved`, so a COMMENTED review's inline comments are invisible there.
  # We keep only the unresolved nodes and normalize each to a `t:review_thread/0`.
  @impl true
  def list_open_review_threads(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref),
         {:ok, body} <- graphql_review_threads(cfg, owner, repo, number) do
      threads =
        body
        |> get_in(["data", "repository", "pullRequest", "reviewThreads", "nodes"])
        |> List.wrap()
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn node -> Map.get(node, "isResolved") == true end)
        |> Enum.map(&normalize_review_thread/1)

      {:ok, threads}
    end
  end

  @impl true
  def reply_to_review_comment(mr_ref, comment_id, body, _opts)
      when is_binary(mr_ref) and is_integer(comment_id) and comment_id > 0 and is_binary(body) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, {owner, repo, number}} <- resolve_ref(cfg, mr_ref) do
      payload = %{"body" => body}

      request(
        cfg,
        :post,
        "/repos/#{owner}/#{repo}/pulls/#{number}/comments/#{comment_id}/replies",
        json: payload
      )
      |> handle_json()
    end
  end

  @impl true
  def resolve_review_thread(mr_ref, thread_id, _opts)
      when is_binary(mr_ref) and is_binary(thread_id) do
    with {:ok, cfg} <- Config.resolve() do
      graphql_resolve_review_thread(cfg, thread_id)
    end
  end

  @impl true
  def ref_for_pr(pr, opts) when is_binary(pr) and is_map(opts) do
    pr = String.trim(pr)

    cond do
      # Full forge URL: https://github[.enterprise.host]/<owner>/<repo>/pull[s]/<n>
      m = Regex.run(~r{//[^/\s]+/([^/\s]+)/([^/\s]+?)(?:\.git)?/pulls?/(\d+)}, pr) ->
        [_, owner, repo, number] = m
        {:ok, build_mr_ref(:embedded, owner, repo, String.to_integer(number))}

      # Slug forms: "<owner>/<repo>#<n>" or "<owner>/<repo>/pull[s]/<n>"
      m = Regex.run(~r{^([^/\s]+)/([^/\s#]+?)(?:\.git)?(?:#|/pulls?/)(\d+)$}, pr) ->
        [_, owner, repo, number] = m
        {:ok, build_mr_ref(:embedded, owner, repo, String.to_integer(number))}

      # Bare number or "#<n>": embed the {owner, repo} derived from the local
      # checkout's origin remote when a :repo_path is given (so the ref talks to
      # that external repo regardless of workspace cfg); otherwise mint a bare
      # ref that falls back to the active workspace cfg's owner/repo.
      m = Regex.run(~r/^#?(\d+)$/, pr) ->
        [_, number] = m
        number = String.to_integer(number)

        case derive_owner_repo(opts) do
          {:ok, {owner, repo}} -> {:ok, build_mr_ref(:embedded, owner, repo, number)}
          :none -> {:ok, build_mr_ref(:bare, nil, nil, number)}
        end

      true ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: nil,
           message:
             "could not parse #{inspect(pr)} as a GitHub PR reference — expected a PR URL, " <>
               "an \"owner/repo#N\" slug, or a number (pass --repo so a bare number can be " <>
               "resolved to owner/repo via the checkout's origin remote)",
           raw: pr
         }}
    end
  end

  # Returns {:ok, value} for a required cfg field (owner or repo), or a
  # :config_missing error when the field is nil (not set in workspace config).
  defp require_owner_repo(cfg, :owner) do
    case cfg.owner do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        {:error,
         %Error{
           kind: :config_missing,
           status: nil,
           message: "GitHub merger config missing \"owner\"",
           raw: nil
         }}
    end
  end

  defp require_owner_repo(cfg, :repo) do
    case cfg.repo do
      v when is_binary(v) and v != "" ->
        {:ok, v}

      _ ->
        {:error,
         %Error{
           kind: :config_missing,
           status: nil,
           message: "GitHub merger config missing \"repo\"",
           raw: nil
         }}
    end
  end

  # Derive {owner, repo} from a local checkout's origin remote, for a bare PR
  # number. Returns :none when no :repo_path was supplied (the caller then mints
  # a bare ref that resolves against the active workspace cfg).
  defp derive_owner_repo(%{repo_path: path}) when is_binary(path) and path != "" do
    case RepoResolver.from_remote(path) do
      {:ok, {_owner, _repo}} = ok -> ok
      {:error, _} -> :none
    end
  end

  defp derive_owner_repo(_opts), do: :none

  # ---- Public helpers ------------------------------------------------------

  @doc """
  Filter `threads` to only the ones where `our_login` participated — either
  by authoring the opening comment or by posting any reply in the thread.
  Used by ReviewPatrol to ignore threads started and carried entirely by other
  reviewers when multiple reviewers are active on the same PR.

  Threads returned by `list_open_review_threads/1` carry a `:comments` list;
  this helper operates on that shape. Threads without a `:comments` key are
  matched solely on `:author`.
  """
  @spec filter_to_our_threads([Merger.review_thread()], String.t()) ::
          [Merger.review_thread()]
  def filter_to_our_threads(threads, our_login)
      when is_list(threads) and is_binary(our_login) do
    Enum.filter(threads, fn thread ->
      thread[:author] == our_login or
        Enum.any?(Map.get(thread, :comments, []), fn c -> c[:author] == our_login end)
    end)
  end

  @doc """
  Convenience: set the active workspace for the current process and run
  `fun`, restoring the previous config when `fun` returns. Useful in tests and
  one-shot scripts. Mirrors `Arbiter.Trackers.Jira.with_workspace/2`.
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

  # Classify *why* an open PR can't merge, or nil when it is mergeable (or
  # already terminal). This is the block-reason surface Phase 1 (#354) escalates
  # on so an approved-but-unmergeable PR never parks silently. Derived from
  # GitHub's merge-state signal plus the resolved CI pipeline and review state:
  #
  #   :conflict                  — mergeable=false / mergeable_state "dirty"
  #   :behind_base               — "behind" (no conflict, just stale vs base)
  #   :ci_failed                 — a required check failed (pipeline :failed)
  #   :needs_approval            — "blocked" by required review, or a dismissed
  #                                approval (a review the fleet can still wait on)
  #   :needs_nonauthor_approval  — "blocked" purely on a required review of a
  #                                fleet-authored PR (the fleet can't self-approve)
  #   :draft                     — PR is a draft
  #   :blocked_other             — blocked by some other forge rule
  defp block_reason(_cfg, _pr, status, _pipeline, _approved, _changes_requested)
       when status in [:merged, :closed],
       do: nil

  defp block_reason(cfg, pr, _status, pipeline, _approved, changes_requested) do
    state = merge_state(pr)
    draft? = Map.get(pr, "draft") == true or state == "draft"

    cond do
      draft? -> :draft
      state == "dirty" or Map.get(pr, "mergeable") == false -> :conflict
      state == "behind" -> :behind_base
      pipeline == :failed -> :ci_failed
      changes_requested -> :needs_approval
      state == "blocked" -> blocked_review_reason(cfg, pr)
      state in ["clean", "has_hooks", "unstable", "unknown", nil] -> nil
      true -> :blocked_other
    end
  end

  # A "blocked" merge state on an otherwise-green PR (no conflict, not behind,
  # CI not failed, no outstanding CHANGES_REQUESTED) means the only thing missing
  # is a required approving review. If that PR was opened by the fleet's *own*
  # identity (the authenticated token's user), the forge's branch protection
  # requires an approval from someone *other than the author* — which the fleet
  # can never supply, because GitHub forbids approving your own pull request. The
  # Watchdog treats `:needs_nonauthor_approval` specially: it parks indefinitely
  # and escalates to a human once, instead of failing at the auto_merge poll ceiling
  # (bd-c3lchp / lt-4kjaoe). When authorship can't be confirmed as the fleet's,
  # fall back to the generic `:needs_approval` (a reviewer may still act).
  defp blocked_review_reason(cfg, pr) do
    if fleet_authored?(cfg, pr), do: :needs_nonauthor_approval, else: :needs_approval
  end

  # True only when the PR's author login matches the authenticated token's own
  # login. Skips the `/user` lookup entirely when the PR carries no author, so
  # the common path (and stubs that don't model `/user`) never make the call.
  defp fleet_authored?(cfg, pr) do
    case get_in(pr, ["user", "login"]) do
      login when is_binary(login) and login != "" -> login == authenticated_login(cfg)
      _ -> false
    end
  end

  # The login of the token's own identity (GET /user). Best-effort: any failure
  # (a GitHub App token with no user, a network error) yields nil so the caller
  # falls back to the generic block reason. Reached only in the narrow
  # blocked-on-review branch, not on every poll.
  defp authenticated_login(cfg) do
    case request(cfg, :get, "/user", []) |> handle_json() do
      {:ok, %{"login" => login}} when is_binary(login) and login != "" -> login
      _ -> nil
    end
  end

  # Normalize GitHub's merge-state signal to a lowercase string. Prefers the REST
  # `mergeable_state`; falls back to the GraphQL `mergeStateStatus` enum
  # (uppercase) some payloads carry. nil when neither is present.
  defp merge_state(pr) do
    case Map.get(pr, "mergeable_state") || Map.get(pr, "mergeStateStatus") do
      s when is_binary(s) and s != "" -> String.downcase(s)
      _ -> nil
    end
  end

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

  # The current (latest) verdict state for a single reviewer login, or nil when
  # that login left no verdict review. Mirrors `latest_review_states/1` but scoped
  # to one author: GitHub returns reviews chronologically, so the last verdict
  # entry for `login` is the current one — a DISMISSED that follows an APPROVED
  # correctly reads as "not currently approved".
  defp latest_state_for(reviews, login) when is_list(reviews) and is_binary(login) do
    reviews
    |> Enum.filter(&(Map.get(&1, "state") in ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]))
    |> Enum.filter(&(review_author(&1) == login))
    |> List.last()
    |> case do
      nil -> nil
      review -> Map.get(review, "state")
    end
  end

  defp latest_state_for(_reviews, _login), do: nil

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
  # Returns nil when the SHA is absent or the request fails (best-effort — a
  # transient API error must not block the MR poll). Returns `:not_started`
  # when the SHA is present and the request succeeded but zero check-runs
  # exist yet (bd-aeb9wv / #1189: PR #1188 merged a full second *before* its
  # check-suite existed). Zero check-runs is genuinely ambiguous from this API
  # alone — it means either "GitHub hasn't created the check-suite yet" (the
  # #1188 race) or "no CI is configured for this repo/commit at all" (no
  # workflow, or every workflow excluded by its `on:` path filters); nothing
  # in this response distinguishes the two. The Watchdog deliberately errs
  # toward waiting on `:not_started` rather than treating it as clear-to-merge,
  # but only for a bounded number of polls — see `@not_started_grace_polls` in
  # watchdog.ex — so a repo with no CI at all still becomes mergeable.
  defp fetch_pipeline_status(_cfg, _owner, _repo, nil), do: nil
  defp fetch_pipeline_status(_cfg, _owner, _repo, ""), do: nil

  defp fetch_pipeline_status(cfg, owner, repo, sha) do
    case request(cfg, :get, "/repos/#{owner}/#{repo}/commits/#{sha}/check-runs", [])
         |> handle_json() do
      {:ok, %{"check_runs" => [_ | _] = runs}} ->
        map_check_run_status(runs)

      {:ok, %{"check_runs" => []}} ->
        :not_started

      _ ->
        nil
    end
  end

  # Collect the failing check runs for the PR's head commit and render each one
  # into a `name` + `summary` (output tail) + `url` map the Watchdog hands to a
  # fix-pass worker. No head SHA (or no check runs) → an empty list, never an
  # error — a `:ci_failed` block with nothing fetchable still dispatches the
  # fix pass, just without log context.
  defp fetch_failing_checks(_cfg, _owner, _repo, sha) when sha in [nil, ""], do: {:ok, []}

  defp fetch_failing_checks(cfg, owner, repo, sha) do
    case request(cfg, :get, "/repos/#{owner}/#{repo}/commits/#{sha}/check-runs", [])
         |> handle_json() do
      {:ok, %{"check_runs" => runs}} when is_list(runs) ->
        {:ok, runs |> Enum.filter(&failing_check?/1) |> Enum.map(&summarize_check/1)}

      {:ok, _} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  defp failing_check?(run), do: Map.get(run, "conclusion") in @failing_conclusions

  defp summarize_check(run) do
    output = Map.get(run, "output") || %{}

    summary =
      [Map.get(output, "title"), Map.get(output, "summary"), Map.get(output, "text")]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")
      |> truncate(@log_tail_limit)

    %{
      name: Map.get(run, "name") || "check",
      summary: summary,
      url: Map.get(run, "details_url") || Map.get(run, "html_url")
    }
  end

  defp truncate(str, limit) when is_binary(str) do
    if String.length(str) > limit, do: String.slice(str, 0, limit) <> "…", else: str
  end

  # `:pending` here means genuinely in-flight (queued/running); `:neutral`
  # means every check run has *completed* with a non-failing, non-all-success
  # conclusion mix (e.g. `neutral`/`skipped`/`stale`) — a settled, mergeable
  # state, not CI-still-running (bd-cnytw3 finding #1: conflating the two made
  # the Watchdog defer indefinitely on a PR that was actually done and
  # mergeable).
  defp map_check_run_status(runs) do
    conclusions = Enum.map(runs, &Map.get(&1, "conclusion"))
    statuses = Enum.map(runs, &Map.get(&1, "status"))

    cond do
      Enum.any?(conclusions, &(&1 in @failing_conclusions)) ->
        :failed

      Enum.all?(statuses, &(&1 == "completed")) and
          Enum.all?(conclusions, &(&1 in ["success", "skipped", "neutral"])) ->
        :success

      Enum.any?(statuses, &(&1 in ["in_progress", "queued", "waiting", "requested", "pending"])) ->
        :running

      true ->
        :neutral
    end
  end

  # ---- Internals: target / ref resolution ----------------------------------

  # Resolve the {owner, repo, ref_form} target for a fresh open/4. ref_form
  # determines whether the minted mr_ref will embed owner/repo (per-repo
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
               "or pass :repo_path so the adapter can derive owner/repo from the repo's git remote.",
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
    # Tolerate a leading `github:` strategy prefix (bd-3jjk0e): some stored refs
    # / callers carry the strategy tag, and without stripping it the owner would
    # parse as "github:owner" and every REST path would 404.
    mr_ref = String.replace_prefix(mr_ref, "github:", "")

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

  # ---- Internals: review threads (GraphQL) ---------------------------------

  # POST the review-threads query to GitHub's GraphQL endpoint. GraphQL returns
  # HTTP 200 even for query-level errors (carried in a top-level "errors" list),
  # so surface those as an error rather than silently treating an error payload
  # as "no threads".
  defp graphql_review_threads(cfg, owner, repo, number) do
    variables = %{"owner" => owner, "repo" => repo, "number" => number}
    payload = %{"query" => @review_threads_query, "variables" => variables}

    case request(cfg, :post, "/graphql", json: payload) do
      {:ok, %Req.Response{status: status, body: %{"errors" => [_ | _] = errors}}} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: status,
           message: graphql_error_message(errors),
           raw: errors
         }}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # POST the required-checks query. Same error-surfacing shape as
  # `graphql_review_threads/4` — GraphQL returns HTTP 200 even for
  # query-level errors.
  defp graphql_required_checks(cfg, owner, repo, number) do
    variables = %{"owner" => owner, "repo" => repo, "number" => number}
    payload = %{"query" => @required_checks_query, "variables" => variables}

    case request(cfg, :post, "/graphql", json: payload) do
      {:ok, %Req.Response{status: status, body: %{"errors" => [_ | _] = errors}}} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: status,
           message: graphql_error_message(errors),
           raw: errors
         }}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # ---- Internals: batched PR signals (GraphQL, bd-3byp1n) ------------------

  # Parse each ref to {owner, repo, number} and assign aliases: a repo alias
  # (`r0`, `r1`, …) per distinct {owner, repo} in first-seen order, and a
  # globally-unique PR alias (`p0`, `p1`, …) per entry. Unparseable refs are
  # dropped (the caller falls back per-PR for any ref missing from the result).
  defp batch_entries(cfg, refs) do
    {entries, _repo_aliases, _k} =
      refs
      |> Enum.reduce({[], %{}, 0}, fn ref, {acc, repo_aliases, k} ->
        case resolve_ref(cfg, ref) do
          {:ok, {owner, repo, number}} ->
            key = {owner, repo}

            {ralias, repo_aliases} =
              case Map.get(repo_aliases, key) do
                nil ->
                  ra = "r#{map_size(repo_aliases)}"
                  {ra, Map.put(repo_aliases, key, ra)}

                ra ->
                  {ra, repo_aliases}
              end

            entry = %{
              ref: ref,
              owner: owner,
              repo: repo,
              number: number,
              ralias: ralias,
              palias: "p#{k}"
            }

            {[entry | acc], repo_aliases, k + 1}

          _ ->
            {acc, repo_aliases, k + 1}
        end
      end)

    Enum.reverse(entries)
  end

  # Build one aliased query for all entries. owner/name go through GraphQL
  # variables (`$o<j>`/`$n<j>`) so repo identifiers can't inject query text; the
  # PR number is interpolated as a literal integer — safe (an int) and needed in
  # two spots, `pullRequest(number:)` and `isRequired(pullRequestNumber:)`, the
  # latter resolved per PR against that PR's own branch protection (never
  # hoisted). Returns `{query, variables_map}`.
  defp build_batch_query(entries) do
    repo_aliases = entries |> Enum.map(& &1.ralias) |> Enum.uniq()

    {var_decls, variables} =
      Enum.reduce(repo_aliases, {[], %{}}, fn "r" <> j = ra, {decls, vars} ->
        %{owner: owner, repo: repo} = Enum.find(entries, &(&1.ralias == ra))

        {decls ++ ["$o#{j}: String!", "$n#{j}: String!"],
         vars |> Map.put("o#{j}", owner) |> Map.put("n#{j}", repo)}
      end)

    repo_blocks =
      repo_aliases
      |> Enum.map(fn "r" <> j = ra ->
        pr_blocks =
          entries
          |> Enum.filter(&(&1.ralias == ra))
          |> Enum.map_join("\n", &batch_pr_block/1)

        "    #{ra}: repository(owner: $o#{j}, name: $n#{j}) {\n#{pr_blocks}\n    }"
      end)
      |> Enum.join("\n")

    # `rateLimit { cost }` is itself free of points and makes GitHub return the
    # exact points this query billed, so a sweep's cost is observable in the logs
    # (bd-3byp1n's "measure the points cost") rather than merely estimated.
    query =
      "query(#{Enum.join(var_decls, ", ")}) {\n#{repo_blocks}\n    rateLimit { cost nodeCount }\n}\n"

    {query, variables}
  end

  # The per-PR selection set — the "...PRBits" fragment inlined per alias (a
  # shared fragment can't carry the per-PR `isRequired(pullRequestNumber:)`
  # argument). Fetches exactly what the three trigger decisions need — and no
  # more, to keep the GraphQL points cost low (bd-3byp1n: "the points budget
  # must not become the new ceiling"):
  #
  #   * `reviews` states → changes_requested (same as `list_review_feedback/1`).
  #   * `reviewThreads { isResolved }` → the unresolved-thread COUNT PRPatrol
  #     triggers on. Comments are fetched `first: 1` (the opening comment, for
  #     thread author/body context) plus a second aliased `last: 1` page (the
  #     latest comment, bd-45x4yo — `answered_by_us?/2` needs to know who spoke
  #     LAST, not who opened the thread, or a thread we already replied to and
  #     left unresolved gets miscounted as still-open every tick) — NOT
  #     `first: 100` like the single-PR `@review_threads_query`. PRPatrol
  #     doesn't need the full comment tree; that's re-read per-PR by the
  #     follow-up worker via `list_open_review_threads/1`. Dropping the 100×100
  #     comment fan-out (2 comment nodes/thread instead) is what keeps this
  #     query's node cost ~one rollup page per PR instead of ~10k nodes/PR.
  #   * `statusCheckRollup` contexts with per-PR `isRequired` → required-check
  #     failures (same as `@required_checks_query`).
  defp batch_pr_block(%{palias: palias, number: number}) do
    """
        #{palias}: pullRequest(number: #{number}) {
          reviews(last: 100) { nodes { state author { login } } }
          reviewThreads(first: 100) {
            nodes {
              id
              isResolved
              path
              line
              comments(first: 1) { nodes { databaseId body author { login } } }
              latest: comments(last: 1) { nodes { databaseId body author { login } } }
            }
          }
          commits(last: 1) {
            nodes {
              commit {
                statusCheckRollup {
                  contexts(first: 100) {
                    nodes {
                      __typename
                      ... on CheckRun {
                        name
                        status
                        conclusion
                        detailsUrl
                        isRequired(pullRequestNumber: #{number})
                      }
                      ... on StatusContext {
                        context
                        state
                        targetUrl
                        description
                        isRequired(pullRequestNumber: #{number})
                      }
                    }
                  }
                }
              }
            }
          }
        }\
    """
  end

  # POST the batched query. Partial failure is tolerated: a body carrying a
  # `data` map is returned as `{:ok, data}` EVEN IF a top-level `errors` list is
  # also present (some aliased nodes came back null) — per-PR extraction then
  # skips the null nodes and the caller falls back for those refs. Only an
  # errors-only response (no usable `data`), an unexpected shape, a non-2xx, or a
  # transport error is a total `{:error, ...}`.
  defp graphql_batch(cfg, query, variables) do
    payload = %{"query" => query, "variables" => variables}

    case request(cfg, :post, "/graphql", json: payload) do
      {:ok, %Req.Response{status: status, body: %{"data" => data}}}
      when status in 200..299 and is_map(data) ->
        log_batch_points(data)
        {:ok, data}

      {:ok, %Req.Response{status: status, body: %{"errors" => [_ | _] = errors}}} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: status,
           message: graphql_error_message(errors),
           raw: errors
         }}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: status,
           message: "unexpected GraphQL response shape",
           raw: body
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # Log the GraphQL points this batched sweep actually billed (bd-3byp1n), so the
  # secondary-vs-primary budget can be watched in production. `cost` is the exact
  # points the query consumed against the token's 5,000 points/hr pool;
  # `nodeCount` is how many nodes it touched. Debug-level: one line per sweep.
  defp log_batch_points(%{"rateLimit" => %{"cost" => cost, "nodeCount" => nodes}})
       when is_integer(cost) do
    Logger.debug("GitHub batch_pr_signals: GraphQL points cost=#{cost} nodeCount=#{nodes}")
  end

  defp log_batch_points(_), do: :ok

  # Destructure the aliased response back to `%{ref => pr_signals}`. A ref whose
  # aliased node is null/missing (partial failure) is simply omitted so the
  # caller re-fetches it per-PR — never dropped silently.
  defp extract_batch(entries, data) do
    Enum.reduce(entries, %{}, fn e, acc ->
      case get_in(data, [e.ralias, e.palias]) do
        node when is_map(node) -> Map.put(acc, e.ref, extract_pr_signals(node))
        _ -> acc
      end
    end)
  end

  # Decompose one aliased PullRequest node into the three trigger signals,
  # reusing the SAME extractors the per-PR callbacks use so decisions are
  # identical.
  defp extract_pr_signals(node) do
    %{
      changes_requested: batch_changes_requested?(node),
      review_threads: batch_review_threads(node),
      required_check_failures: batch_required_check_failures(node)
    }
  end

  # Normalize the GraphQL reviews (`author { login }`) to the REST shape
  # `changes_requested?/1` expects (`user.login`), then reuse it verbatim — same
  # latest-verdict-per-reviewer semantics as `list_review_feedback/1`.
  defp batch_changes_requested?(node) do
    node
    |> get_in(["reviews", "nodes"])
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn r ->
      %{"state" => Map.get(r, "state"), "user" => %{"login" => get_in(r, ["author", "login"])}}
    end)
    |> changes_requested?()
  end

  # Same unresolved-thread filter + normalization as `list_open_review_threads/1`.
  defp batch_review_threads(node) do
    node
    |> get_in(["reviewThreads", "nodes"])
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(fn n -> Map.get(n, "isResolved") == true end)
    |> Enum.map(&merge_latest_thread_comment/1)
    |> Enum.map(&normalize_review_thread/1)
  end

  # bd-45x4yo: fold the `latest: comments(last: 1)` alias into `comments.nodes`
  # so `normalize_review_thread/1`'s `List.last(comments)` sees the thread's
  # most recent comment, not just its `first: 1` opener. When the thread has
  # only one comment, the first-page and last-page nodes are the same comment
  # (by `databaseId`) — keep just the one node rather than duplicating it.
  defp merge_latest_thread_comment(node) do
    opener_nodes =
      node |> get_in(["comments", "nodes"]) |> List.wrap() |> Enum.reject(&is_nil/1)

    latest_nodes =
      node |> get_in(["latest", "nodes"]) |> List.wrap() |> Enum.reject(&is_nil/1)

    merged =
      case {opener_nodes, latest_nodes} do
        {[o], [l]} when o != l -> [o, l]
        {[o], _} -> [o]
        _ -> opener_nodes
      end

    case get_in(node, ["comments", "nodes"]) do
      nil -> node
      _ -> put_in(node, ["comments", "nodes"], merged)
    end
  end

  # Same required+settled filter + summary as `list_required_check_failures/1`.
  defp batch_required_check_failures(node) do
    node
    |> get_in(["commits", "nodes"])
    |> List.wrap()
    |> List.first()
    |> case do
      %{"commit" => %{"statusCheckRollup" => %{"contexts" => %{"nodes" => nodes}}}}
      when is_list(nodes) ->
        nodes

      _ ->
        []
    end
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&required_settled_failure?/1)
    |> Enum.map(&summarize_required_check/1)
  end

  # A required rollup context (CheckRun or legacy StatusContext) that has
  # settled on a failing outcome. A required check still IN_PROGRESS/PENDING
  # is excluded — not yet a failure, just not green yet.
  defp required_settled_failure?(%{"isRequired" => true} = ctx) do
    case Map.get(ctx, "__typename") do
      "CheckRun" ->
        Map.get(ctx, "status") == "COMPLETED" and
          Map.get(ctx, "conclusion") in @failing_check_run_conclusions

      "StatusContext" ->
        Map.get(ctx, "state") in @failing_status_context_states

      _ ->
        false
    end
  end

  defp required_settled_failure?(_), do: false

  defp summarize_required_check(%{"__typename" => "CheckRun"} = ctx) do
    %{
      name: Map.get(ctx, "name") || "",
      summary: Map.get(ctx, "conclusion") || "",
      url: Map.get(ctx, "detailsUrl")
    }
  end

  defp summarize_required_check(%{"__typename" => "StatusContext"} = ctx) do
    %{
      name: Map.get(ctx, "context") || "",
      summary: Map.get(ctx, "description") || Map.get(ctx, "state") || "",
      url: Map.get(ctx, "targetUrl")
    }
  end

  defp graphql_resolve_review_thread(cfg, thread_id) do
    payload = %{"query" => @resolve_review_thread_mutation, "variables" => %{"id" => thread_id}}

    case request(cfg, :post, "/graphql", json: payload) do
      {:ok, %Req.Response{status: status, body: %{"errors" => [_ | _] = errors}}} ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: status,
           message: graphql_error_message(errors),
           raw: errors
         }}

      {:ok,
       %Req.Response{
         status: status,
         body: %{"data" => %{"resolveReviewThread" => %{"thread" => thread}}}
       }}
      when status in 200..299 ->
        {:ok, thread}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: status,
           message: "unexpected GraphQL response shape",
           raw: body
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  defp normalize_review_thread(node) do
    comment_nodes =
      node
      |> get_in(["comments", "nodes"])
      |> List.wrap()
      |> Enum.reject(&is_nil/1)

    first_comment = List.first(comment_nodes) || %{}

    comments =
      Enum.map(comment_nodes, fn c ->
        %{
          id: Map.get(c, "databaseId"),
          author: get_in(c, ["author", "login"]),
          body: Map.get(c, "body")
        }
      end)

    %{
      id: Map.get(node, "id"),
      resolved: Map.get(node, "isResolved") == true,
      path: Map.get(node, "path"),
      line: Map.get(node, "line"),
      author: get_in(first_comment, ["author", "login"]),
      body: Map.get(first_comment, "body"),
      comments: comments
    }
  end

  defp graphql_error_message(errors) do
    errors
    |> Enum.map(&Map.get(&1, "message"))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("; ")
    |> case do
      "" -> "GraphQL query error"
      msg -> msg
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
  # merge gate uses the internal worker verdict, not GitHub's review state,
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

    case perform_request(cfg.token, full_opts, 0) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, to_string(body)}

      {:ok, %Req.Response{status: status, body: body} = resp} ->
        {:error, http_error(status, body, resp)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

  # ---- Internals: HTTP -----------------------------------------------------

  # Bounded retries for GitHub's *secondary* (abuse) rate limit — a transient,
  # burst-triggered 403/429 distinct from primary quota exhaustion (bd-1yva53,
  # bd-2o4b8f). ReviewPatrol's per-tick poll of every open engagement is the
  # main source of these bursts; retrying here (rather than in every caller)
  # also covers mid-review adapter calls (get_diff, post_inline_comment, …) so
  # a single secondary-limit 403/429 no longer fails an entire CodeReview run.
  @max_secondary_retries 2
  @base_backoff_ms 250
  @max_backoff_ms 5_000

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

    perform_request(cfg.token, full_opts, 0)
  end

  # Every real HTTP request passes through the shared priority-aware GitHub
  # budget (bd-3p5vqc): background patrol traffic may be withheld here so it can
  # never starve foreground work (PR open/merge/finalize, deploys), and the
  # limiter observes each response to drive its headroom + secondary-limit
  # accounting.
  #
  # bd-8y1i58: the gate is *inside* the retry loop, not around it. With the loop
  # inside a single gate, one acquire could issue up to three real requests —
  # the limiter's counters (what an operator reads when the account is
  # exhausted) undercounted by up to 3x, and a background retry storm could not
  # be shed once it had started. Gating per attempt also means the first 403
  # arms the secondary backoff before the retry is decided, so background retry
  # traffic — the thing that *sustains* a secondary limit — is withheld.
  defp perform_request(token, full_opts, attempt) do
    case Limiter.gate(token, fn -> Req.request(full_opts) end) do
      {:ok, %Req.Response{status: status} = resp} = result when status in [403, 429] ->
        if attempt < @max_secondary_retries and secondary_rate_limited?(resp) do
          Logger.info(
            "GitHub: secondary rate limit hit (attempt #{attempt + 1}); backing off before retry"
          )

          wait_before_retry(resp, attempt)
          perform_request(token, full_opts, attempt + 1)
        else
          result
        end

      other ->
        other
    end
  end

  # GitHub's secondary/abuse limit is a 403 whose body names it explicitly, or
  # (per GitHub's docs) may carry a `Retry-After` header — unlike a primary
  # quota 403, which never does. Either signal is enough to treat it as
  # transient rather than a hard auth/permissions failure.
  defp secondary_rate_limited?(%Req.Response{} = resp) do
    retry_after_seconds(resp) != nil or secondary_limit_message?(resp.body)
  end

  defp secondary_limit_message?(%{"message" => msg}) when is_binary(msg) do
    msg = String.downcase(msg)
    String.contains?(msg, "secondary rate limit") or String.contains?(msg, "abuse detection")
  end

  defp secondary_limit_message?(_), do: false

  defp wait_before_retry(resp, attempt) do
    ms =
      case retry_after_seconds(resp) do
        nil -> backoff_ms(attempt)
        seconds -> min(seconds * 1_000, @max_backoff_ms)
      end

    sleep(ms)
  end

  defp retry_after_seconds(%Req.Response{} = resp) do
    case Req.Response.get_header(resp, "retry-after") do
      [v | _] ->
        case Integer.parse(v) do
          {n, _} when n >= 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Exponential backoff with jitter, capped — used when GitHub gives no
  # Retry-After header to honor directly.
  defp backoff_ms(attempt) do
    base = @base_backoff_ms * Integer.pow(2, attempt)
    jitter = :rand.uniform(div(base, 2) + 1)
    min(base + jitter, @max_backoff_ms)
  end

  # Overridable in tests (`Application.put_env(:arbiter, :github_retry_sleep_fun, fun)`)
  # so retry backoff never actually blocks the test suite.
  defp sleep(ms) do
    case Application.get_env(:arbiter, :github_retry_sleep_fun) do
      fun when is_function(fun, 1) -> fun.(ms)
      _ -> Process.sleep(ms)
    end
  end

  defp handle_json({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_json({:ok, %Req.Response{status: status, body: body} = resp}),
    do: {:error, http_error(status, body, resp)}

  defp handle_json({:error, exception}), do: {:error, transport_error(exception)}

  # For callbacks that only care about success vs failure (merge/close/comment).
  defp expect_ok({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp expect_ok({:ok, %Req.Response{status: status, body: body} = resp}),
    do: {:error, http_error(status, body, resp)}

  defp expect_ok({:error, exception}), do: {:error, transport_error(exception)}

  defp headers(%{token: token}) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "arbiter"}
    ]
  end

  # `resp` is the full `%Req.Response{}` when available (so rate-limit headers
  # can be read) — omitted at call sites that only destructured status/body
  # before GitHub's rate-limit shape mattered there (bd-1m8k7d).
  defp http_error(status, body, resp \\ nil) do
    %Error{
      kind: classify_kind(status, body),
      status: status,
      message: error_message(body, status),
      raw: body,
      retry_after_ms: rate_limit_retry_after_ms(status, resp)
    }
  end

  # A 429 is always a rate limit. A 403 is a rate limit only when the body
  # says so — otherwise it's a scope/permission `:forbidden` (bad credentials,
  # missing PR access, …). This distinguishes ReviewPatrol's target failure
  # (primary quota exhaustion, "API rate limit exceeded for user ID …", and
  # the secondary/abuse "you have exceeded a secondary rate limit…") from an
  # ordinary auth failure that a workspace-level backoff would only delay
  # surfacing (bd-1m8k7d).
  defp classify_kind(429, _body), do: :rate_limited

  defp classify_kind(403, body),
    do: if(rate_limited_body?(body), do: :rate_limited, else: :forbidden)

  defp classify_kind(status, _body), do: kind_for_status(status)

  defp rate_limited_body?(%{"message" => msg}) when is_binary(msg) do
    msg = String.downcase(msg)
    String.contains?(msg, "rate limit") or String.contains?(msg, "abuse detection")
  end

  defp rate_limited_body?(_), do: false

  defp kind_for_status(400), do: :validation_failed
  defp kind_for_status(401), do: :unauthenticated
  defp kind_for_status(404), do: :not_found
  defp kind_for_status(405), do: :not_mergeable
  defp kind_for_status(409), do: :conflict
  defp kind_for_status(422), do: :validation_failed
  defp kind_for_status(status) when status >= 500 and status < 600, do: :server_error
  defp kind_for_status(_), do: :http

  defp error_message(%{"message" => msg}, _status) when is_binary(msg), do: msg
  defp error_message(_, status), do: "HTTP #{status}"

  # How long to wait before the next rate-limited request, per GitHub's own
  # headers rather than a guess: `Retry-After` (seconds) when present — GitHub
  # sends this on the secondary/abuse limit — else `x-ratelimit-reset` (unix
  # epoch seconds), which the primary quota limit always sends instead. `resp`
  # is `nil` at call sites that never captured the full response; those simply
  # get no retry hint (the caller falls back to its own backoff policy).
  defp rate_limit_retry_after_ms(status, %Req.Response{} = resp) when status in [403, 429] do
    case retry_after_seconds(resp) do
      seconds when is_integer(seconds) -> seconds * 1_000
      nil -> reset_retry_after_ms(resp)
    end
  end

  defp rate_limit_retry_after_ms(_status, _resp), do: nil

  defp reset_retry_after_ms(%Req.Response{} = resp) do
    with [v | _] <- Req.Response.get_header(resp, "x-ratelimit-reset"),
         {epoch, _} <- Integer.parse(v) do
      ms = (epoch - System.os_time(:second)) * 1_000
      if ms > 0, do: ms, else: nil
    else
      _ -> nil
    end
  end

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
