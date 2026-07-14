defmodule Arbiter.Reviews.ExternalReview do
  @moduledoc """
  Review an **external / non-arbiter PR** — one the fleet never opened (a
  coworker's PR) — with no pre-linked arbiter task and no arbiter-authored
  branch (bd-d4ealy).

  ## Why this exists

  `arb review <task-id>` dispatches a claude-driven reviewer against the PR/MR
  *linked to an arbiter task* — but a task's `pr_ref` is only minted when arbiter
  itself opens/manages the MR. There was no supported path to point a review at
  an existing external PR. This module is that path: given a repo checkout + a
  PR identifier (URL or number), it constructs an `mr_ref` through the
  configured **MR-provider adapter** and runs `Arbiter.Workflows.CodeReview` in
  `:adapter` mode — read the diff, post per-finding inline comments, submit a
  single verdict — entirely against the forge, with no task / worktree / branch.

  ## Tracker vs. MR-provider split

  A workspace may track issues in Jira while its MRs live on GitHub. The review
  targets the **MR provider** (`config["merge"]["strategy"]` →
  `Arbiter.Mergers.for_workspace/1`), *not* the issue tracker. `mr_ref`
  construction is delegated to the adapter's `ref_for_pr/2` callback, so adding
  GitLab / another MR provider needs no change here — the orchestrator stays
  adapter-blind.

  ## Sync vs. async

    * `review/1` runs the whole thing synchronously and returns the verdict —
      used by tests and any caller that wants to block on the result.
    * `dispatch/1` validates synchronously (so a bad PR ref / unsupported
      strategy fails fast with a clear error) and then runs the workflow in a
      supervised background `Task`, returning a "dispatched" ack immediately.
      The findings + verdict land on the PR itself. This mirrors the
      fire-and-acknowledge semantics of `arb review`.

  ## Follow-up engagement (Option A, bd-2ovun1)

  A one-shot external review posts findings + a verdict and then forgets the PR
  — nothing re-reviews new commits, handles author replies, or tracks the PR to
  merge. Those lifecycle behaviours live in `Arbiter.Workflows.ReviewPatrol`,
  which only acts on **engagements**: an `Issue` with `review_only == true` and a
  `source_pr` set.

  So when `follow_up` is set (default: on when the workspace has a ReviewPatrol
  running), this module — **after the verdict posts** — creates exactly one such
  engagement so ReviewPatrol adopts the PR on its next tick. The engagement:

    * is `review_only` and `tracker_type: :none` → tracker-inert (no upstream
      lifecycle write-back) and `issue_type: :task` → the non-reviewable type
      that spawns **no worktree/branch**;
    * records `source_pr` = the constructed `mr_ref` (what ReviewPatrol hands to
      `adapter.get/1`), a baseline `last_reviewed_sha` (PR head at review time,
      so only *later* commits trigger a re-review), a `last_seen_comment_id`
      high-watermark (so only *new* author replies trigger), and the resolved
      `review_automation` mode;
    * carries `tracker_context_ref`/`tracker_context_type` when supplied.

  Dedup: if an open `review_only` engagement already exists for
  `(source_pr, workspace)`, no second one is created — a repeated `follow_up`
  dispatch for the same PR is a no-op on the engagement.
  """

  require Logger
  require Ash.Query

  alias Arbiter.Mergers
  alias Arbiter.Reviews.{Checkout, Record}
  alias Arbiter.Tasks.{Issue, RepoConfig, Workspace}
  alias Arbiter.Worker.{ReviewAutomation, ReviewScope}
  alias Arbiter.Workflows.{CodeReview, ReviewPatrolSupervisor}

  @task_supervisor Arbiter.Reviews.TaskSupervisor

  @type opts :: [
          pr: String.t(),
          repo: String.t() | nil,
          workspace: String.t() | nil,
          check_runner: (String.t(), map() -> {:ok, list()} | {:error, term()}) | nil,
          # When true (or, when unset, when the workspace has a ReviewPatrol
          # running), a `review_only` engagement is created after the verdict
          # posts so ReviewPatrol adopts the PR (Option A, bd-2ovun1). When
          # false, the review is a pure one-shot (legacy behaviour).
          follow_up: boolean() | nil,
          # Explicit engagement automation override; otherwise resolved from the
          # workspace `review_automation` policy against the PR author.
          automation: :auto | :report_only | :flag | String.t() | nil,
          # Force report-only (propose) mode: run the full review but post NOTHING
          # to the PR — surface findings + proposed comments to the coordinator to
          # greenlight (bd-36qzgx). When unset, resolved from `automation` /
          # workspace policy: a :report_only mode ⇒ report-only.
          report_only: boolean() | nil,
          # Read-only tracker context (e.g. the ticket the PR implements) carried
          # onto the engagement for re-review intent (#638).
          tracker_context_ref: String.t() | nil,
          tracker_context_type: atom() | String.t() | nil,
          # Review depth (bd-5xsp25): "diff" (default) sees only the unified
          # diff; "repo" additionally gets a read-only cross-file consumer
          # trace against the resolved repo checkout. Unset ⇒ resolved from
          # the workspace `review_scope` policy (default + sensitive-path
          # auto-escalation) — see `Arbiter.Worker.ReviewScope`.
          scope: :diff | :repo | String.t() | nil
        ]

  @doc """
  Validate an external-review request and resolve everything the workflow needs
  — workspace, MR-provider adapter, local checkout path, and the constructed
  `mr_ref` — without running the (slow) review itself.

  Fails fast on a missing/unparseable PR identifier, an unknown workspace, or a
  merge strategy with no external-PR support (e.g. `:direct`).
  """
  @spec prepare(opts() | map()) :: {:ok, map()} | {:error, term()}
  def prepare(opts) do
    opts = Map.new(opts)

    with {:ok, pr} <- fetch_pr(opts),
         {:ok, workspace} <- resolve_workspace(Map.get(opts, :workspace)),
         adapter = Mergers.for_workspace(workspace),
         strategy = Workspace.merger_strategy(workspace),
         :ok <- ensure_supports_external(adapter, strategy),
         repo_path = resolve_repo_path(workspace, Map.get(opts, :repo)),
         :ok <- Mergers.prepare(workspace),
         {:ok, mr_ref} <- adapter.ref_for_pr(pr, %{repo_path: repo_path}) do
      {:ok,
       %{
         workspace: workspace,
         adapter: adapter,
         strategy: strategy,
         mr_ref: mr_ref,
         repo_path: repo_path,
         pr: pr,
         link: safe_link(adapter, mr_ref)
       }}
    end
  end

  @doc """
  Run an external review **synchronously** and return the verdict.

  Returns `{:ok, result}` where `result` carries the `:verdict`
  (`:approve | :request_changes`), the number of `:findings`, and the resolved
  `:mr_ref` / `:link`. Returns `{:error, reason}` on a validation or workflow
  failure.
  """
  @spec review(opts() | map()) :: {:ok, map()} | {:error, term()}
  def review(opts) do
    opts = Map.new(opts)

    with {:ok, prepared} <- prepare(opts) do
      opts = put_report_only(opts, prepared)
      record = create_review_record(prepared, opts)

      case run_workflow(prepared, opts) do
        {:ok, result} ->
          complete_review_record(record, :completed, result)
          write_usage_event(record, prepared, result)
          maybe_notify_coordinator(prepared, result, record)
          {:ok, result}

        {:error, _} = err ->
          complete_review_record(record, :failed, %{})
          err
      end
    end
  end

  @doc """
  Validate synchronously, then run the review in a supervised background `Task`,
  returning a "dispatched" ack immediately (`{:ok, ack}`). The findings +
  verdict are posted to the PR by the adapter when the workflow completes.

  A validation error (bad PR ref, unknown workspace, unsupported strategy)
  returns `{:error, reason}` before anything is spawned.
  """
  @spec dispatch(opts() | map()) :: {:ok, map()} | {:error, term()}
  def dispatch(opts) do
    opts = Map.new(opts)

    with {:ok, prepared} <- prepare(opts) do
      opts = put_report_only(opts, prepared)
      record = create_review_record(prepared, opts)
      start_async(prepared, opts, record)
      {:ok, ack(prepared, record)}
    end
  end

  @doc """
  Turn any error this module returns into a single human-readable string, so the
  REST controller and the MCP tool can render a consistent message.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(:pr_required),
    do: "a PR/MR identifier is required (pass --pr <url|number>)"

  def describe_error({:unsupported_strategy, strategy}),
    do:
      "external PR review is not supported for the #{inspect(strategy)} merge strategy — " <>
        "configure a hosted MR provider (github/gitlab) under config[\"merge\"][\"strategy\"]"

  def describe_error({:workspace, msg}) when is_binary(msg), do: msg

  def describe_error(%{__struct__: mod, message: msg}) when is_binary(msg),
    do: "#{inspect(mod)}: #{msg}"

  def describe_error(other), do: "external review failed: #{inspect(other)}"

  @doc """
  Greenlight step for a report-only review (bd-36qzgx): post the
  coordinator-approved subset of a review's proposed comments to the PR — and
  nothing else. Un-approved findings never post.

  Opts:

    * `record_id` (required) — the `Arbiter.Reviews.Record` id of the report-only
      review whose `proposed_comments` to post.
    * `select` — which proposed comments to approve: omit (or `"all"` / `:all`)
      for every proposed comment, or a list of zero-based indices into the
      review's `proposed_comments`. An empty list posts nothing (records
      `greenlight_status: :none`).
    * `post_verdict` — whether to also submit the recommended verdict as a
      single review. Defaults to `true` when at least one comment is approved,
      `false` when none are (so "approve nothing" is a true no-op on the PR).
    * `repo` — optional local checkout (only needed by adapters that resolve
      owner/repo from a bare PR number).

  Returns `{:ok, %{mr_ref, posted, selected, verdict_posted, link}}`.
  """
  @spec greenlight(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def greenlight(opts) do
    opts = Map.new(opts)

    with {:ok, record} <- fetch_record(opts),
         {:ok, workspace} <- resolve_workspace(record.workspace_id),
         adapter = Mergers.for_workspace(workspace),
         strategy = Workspace.merger_strategy(workspace),
         :ok <- ensure_supports_external(adapter, strategy),
         repo_path = resolve_repo_path(workspace, Map.get(opts, :repo)),
         :ok <- Mergers.prepare(workspace) do
      do_greenlight(record, adapter, repo_path, opts)
    end
  end

  defp do_greenlight(%Record{} = record, adapter, repo_path, opts) do
    mr_ref = record.pr_ref
    proposed = record.proposed_comments || []
    selected = select_comments(proposed, opts)
    adapter_opts = adapter_opts(repo_path)
    post_verdict? = Map.get(opts, :post_verdict, selected != [])

    with {:ok, posted} <- post_selected_comments(adapter, mr_ref, selected, adapter_opts),
         {:ok, verdict_posted} <-
           maybe_submit_verdict(adapter, mr_ref, record, post_verdict?, adapter_opts) do
      mark_greenlit(record, selected)

      Logger.info(
        "ExternalReview.greenlight: #{mr_ref} posted #{length(posted)}/#{length(proposed)} " <>
          "proposed comment(s)#{if verdict_posted, do: " + verdict", else: ""}"
      )

      {:ok,
       %{
         mr_ref: mr_ref,
         posted: length(posted),
         selected: length(selected),
         proposed: length(proposed),
         verdict_posted: verdict_posted,
         verdict: record.verdict,
         link: safe_link(adapter, mr_ref)
       }}
    end
  end

  # Load the report-only review record by id.
  defp fetch_record(opts) do
    case string_opt(opts, :record_id) || string_opt(opts, :review_record_id) do
      id when is_binary(id) and id != "" ->
        case Ash.get(Record, id) do
          {:ok, %Record{} = rec} -> {:ok, rec}
          _ -> {:error, {:not_found, "no review record #{id}"}}
        end

      _ ->
        {:error, {:invalid, "greenlight requires a record_id"}}
    end
  rescue
    _ -> {:error, {:not_found, "review record lookup failed"}}
  end

  # Which proposed comments the coordinator approved. Default = all; a list of
  # zero-based indices selects a subset; an empty list posts nothing.
  defp select_comments(proposed, opts) do
    case Map.get(opts, :select) do
      nil ->
        proposed

      :all ->
        proposed

      "all" ->
        proposed

      idxs when is_list(idxs) ->
        idxs |> Enum.map(&Enum.at(proposed, &1)) |> Enum.reject(&is_nil/1)

      _ ->
        proposed
    end
  end

  defp post_selected_comments(adapter, mr_ref, selected, adapter_opts) do
    Enum.reduce_while(selected, {:ok, []}, fn comment, {:ok, acc} ->
      case safe_adapter_call(adapter, :post_inline_comment, [
             mr_ref,
             to_finding(comment),
             adapter_opts
           ]) do
        {:ok, resp} -> {:cont, {:ok, [resp | acc]}}
        :ok -> {:cont, {:ok, acc}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp maybe_submit_verdict(_adapter, _mr_ref, _record, false, _opts), do: {:ok, false}

  defp maybe_submit_verdict(adapter, mr_ref, %Record{} = record, true, adapter_opts) do
    verdict = record.verdict || :approve
    finding_count = record.finding_count || 0

    body =
      "Greenlit review (#{finding_count} finding(s)) — recommendation: " <>
        String.upcase(to_string(verdict)) <> "."

    case safe_adapter_call(adapter, :submit_review, [mr_ref, verdict, body, adapter_opts]) do
      {:ok, _} -> {:ok, true}
      :ok -> {:ok, true}
      {:error, _} = err -> err
    end
  end

  # Record the outcome: :posted when we posted at least one comment, :none when
  # the coordinator approved nothing.
  defp mark_greenlit(%Record{} = record, selected) do
    status = if selected == [], do: :none, else: :posted

    case Ash.update(record, %{greenlight_status: status}, action: :greenlight) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  rescue
    _ -> :ok
  end

  # Rehydrate a string-keyed stored proposed comment into the atom-keyed finding
  # shape the adapters' post_inline_comment/3 expects.
  defp to_finding(%{} = c) do
    %{
      severity: severity_atom(c["severity"] || c[:severity]),
      file: c["file"] || c[:file],
      line: c["line"] || c[:line],
      message: c["message"] || c[:message]
    }
  end

  defp severity_atom(s) when s in [:error, :warning, :info], do: s
  defp severity_atom("error"), do: :error
  defp severity_atom("warning"), do: :warning
  defp severity_atom("info"), do: :info
  defp severity_atom(_), do: :info

  # ---- internals -----------------------------------------------------------

  defp fetch_pr(opts) do
    case Map.get(opts, :pr) do
      pr when is_binary(pr) and pr != "" -> {:ok, String.trim(pr)}
      _ -> {:error, :pr_required}
    end
  end

  # The review targets the MR provider, so an adapter that can't mint a ref for
  # an externally-authored PR (Direct — local merge, no forge) cannot run one.
  defp ensure_supports_external(adapter, strategy) do
    # function_exported?/2 does not load the module; in interactive/mix mode the
    # adapter may not be loaded yet, so ensure it is before the export check —
    # otherwise every external review is wrongly rejected as unsupported.
    Code.ensure_loaded(adapter)

    if function_exported?(adapter, :ref_for_pr, 2) do
      :ok
    else
      {:error, {:unsupported_strategy, strategy}}
    end
  end

  defp run_workflow(prepared, opts) do
    %{adapter: adapter, mr_ref: mr_ref, workspace: workspace, repo_path: repo_path} = prepared
    report_only = Map.get(opts, :report_only, false)
    ws_config = workspace_config(workspace)

    # Tier 2 (bd-6onexk): best-effort checkout of the PR's actual head commit
    # into a throwaway worktree, so the reviewer gets real file/grep/bash
    # access at PR-head instead of only the unified diff. `checkout_path` is
    # nil when a checkout can't be provisioned (no repo_path, no head_sha, or
    # the git operations themselves fail) — the Tier-1 diff-only path (the
    # original `repo_path`) is then unchanged.
    checkout_path = provision_checkout(adapter, mr_ref, workspace, repo_path)

    state =
      %{
        mode: :adapter,
        adapter: adapter,
        mr_ref: mr_ref,
        # Threaded so CodeReview re-seeds the adapter's per-process config
        # (Mergers.prepare/1) at the start of every step — required when the
        # workflow runs in the async Task's process, not the caller's.
        workspace: workspace,
        adapter_opts: adapter_opts(repo_path),
        # report-only (propose): CodeReview reads the diff + computes findings /
        # verdict but posts NOTHING; the proposed comments land in state.
        report_only: report_only,
        # Review scope (bd-5xsp25): explicit override resolved now (doesn't
        # depend on the diff); sensitive-glob auto-escalation is resolved
        # inside CodeReview once the diff's changed files are known. Once a
        # PR-head worktree is provisioned, ConsumerTrace's cross-file grep
        # runs against it, subsuming the old base-tree limitation.
        scope: ReviewScope.resolve(ws_config, Map.get(opts, :scope), []),
        repo_path: checkout_path || repo_path,
        sensitive_globs: sensitive_globs(ws_config)
      }
      |> maybe_put(:review_cwd, checkout_path)
      |> maybe_put_check_runner(opts)
      |> maybe_put_tracker_context(opts, workspace)

    result =
      case Arbiter.Workflow.run(CodeReview, state) do
        {:ok, final} ->
          # After the verdict posts (or, for report-only, is computed), adopt the
          # PR into ReviewPatrol by opening a review_only engagement (Option A).
          # Best-effort: a failure here never fails the review itself. The
          # first-pass findings seed the engagement's `posted_findings` so
          # ReviewPatrol's relevance gate (re-review only when a new commit touches
          # a previously-flagged file) has something to match against.
          engagement = maybe_create_engagement(prepared, opts, Map.get(final, :findings) || [])
          {:ok, result(prepared, final, engagement, report_only)}

        {:error, _} = err ->
          err
      end

    Checkout.teardown(checkout_path)
    result
  end

  # Best-effort: resolve the PR's head SHA via the adapter, then hand it to
  # `Checkout.provision/2`. Returns the worktree path on success, nil on any
  # failure (missing repo_path, adapter can't answer `get/1`, git failure) —
  # never raises, and never blocks the review on a checkout problem.
  defp provision_checkout(_adapter, _mr_ref, _workspace, nil), do: nil
  defp provision_checkout(_adapter, _mr_ref, _workspace, ""), do: nil

  defp provision_checkout(adapter, mr_ref, workspace, repo_path) do
    Mergers.prepare(workspace)

    case head_sha_for(adapter, mr_ref) do
      sha when is_binary(sha) and sha != "" ->
        case Checkout.provision(repo_path, sha) do
          {:ok, path} ->
            path

          {:error, reason} ->
            Logger.warning(
              "ExternalReview: checkout provisioning failed for #{mr_ref}: #{inspect(reason)}"
            )

            nil
        end

      _ ->
        nil
    end
  end

  defp head_sha_for(adapter, mr_ref) do
    case safe_adapter_call(adapter, :get, [mr_ref]) do
      {:ok, %{} = info} -> Map.get(info, :head_sha) || Map.get(info, "head_sha")
      _ -> nil
    end
  end

  # Resolve whether this review runs report-only (post nothing, await greenlight).
  # An explicit `report_only: true` or `automation: "report_only"|"propose"` wins;
  # otherwise the workspace `review_automation` policy decides — a repo_override or
  # default of `report_only` (e.g. infra repos atlas / verus-infrastructure) makes
  # the review report-only. Author is not needed: the author-based path only ever
  # yields :auto, never :report_only.
  defp put_report_only(opts, prepared) do
    Map.put(opts, :report_only, report_only_mode?(opts, prepared))
  end

  defp report_only_mode?(opts, prepared) do
    cond do
      Map.get(opts, :report_only) == true ->
        true

      true ->
        case ReviewAutomation.normalize(Map.get(opts, :automation)) do
          :report_only ->
            true

          mode when mode in [:auto, :flag] ->
            false

          nil ->
            config = workspace_config(prepared.workspace)
            ReviewAutomation.resolve(config, nil, Map.get(opts, :repo)) == :report_only
        end
    end
  end

  defp workspace_config(%Workspace{config: config}), do: config
  defp workspace_config(_), do: nil

  defp sensitive_globs(%{"review_scope" => %{"sensitive_globs" => globs}}) when is_list(globs),
    do: globs

  defp sensitive_globs(_ws_config), do: []

  # ---- report-only coordinator notification (bd-36qzgx) --------------------

  # After a report-only review completes, surface the findings + per-finding
  # proposed comment text to the coordinator mailbox so a human can greenlight
  # which comments actually post. Best-effort: a mailbox failure never fails the
  # review. No-op for a normal (auto) review — that already posted to the PR.
  defp maybe_notify_coordinator(prepared, %{report_only: true} = result, record) do
    ws_id = prepared.workspace && prepared.workspace.id

    if is_binary(ws_id) do
      safe_call(fn ->
        Arbiter.Messages.Message.send_mail(%{
          kind: :escalation,
          to_ref: "admiral",
          from_ref: "external_review",
          workspace_id: ws_id,
          directive_ref: String.slice(prepared.mr_ref, 0, 255),
          subject:
            "Report-only review: #{prepared.mr_ref} — #{result.findings} proposed comment(s), " <>
              "recommend #{result.verdict}",
          body: render_report_body(prepared, result, record)
        })
      end)
    end

    :ok
  end

  defp maybe_notify_coordinator(_prepared, _result, _record), do: :ok

  defp render_report_body(prepared, result, record) do
    rec_id = record && record.id
    proposed = Map.get(result, :proposed_comments) || []

    comments =
      case proposed do
        [] ->
          "(no findings — recommended verdict: #{result.verdict})"

        list ->
          list
          |> Enum.with_index()
          |> Enum.map(fn {c, i} ->
            file = c[:file] || c["file"] || "?"
            line = c[:line] || c["line"]
            loc = if line, do: "#{file}:#{line}", else: file
            body = c[:body] || c["body"] || ""
            "  [#{i}] #{loc}\n      #{body}"
          end)
          |> Enum.join("\n")
      end

    """
    Report-only review of #{prepared.pr} (#{prepared.mr_ref}).
    #{if is_binary(result.link) and result.link != "", do: "Link: #{result.link}\n", else: ""}\
    Recommended verdict: #{result.verdict}. Nothing was posted to the PR.

    Proposed comments:
    #{comments}

    To post the approved subset, greenlight this review#{if rec_id, do: " (record #{rec_id})", else: ""}:
      review_greenlight record_id=#{rec_id} select=all        # post all
      review_greenlight record_id=#{rec_id} select=[0,2]      # post only #0 and #2
      review_greenlight record_id=#{rec_id} select=[]         # approve nothing
    """
  end

  # Persist the (string-keyed) proposed comments on the audit record for a
  # report-only review so the greenlight step can post the approved subset.
  defp maybe_put_proposed(attrs, false, _proposed), do: attrs

  defp maybe_put_proposed(attrs, true, proposed) do
    Map.put(attrs, :proposed_comments, stringify_proposed(proposed))
  end

  defp stringify_proposed(proposed) do
    proposed
    |> List.wrap()
    |> Enum.map(fn c ->
      %{
        "file" => c[:file] || c["file"],
        "line" => c[:line] || c["line"],
        "severity" => to_string(c[:severity] || c["severity"] || ""),
        "message" => c[:message] || c["message"],
        "body" => c[:body] || c["body"]
      }
    end)
  end

  defp safe_adapter_call(adapter, fun, args) do
    apply(adapter, fun, args)
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp adapter_opts(repo_path) when is_binary(repo_path), do: %{repo_path: repo_path}
  defp adapter_opts(_), do: %{}

  # A test/advanced caller can inject a deterministic check runner; otherwise
  # CodeReview falls back to its default (a one-shot Claude review of the diff).
  defp maybe_put_check_runner(state, opts) do
    case Map.get(opts, :check_runner) do
      fun when is_function(fun, 2) -> Map.put(state, :check_runner, fun)
      _ -> state
    end
  end

  defp start_async(prepared, opts, record) do
    Task.Supervisor.start_child(@task_supervisor, fn ->
      case run_workflow(prepared, opts) do
        {:ok, result} ->
          complete_review_record(record, :completed, result)
          write_usage_event(record, prepared, result)
          maybe_notify_coordinator(prepared, result, record)

          Logger.info(
            "ExternalReview: #{result.strategy} #{result.mr_ref} → #{result.verdict} " <>
              "(#{result.findings} finding(s), #{result.mode}) #{result.link}"
          )

        {:error, reason} ->
          complete_review_record(record, :failed, %{})

          Logger.warning(
            "ExternalReview: #{prepared.strategy} #{prepared.mr_ref} failed: #{inspect(reason)}"
          )
      end
    end)
  end

  defp ack(prepared, record) do
    %{
      external: true,
      status: "dispatched",
      pr: prepared.pr,
      mr_ref: prepared.mr_ref,
      strategy: prepared.strategy,
      link: prepared.link,
      review_record_id: record && record.id,
      mode: record && record.mode
    }
  end

  defp result(prepared, final, engagement, report_only) do
    proposed = Map.get(final, :proposed_comments) || []

    %{
      external: true,
      pr: prepared.pr,
      mr_ref: prepared.mr_ref,
      strategy: prepared.strategy,
      link: prepared.link,
      mode: if(report_only, do: :report_only, else: :auto),
      report_only: report_only,
      verdict: Map.get(final, :verdict),
      findings: length(Map.get(final, :findings) || []),
      findings_list: Map.get(final, :findings) || [],
      # Report-only: the per-finding proposed inline comments (posted nothing).
      proposed_comments: proposed,
      review_path: Map.get(final, :review_path),
      # Structured usage from the check runner (model, cost, tokens) — populated
      # when the default Claude invoker ran; nil when a stub runner was used.
      check_usage: Map.get(final, :check_usage),
      # The id of the review_only engagement created (or adopted) for this PR,
      # or nil when follow-up was off / disabled.
      engagement: engagement && engagement.id,
      engagement_created: (engagement && engagement.created) || false
    }
  end

  defp safe_link(adapter, mr_ref) do
    adapter.link_for(mr_ref)
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  # ---- follow-up engagement (Option A, bd-2ovun1) --------------------------

  # After the verdict posts, create a review_only engagement so ReviewPatrol
  # adopts the PR. Returns %{id, created} on create, %{id, created: false} when
  # an open engagement already existed (dedup), or nil when follow-up is off /
  # anything goes wrong (best-effort — never fails the review).
  defp maybe_create_engagement(prepared, opts, findings) do
    if follow_up?(prepared, opts) do
      create_engagement(prepared, opts, findings)
    else
      nil
    end
  end

  # follow_up resolution: an explicit boolean wins; otherwise engage by default
  # only when the workspace actually has a ReviewPatrol running (no point filing
  # an engagement nothing will pick up).
  defp follow_up?(prepared, opts) do
    case Map.get(opts, :follow_up) do
      v when is_boolean(v) -> v
      _ -> review_patrol_active?(prepared.workspace)
    end
  end

  defp review_patrol_active?(%Workspace{id: id}) when is_binary(id) do
    ReviewPatrolSupervisor.whereis_all(id) != []
  rescue
    _ -> false
  end

  defp review_patrol_active?(_workspace), do: false

  defp create_engagement(
         %{mr_ref: mr_ref, workspace: %Workspace{id: ws_id}} = prepared,
         opts,
         findings
       ) do
    case existing_engagement(mr_ref, ws_id) do
      %Issue{} = existing ->
        # Dedup: an open review_only engagement already tracks this PR.
        Logger.info(
          "ExternalReview: engagement #{existing.id} already open for #{mr_ref}; not duplicating"
        )

        %{id: existing.id, created: false}

      :error ->
        # The dedup read itself failed. Fail closed: an open engagement *may*
        # exist and we can't tell, so skip creation rather than risk a duplicate
        # (the exact thing the dedup guards against). A later dispatch retries.
        Logger.warning(
          "ExternalReview: dedup read failed for #{mr_ref}; skipping engagement creation " <>
            "to avoid a possible duplicate"
        )

        nil

      nil ->
        do_create_engagement(prepared, opts, findings)
    end
  rescue
    e ->
      Logger.warning(
        "ExternalReview: engagement creation crashed for #{prepared.mr_ref}: " <>
          Exception.message(e)
      )

      nil
  end

  defp create_engagement(_prepared, _opts, _findings), do: nil

  # An OPEN review_only engagement already linked to this PR in this workspace,
  # or nil when none exists. Mirrors ReviewPatrol's own engagement predicate
  # (review_only + source_pr + not closed), scoped to the workspace. Returns the
  # `:error` sentinel when the read itself fails — the caller fails closed and
  # skips creation, so a transient DB blip can't spawn a duplicate engagement.
  defp existing_engagement(mr_ref, ws_id) do
    Issue
    |> Ash.Query.filter(
      review_only == true and source_pr == ^mr_ref and status != :closed and
        workspace_id == ^ws_id
    )
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> :error
  end

  defp do_create_engagement(%{adapter: adapter, mr_ref: mr_ref} = prepared, opts, findings) do
    # Baseline captured at review time: PR head SHA (so only later commits
    # trigger a re-review) + the PR author (for automation-mode resolution).
    {head_sha, pr_author} = fetch_pr_baseline(adapter, mr_ref)
    watermark = fetch_comment_watermark(adapter, mr_ref)
    mode = resolve_automation(opts, prepared.workspace, pr_author, Map.get(opts, :repo))

    case create_engagement_issue(prepared, opts, mode, head_sha, watermark, findings) do
      {:ok, issue} ->
        Logger.info(
          "ExternalReview: opened review engagement #{issue.id} for #{mr_ref} " <>
            "(mode #{mode}, baseline #{head_sha || "-"}, cursor #{watermark || "-"})"
        )

        %{id: issue.id, created: true}

      {:error, reason} ->
        Logger.warning(
          "ExternalReview: failed to open engagement for #{mr_ref}: #{inspect(reason)}"
        )

        nil
    end
  end

  # Create the engagement Issue in one atomic action. review_only + the
  # ReviewPatrol baseline/cursor + automation mode are set at create time (the
  # :create action accepts them — bd-2ovun1) so an engagement is never left
  # half-formed. tracker_type: :none + skip_upstream_create keep it tracker-inert;
  # issue_type: :task is the non-reviewable type so nothing ever provisions a
  # worktree/branch for it.
  defp create_engagement_issue(
         %{mr_ref: mr_ref, workspace: %Workspace{id: ws_id}} = prepared,
         opts,
         mode,
         head_sha,
         watermark,
         findings
       ) do
    attrs =
      %{
        title: engagement_title(mr_ref),
        description: engagement_description(prepared),
        issue_type: :task,
        priority: 2,
        tracker_type: :none,
        source_pr: mr_ref,
        workspace_id: ws_id,
        review_only: true,
        review_automation: mode,
        skip_upstream_create: true,
        # Seed the relevance baseline from the first-pass findings so a later
        # commit touching a flagged file triggers a re-review. An approve /
        # zero-finding review leaves this empty (correctly quiet).
        posted_findings: normalize_findings(findings)
      }
      |> maybe_put(:last_reviewed_sha, head_sha)
      |> maybe_put(:last_seen_comment_id, watermark)
      |> put_tracker_context(opts, prepared.workspace)

    Ash.create(Issue, attrs)
  end

  # Map fresh (atom-keyed) check findings into the string-keyed shape
  # ReviewPatrol persists and reads (`stored_finding/1` / `stored_field/2` in
  # `Arbiter.Workflows.ReviewPatrol`), so its relevance gate and dedup can match
  # them against re-review findings.
  defp normalize_findings(findings) do
    findings
    |> List.wrap()
    |> Enum.map(fn f ->
      %{
        "file" => f[:file] || f["file"],
        "line" => f[:line] || f["line"],
        "message" => f[:message] || f["message"],
        "severity" => to_string(f[:severity] || f["severity"] || "")
      }
    end)
  end

  defp engagement_title(mr_ref), do: "Review engagement: #{mr_ref}"

  defp engagement_description(%{pr: pr, mr_ref: mr_ref, link: link}) do
    """
    ReviewPatrol engagement for an external PR review (bd-2ovun1).

    PR: #{pr} (#{mr_ref})
    #{if is_binary(link) and link != "", do: "Link: #{link}\n", else: ""}\
    Opened by ExternalReview after posting the first-pass verdict. ReviewPatrol
    owns this task's lifecycle from here: new-commit re-review, author-reply
    handling, and stop-on-merge. Tracker-inert, no worktree/branch.
    """
  end

  # Carry read-only tracker context onto the engagement when supplied, defaulting
  # the type to the workspace tracker (the common reviewee==reviewer-tracker case).
  defp put_tracker_context(attrs, opts, workspace) do
    case string_opt(opts, :tracker_context_ref) do
      ref when is_binary(ref) and ref != "" ->
        attrs
        |> Map.put(:tracker_context_ref, ref)
        |> maybe_put(:tracker_context_type, tracker_context_type(opts, workspace))

      _ ->
        attrs
    end
  end

  # Fetch the linked tracker ticket (title + description) so `Checks.build_prompt/2`
  # can fold it into the reviewer prompt (bd-adpwl0) — read-only, best-effort:
  # a fetch failure (or no `tracker_context_ref` at all) just means no ticket
  # section in the prompt, never a failed review. Mirrors
  # `Arbiter.Worker.Dispatch.fetch_tracker_context/2`.
  defp maybe_put_tracker_context(state, opts, workspace) do
    case fetch_tracker_context(opts, workspace) do
      nil -> state
      ctx -> Map.put(state, :tracker_context, ctx)
    end
  end

  defp fetch_tracker_context(opts, workspace) do
    with ref when is_binary(ref) and ref != "" <- string_opt(opts, :tracker_context_ref),
         type <- tracker_context_type(opts, workspace),
         true <- type not in [nil, :none] do
      adapter = Arbiter.Trackers.for_type(type)

      Arbiter.Trackers.with_workspace(type, workspace, fn ->
        case adapter.fetch(ref) do
          {:ok, raw} ->
            %{
              ref: ref,
              type: type,
              title: adapter.extract_title(raw),
              description: adapter.extract_description(raw)
            }

          {:error, reason} ->
            Logger.warning(
              "ExternalReview: failed to fetch tracker context #{type}:#{ref}: #{inspect(reason)}"
            )

            nil
        end
      end)
    else
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("ExternalReview: error fetching tracker context: #{Exception.message(e)}")
      nil
  end

  defp tracker_context_type(opts, workspace) do
    case Map.get(opts, :tracker_context_type) do
      t when is_atom(t) and not is_nil(t) ->
        t

      t when is_binary(t) and t != "" ->
        try do
          String.to_existing_atom(t)
        rescue
          ArgumentError -> nil
        end

      _ ->
        workspace_tracker_type(workspace)
    end
  end

  defp workspace_tracker_type(%Workspace{} = ws), do: Arbiter.Trackers.workspace_type(ws)
  defp workspace_tracker_type(_ws), do: nil

  # Resolve the engagement's automation mode: an explicit override wins,
  # otherwise the workspace review_automation policy against the actual PR author.
  # A report-only review always yields a :report_only engagement so re-reviews
  # stay report-only.
  defp resolve_automation(opts, workspace, pr_author, rig_name) do
    config = workspace_config(workspace)

    cond do
      Map.get(opts, :report_only) == true ->
        :report_only

      mode = ReviewAutomation.normalize(Map.get(opts, :automation)) ->
        mode

      true ->
        ReviewAutomation.resolve(config, pr_author, rig_name)
    end
  end

  # PR head SHA + author at review time, via the adapter's get/1. Best-effort:
  # {nil, nil} when the adapter can't answer (the engagement still forms; the
  # first ReviewPatrol tick records the head as a first sighting).
  defp fetch_pr_baseline(adapter, mr_ref) do
    if function_exported?(adapter, :get, 1) do
      case safe_call(fn -> adapter.get(mr_ref) end) do
        {:ok, %{} = pr} -> {Map.get(pr, :head_sha), Map.get(pr, :author)}
        _ -> {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  # Current high-watermark comment id across the PR's review threads, as a string
  # (matching how ReviewPatrol stores/reads the cursor). nil when unavailable —
  # ReviewPatrol then treats every author reply as new (conservative).
  defp fetch_comment_watermark(adapter, mr_ref) do
    if function_exported?(adapter, :list_open_review_threads, 1) do
      case safe_call(fn -> adapter.list_open_review_threads(mr_ref) end) do
        {:ok, threads} when is_list(threads) -> max_comment_id(threads)
        _ -> nil
      end
    else
      nil
    end
  end

  defp max_comment_id(threads) do
    ids =
      for thread <- threads,
          comment <- Map.get(thread, :comments) || [],
          is_integer(comment[:id]),
          do: comment[:id]

    case ids do
      [] -> nil
      _ -> ids |> Enum.max() |> Integer.to_string()
    end
  end

  defp string_opt(opts, key) do
    case Map.get(opts, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # ---- audit record persistence (bd-31fh9e) --------------------------------

  # Insert a :running record immediately when a review is dispatched or started.
  # Returns the record struct on success, nil on any error (best-effort — never
  # fails the review itself). The record carries started_at so in-flight reviews
  # are visible on the dashboard.
  defp create_review_record(%{mr_ref: mr_ref, workspace: workspace} = prepared, opts) do
    ws_id = workspace && workspace.id

    report_only = Map.get(opts, :report_only, false)

    attrs = %{
      pr_ref: mr_ref,
      pr: Map.get(prepared, :pr),
      workspace_id: ws_id,
      strategy: to_string(prepared.strategy),
      link: prepared.link,
      status: :running,
      mode: if(report_only, do: :report_only, else: :auto),
      greenlight_status: if(report_only, do: :pending, else: nil),
      dispatched_by: string_opt(opts, :dispatched_by),
      started_at: DateTime.utc_now()
    }

    case Ash.create(Record, attrs) do
      {:ok, record} ->
        broadcast_review_event(ws_id, :running, record)
        record

      {:error, _} ->
        nil
    end
  rescue
    _ -> nil
  end

  defp create_review_record(_, _), do: nil

  # Update the record to :completed or :failed once the workflow finishes.
  # Best-effort — a failure here never surfaces to the caller.
  defp complete_review_record(nil, _status, _result), do: :ok

  defp complete_review_record(%Record{} = record, status, result) do
    findings_list = Map.get(result, :findings_list) || []
    finding_count = Map.get(result, :findings)
    verdict = Map.get(result, :verdict)
    engagement_id = Map.get(result, :engagement)
    usage = Map.get(result, :check_usage) || %{}
    report_only = Map.get(result, :report_only, false)

    attrs =
      %{
        status: status,
        verdict: verdict,
        finding_count: finding_count,
        findings_summary: findings_summary(findings_list),
        engagement_id: engagement_id && to_string(engagement_id),
        completed_at: DateTime.utc_now(),
        model: Map.get(usage, :model),
        cost_usd: Map.get(usage, :cost_usd),
        tokens_in: Map.get(usage, :tokens_in),
        tokens_out: Map.get(usage, :tokens_out)
      }
      |> maybe_put_proposed(report_only, Map.get(result, :proposed_comments) || [])

    case Ash.update(record, attrs, action: :complete) do
      {:ok, updated} ->
        broadcast_review_event(record.workspace_id, status, updated)
        :ok

      {:error, _} ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # Broadcast an ExternalReview lifecycle transition on the workspace (and
  # global) `/events` stream (bd-6f9u6z), so a live coordinator subscriber
  # sees running/completed/failed without polling the audit list. Best-effort:
  # `Arbiter.Events.broadcast/3` itself swallows PubSub failures.
  defp broadcast_review_event(ws_id, status, %Record{} = record) when is_binary(ws_id) do
    Arbiter.Events.broadcast(ws_id, "external_review", %{
      status: to_string(status),
      pr_ref: record.pr_ref,
      verdict: record.verdict,
      finding_count: record.finding_count,
      mode: record.mode,
      review_record_id: record.id,
      engagement_id: record.engagement_id
    })
  end

  defp broadcast_review_event(_ws_id, _status, _record), do: :ok

  defp findings_summary([]), do: nil

  defp findings_summary(findings) when is_list(findings) do
    lines =
      findings
      |> Enum.map(fn f ->
        file = f[:file] || f["file"] || "?"
        line = f[:line] || f["line"]
        sev = f[:severity] || f["severity"] || "info"
        msg = f[:message] || f["message"] || ""
        loc = if line, do: "#{file}:#{line}", else: file
        "[#{sev}] #{loc} — #{msg}"
      end)
      |> Enum.take(20)
      |> Enum.join("\n")

    if String.length(lines) > 500, do: String.slice(lines, 0, 497) <> "…", else: lines
  end

  defp findings_summary(_), do: nil

  # ---- usage ledger ---------------------------------------------------------
  #
  # Write a Usage.Event row so external reviews appear in the usage ledger
  # alongside worker-driven reviews. Best-effort: failure here never surfaces.
  # The `task_id` field (allow_nil? false in the schema) carries the review
  # record id prefixed with "ext:" so ledger queries can distinguish these rows.

  defp write_usage_event(record, prepared, result) do
    usage = Map.get(result, :check_usage) || %{}
    model = Map.get(usage, :model)

    task_id =
      cond do
        record && record.id -> "ext:#{record.id}"
        true -> "ext:#{String.slice(prepared.mr_ref, 0, 250)}"
      end

    attrs = %{
      task_id: task_id,
      workspace_id: prepared.workspace && to_string(prepared.workspace.id),
      step: :review,
      model: model,
      provider: provider_for(model),
      tokens_in: Map.get(usage, :tokens_in),
      tokens_out: Map.get(usage, :tokens_out),
      cost_usd: Map.get(usage, :cost_usd),
      duration_ms: Map.get(usage, :duration_ms),
      session_id: Map.get(usage, :session_id),
      occurred_at: DateTime.utc_now()
    }

    case Ash.create(Arbiter.Usage.Event, attrs) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ExternalReview: usage event write failed for #{prepared.mr_ref}: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    _ -> :ok
  end

  defp provider_for(nil), do: nil

  defp provider_for(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "claude") -> "claude"
      String.starts_with?(model, "gemini") -> "gemini"
      String.contains?(model, "gpt") -> "openai"
      true -> "other"
    end
  end

  defp provider_for(_), do: nil

  # ---- workspace resolution ------------------------------------------------
  #
  # nil → the installation default (the lone workspace, else the one named
  # "default"); a string → a workspace id, then a workspace name. Mirrors the
  # resolution `Arbiter.MCP.Tools` uses for workspace-agnostic coordinator tools.

  defp resolve_workspace(nil), do: default_workspace()

  defp resolve_workspace(ref) when is_binary(ref) and ref != "" do
    with :error <- workspace_by_id(ref),
         :error <- workspace_by_name(ref) do
      {:error, {:workspace, "workspace #{inspect(ref)} not found"}}
    end
  end

  defp resolve_workspace(_), do: default_workspace()

  defp default_workspace do
    case Ash.read!(Workspace) do
      [%Workspace{} = ws] ->
        {:ok, ws}

      [] ->
        {:error, {:workspace, "no workspaces exist on this installation"}}

      many ->
        case Enum.find(many, &(&1.name == "default")) do
          %Workspace{} = ws -> {:ok, ws}
          nil -> {:error, {:workspace, "multiple workspaces; pass a workspace name or id"}}
        end
    end
  rescue
    e -> {:error, {:workspace, "could not load workspaces: #{Exception.message(e)}"}}
  end

  defp workspace_by_id(ref) do
    case Ash.get(Workspace, ref) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp workspace_by_name(ref) do
    case Workspace |> Ash.Query.filter(name == ^ref) |> Ash.read_one() do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # ---- repo path resolution ------------------------------------------------
  #
  # Map a repo name to its local checkout via the workspace `repo_paths` (legacy
  # `rig_paths`) config, falling back to the global `:arbiter, :repo_paths` app
  # env — the same lookup order `Arbiter.Worker.Dispatch` uses. nil when no repo
  # was named or it isn't mapped (a bare PR number then can't derive owner/repo
  # and a full PR URL is required).

  defp resolve_repo_path(_workspace, nil), do: nil
  defp resolve_repo_path(_workspace, ""), do: nil

  defp resolve_repo_path(%Workspace{config: config}, repo) when is_binary(repo) do
    from_config =
      RepoConfig.repo_path_from_config(
        get_in(config || %{}, ["repo_paths", repo]) || get_in(config || %{}, ["rig_paths", repo])
      )

    from_config || application_repo_path(repo)
  end

  defp application_repo_path(repo) do
    :arbiter
    |> Application.get_env(:repo_paths, %{})
    |> Map.get(repo)
    |> RepoConfig.repo_path_from_config()
  end
end
