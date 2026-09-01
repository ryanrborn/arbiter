defmodule Arbiter.MCP.Tools do
  @moduledoc """
  The `Arbiter.MCP` tool handlers — the agent-native route back into the domain.
  Each handler calls Ash directly (the same actions the REST controllers and
  `arb` subcommands take) and returns plain, JSON-friendly maps.

  Phase 1 ships the read tools plus the one narrowed worker write
  (`task_update_progress`); Phase 2 adds the coordinator-only mutating tools —
  `task_create` / `task_update` / `task_close` / `task_reopen`, `dep_add` /
  `dep_remove` (grouping/epics use a `parent_of` edge), the `worker_*` lifecycle family
  (`worker_dispatch` / `worker_resume` / `worker_review` / `worker_stop` /
  `worker_list`), `message_send`, `notify_list`, the `tracker_*` bridge
  (`tracker_claim` / `tracker_sync`), `workspace_list`, and `usage_summarize`
  (see `docs/mcp-server-design.md` §8). The worker-dispatch tools
  (`worker_dispatch` / `worker_resume` / `worker_review`) carry the
  dispatch-recursion guardrail (`can_dispatch` + `depth`, §4.3).

  Handlers take `(scope, arguments)` where `scope` is an `Arbiter.MCP.Scope` and
  `arguments` is the decoded `tools/call` arguments object (string keys). They
  return:

    * `{:ok, map}` — structured result (serialized to `structuredContent`);
    * `{:error, {:unauthorized, msg}}` — a scope violation (the transport maps it
      to a JSON-RPC error, per `docs/mcp-server-design.md` §4.2);
    * `{:error, {:not_found | :invalid, msg}}` — an operational failure (returned
      as an `isError: true` tool result so the agent gets a usable message).

  Tier-level visibility (which tier may call which tool) is enforced upstream in
  `Arbiter.MCP.Catalog`; these handlers enforce the *data-level* rules —
  own-task and workspace isolation — via `Arbiter.MCP.Scope`.

  Most handlers live directly on this module, but six tool groups are split into
  submodules to keep this file a manageable size — this module `defdelegate`s
  their public functions so `Arbiter.MCP.Catalog`'s `&Tools.function/2` captures
  and every existing caller keep working unchanged:

    * `Arbiter.MCP.Tools.Skills` — `skill_*`
    * `Arbiter.MCP.Tools.LoopPending` — `loop_pending_*`
    * `Arbiter.MCP.Tools.Task` — `task_show` / `task_ready` / `task_update_progress` /
      `task_create` / `task_update` / `task_close` / `task_reopen` /
      `task_sync_upstream_close` / `dep_add` / `dep_remove`
    * `Arbiter.MCP.Tools.Workspace` — `workspace_show` / `workspace_config_*` /
      `installation_config_*`
    * `Arbiter.MCP.Tools.Messaging` — `inbox_check` / `coordinator_inbox` /
      `message_send` / `notify_list`
    * `Arbiter.MCP.Tools.Worker` — the `worker_*` lifecycle family, `run_log_list`,
      `transcript_capture_stats`

  This module still owns the generic arg/serialization helpers those submodules
  call back into (`fetch_string`, `authorized_workspace`, `serialize_task_summary`,
  etc), plus every tool group not split out above.
  """

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Claim
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.MCP.Scope
  alias Arbiter.Trackers
  alias Arbiter.Usage
  alias Arbiter.Workflows.Conductor
  alias Arbiter.Workflows.ConductorSupervisor

  require Ash.Query
  require Logger

  # ---- quota_get ----------------------------------------------------------

  @doc """
  Current quota state for the scope's workspace. Resolution mirrors
  `workspace_show`.

  This is a pure DB read (bd-ajh7bd): every provider's figures are read from the
  persisted quota tables, kept fresh by the background probes
  (`Arbiter.Quota.RefreshProbe` for Claude's header capture,
  `Arbiter.Quota.CloudProbe` for Codex / Gemini CLI / Antigravity and Anthropic's
  secondary `/api/oauth/usage` layer). Nothing here fetches live, so there's no
  request-time latency or rate-limit exposure.

  `claude` is the latest captured snapshot (`nil` until the first proxied
  request), including the per-model weekly + `extra_usage` overage layer when the
  oauth-usage probe has run. `codex` is `nil` with a `codex_message` until the
  Codex probe has stored a snapshot (i.e. the `codex` CLI is authenticated on
  this host). `gemini` / `antigravity` are the persisted per-model Cloud Code
  Assist snapshots (`nil` until the Gemini CLI is authenticated and probed).
  """
  @spec quota_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def quota_get(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      codex = Arbiter.Quota.Codex.serialize_latest(ws_id)

      {:ok,
       %{
         claude: Arbiter.Quota.serialize(ws_id),
         codex: codex,
         codex_message: Arbiter.Quota.codex_absence_message(codex),
         gemini: Arbiter.Quota.CloudCode.serialize_latest(ws_id, "gemini_cli"),
         antigravity: Arbiter.Quota.CloudCode.serialize_latest(ws_id, "antigravity")
       }}
    end
  end

  # ---- external_review_list -----------------------------------------------

  @doc """
  List recent ExternalReview audit records for a workspace (bd-31fh9e, bd-bs5b12).
  Coordinator only. Returns records newest-first wrapped under the :external_reviews key
  (consistent with other MCP list tools: tasks, workers, skills). Note: the REST
  endpoint `GET /api/external_reviews` uses the :data key instead — this deliberate
  asymmetry is intentional (Option 3 in bd-bs5b12): each transport follows its own
  convention for consistency within that transport. Optional `limit` (default 20,
  max 200), `status` filter, and `workspace` (resolved the same way as
  `worker_list`/`task_ready` — explicit arg, then the installation default).
  """
  @spec external_review_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def external_review_list(%Scope{} = scope, args) do
    require Ash.Query
    alias Arbiter.Reviews.Record, as: ExternalReviewRecord

    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, limit} <- parse_bounded_limit(args, "limit", 20, 200),
         {:ok, status} <- optional_enum(args, "status", ExternalReviewRecord.statuses()) do
      records =
        ExternalReviewRecord
        |> Ash.Query.filter(workspace_id == ^ws_id)
        |> then(fn q ->
          if status, do: Ash.Query.filter(q, status == ^status), else: q
        end)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()
        |> Enum.map(&serialize_external_review/1)

      {:ok, %{external_reviews: records, count: length(records)}}
    end
  rescue
    e -> {:error, {:internal, "external_review_list failed: #{Exception.message(e)}"}}
  end

  # ---- external_review_show ------------------------------------------------

  @doc """
  Fetch a single ExternalReview audit record by `record_id` (bd-dmy4pk), including
  its full `proposed_comments` — so a report_only review's findings can be read
  before `review_greenlight`. Coordinator only. Workspace-agnostic: looked up
  directly by id, with no workspace filter, since the caller already has the
  specific record id (e.g. from a dispatch response or `external_review_list`).

  Also reports this review's durable-corpus state (bd-7efini):
  `transcript_exists`, `prompt_exists`, `transcript_line_count`,
  `tool_use_count` and `tools_used` — the same "is it retrievable, and how
  big" signal `run_log_list` gives a regular worker run. Fetch the corpus
  itself with `external_review_transcript`. The list tool deliberately does
  NOT carry these: they cost a disk read per record.
  """
  @spec external_review_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def external_review_show(%Scope{} = _scope, args) do
    alias Arbiter.Reviews.Record, as: ExternalReviewRecord

    with {:ok, record_id} <- require_string(args, "record_id") do
      case Ash.get(ExternalReviewRecord, record_id) do
        {:ok, %ExternalReviewRecord{} = record} ->
          {:ok, serialize_external_review(record, proposed_comments: true, transcript: true)}

        _ ->
          {:error, {:not_found, "no external review record found for #{record_id}"}}
      end
    end
  rescue
    e -> {:error, {:internal, "external_review_show failed: #{Exception.message(e)}"}}
  end

  # ---- external_review_transcript ------------------------------------------

  @doc """
  Full durable corpus of one external review (bd-7efini, #1425): the composed
  prompt it was given, the raw `stream-json` transcript its reviewer emitted,
  and every tool call in that transcript paired with the result it returned.

  This is `worker_log`'s counterpart for a review. An external review is not
  task-linked — it has no `Arbiter.Workers.Run` row — so it can't be reached
  through `run_log_list`/`worker_log`'s task-scoped lookup; it is keyed on its
  own `Arbiter.Reviews.Record` id instead (see `Arbiter.Reviews.Transcript`).

  Coordinator only. Workspace-agnostic, like `external_review_show`.

    * `record_id` (required) — the review to read.
    * `tail` — return only the last N transcript lines (`truncated: true` when
      lines were dropped). Omit for the whole transcript; a tool-heavy review
      runs to thousands of JSONL lines.
    * `include_prompt` — set false to skip the (large) prompt.

  `exists` distinguishes "never captured" (a review that predates capture, or
  whose reviewer produced nothing) from "captured but empty".
  """
  @spec external_review_transcript(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def external_review_transcript(%Scope{} = _scope, args) do
    alias Arbiter.Reviews.Record, as: ExternalReviewRecord
    alias Arbiter.Reviews.Transcript

    with {:ok, record_id} <- require_string(args, "record_id"),
         {:ok, tail} <- optional_positive_integer(args, "tail") do
      case Ash.get(ExternalReviewRecord, record_id) do
        {:ok, %ExternalReviewRecord{} = record} ->
          # One read + one decode pass for summary, lines and tool uses alike.
          corpus = Transcript.corpus(record.id, preview: Transcript.default_preview())
          summary = corpus.summary
          {lines, truncated} = Transcript.tail(corpus.lines, tail)

          prompt =
            if fetch_optional_bool!(args, "include_prompt") == false do
              nil
            else
              case Transcript.prompt(record.id) do
                {:ok, prompt} -> prompt
                {:error, _} -> nil
              end
            end

          {:ok,
           %{
             record_id: record.id,
             pr_ref: record.pr_ref,
             pr: record.pr,
             workspace_id: record.workspace_id,
             status: record.status,
             model: record.model,
             path: summary.path,
             prompt_path: summary.prompt_path,
             exists: summary.exists,
             prompt_exists: summary.prompt_exists,
             prompt: prompt,
             line_count: summary.line_count,
             lines: lines,
             truncated: truncated,
             tool_use_count: summary.tool_use_count,
             tools_used: summary.tools_used,
             tool_uses: corpus.tool_uses
           }}

        _ ->
          {:error, {:not_found, "no external review record found for #{record_id}"}}
      end
    end
  rescue
    e -> {:error, {:internal, "external_review_transcript failed: #{Exception.message(e)}"}}
  end

  # ---- review_gate_rounds_list ---------------------------------------------

  @doc """
  List `Arbiter.ReviewGate.Round` rows for a task (bd-aqyjuc): one row per
  ReviewGate reviewer or implementer pass, oldest-first, so a round-1 rejection
  and a round-2 approval surface as two distinct rows rather than being
  collapsed into the task's terminal outcome. Coordinator only. Requires
  `task_id`. Backfill is out of scope — rows only exist for ReviewGate runs
  from 2026-07-28 onward.

  Optional `limit` (bd-dp7hiw) caps the response to the most recent N rounds
  (still returned oldest-first) so a task with many rounds/resumes doesn't
  force pulling the entire history just to see the latest one or two.
  Omitting it preserves the original full-history behavior; `total_count`
  always reports how many rounds exist regardless of `limit`.
  """
  @spec review_gate_rounds_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def review_gate_rounds_list(%Scope{} = _scope, args) do
    require Ash.Query
    alias Arbiter.ReviewGate.Round

    with {:ok, task_id} <- require_string(args, "task_id"),
         {:ok, limit} <- optional_positive_integer(args, "limit") do
      all_rounds =
        Round
        |> Ash.Query.filter(task_id == ^task_id)
        |> Ash.Query.sort(round: :asc, inserted_at: :asc)
        |> Ash.read!()

      rounds =
        all_rounds
        |> take_last(limit)
        |> Enum.map(&serialize_review_gate_round/1)

      {:ok, %{rounds: rounds, count: length(rounds), total_count: length(all_rounds)}}
    end
  rescue
    e -> {:error, {:internal, "review_gate_rounds_list failed: #{Exception.message(e)}"}}
  end

  defp take_last(list, nil), do: list
  defp take_last(list, n), do: Enum.take(list, -n)

  defp optional_positive_integer(args, key) do
    with {:ok, n} <- optional_integer(args, key) do
      cond do
        is_nil(n) -> {:ok, nil}
        n > 0 -> {:ok, n}
        true -> {:error, {:invalid, "`#{key}` must be a positive integer"}}
      end
    end
  end

  defp serialize_review_gate_round(%Arbiter.ReviewGate.Round{} = r) do
    %{
      id: r.id,
      task_id: r.task_id,
      run_id: r.run_id,
      round: r.round,
      role: r.role,
      verdict: r.verdict,
      findings: r.findings,
      finding_count: r.finding_count,
      reviewer_model: r.reviewer_model,
      reviewer_tier: r.reviewer_tier,
      cost_usd: r.cost_usd,
      converged: r.converged,
      inserted_at: iso(r.inserted_at)
    }
  end

  # ---- review_greenlight --------------------------------------------------

  @doc """
  Greenlight a report-only review (bd-36qzgx): post the coordinator-approved
  subset of a review's proposed comments to the PR — and nothing else.
  Coordinator only. Backs onto `Arbiter.Reviews.ExternalReview.greenlight/1`.
  """
  @spec review_greenlight(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def review_greenlight(%Scope{} = scope, args) do
    with :ok <- ensure_can_dispatch(scope),
         {:ok, record_id} <- require_string(args, "record_id"),
         {:ok, select} <- parse_select(args) do
      opts =
        [record_id: record_id, repo: fetch_string(args, "repo")]
        |> maybe_put_kw(:select, select)
        |> maybe_put_kw(:post_verdict, fetch_optional_bool!(args, "post_verdict"))

      case Arbiter.Reviews.ExternalReview.greenlight(opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, {:invalid, Arbiter.Reviews.ExternalReview.describe_error(reason)}}
      end
    end
  end

  # `select` may be omitted (→ nil, meaning all), the string "all", or a JSON
  # array of zero-based indices. Anything else is rejected.
  defp parse_select(args) do
    case Map.get(args, "select") do
      nil ->
        {:ok, nil}

      "all" ->
        {:ok, :all}

      list when is_list(list) ->
        if Enum.all?(list, &(is_integer(&1) and &1 >= 0)) do
          {:ok, list}
        else
          {:error, {:invalid, "select must be \"all\" or a list of non-negative integers"}}
        end

      _ ->
        {:error, {:invalid, "select must be \"all\" or a list of non-negative integers"}}
    end
  end

  defp fetch_optional_bool!(args, key) do
    case Map.get(args, key) do
      b when is_boolean(b) -> b
      _ -> nil
    end
  end

  defp serialize_external_review(%Arbiter.Reviews.Record{} = r, opts \\ []) do
    proposed = r.proposed_comments || []

    base = %{
      id: r.id,
      pr_ref: r.pr_ref,
      pr: r.pr,
      workspace_id: r.workspace_id,
      strategy: r.strategy,
      link: r.link,
      status: r.status,
      mode: r.mode,
      greenlight_status: r.greenlight_status,
      proposed_count: length(proposed),
      # bd-887swr: in/out-of-diff breakdown of the proposed comments, so a
      # coordinator can see how many are postable without fetching the full
      # `proposed_comments` list (external_review_show) or diffing the PR by
      # hand. Comments persisted before the "in_diff" label existed count
      # toward neither.
      in_diff_count: Enum.count(proposed, &(&1["in_diff"] == true)),
      out_of_diff_count: Enum.count(proposed, &(&1["in_diff"] == false)),
      verdict: r.verdict,
      finding_count: r.finding_count,
      findings_summary: r.findings_summary,
      model: r.model,
      cost_usd: r.cost_usd,
      tokens_in: r.tokens_in,
      tokens_out: r.tokens_out,
      dispatched_by: r.dispatched_by,
      engagement_id: r.engagement_id,
      failure_stage: r.failure_stage,
      failure_reason: r.failure_reason,
      started_at: iso_dt(r.started_at),
      completed_at: iso_dt(r.completed_at)
    }

    base =
      if Keyword.get(opts, :proposed_comments, false) do
        Map.put(base, :proposed_comments, proposed)
      else
        base
      end

    # bd-7efini: capture state of the review's durable corpus. Show-only —
    # each call stats/reads files, which a 200-record list must not do.
    if Keyword.get(opts, :transcript, false) do
      summary = Arbiter.Reviews.Transcript.summary(r.id)

      Map.merge(base, %{
        transcript_exists: summary.exists,
        transcript_path: summary.path,
        transcript_line_count: summary.line_count,
        prompt_exists: summary.prompt_exists,
        tool_use_count: summary.tool_use_count,
        tools_used: summary.tools_used
      })
    else
      base
    end
  end

  # internal — shared by Arbiter.MCP.Tools.Worker (also used by external_review_list)
  def parse_bounded_limit(args, key, default, max) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      n when is_integer(n) and n > 0 -> {:ok, min(n, max)}
      _ -> {:error, {:invalid, "#{key} must be a positive integer (max #{max})"}}
    end
  end

  defp iso_dt(nil), do: nil
  defp iso_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # ---- task_list ----------------------------------------------------------

  @doc """
  List tasks in the scope's workspace with optional filters. Coordinator only.
  Accepts optional `status`, `priority`, and `issue_type` filters. Always
  scoped to the coordinator's workspace. Backs onto `Ash.read(Issue, ...)`.
  """
  @spec task_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, status} <- optional_enum(args, "status", Issue.statuses()),
         {:ok, issue_type} <- optional_enum(args, "issue_type", Issue.issue_types()),
         {:ok, priority} <- optional_integer(args, "priority") do
      query =
        Issue
        |> Ash.Query.filter(workspace_id == ^ws_id)
        |> maybe_filter_status(status)
        |> maybe_filter_issue_type(issue_type)
        |> maybe_filter_priority(priority)

      tasks =
        query
        |> Ash.read!()
        |> Enum.map(&serialize_task_summary/1)

      {:ok, %{tasks: tasks, count: length(tasks)}}
    end
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, status),
    do: Ash.Query.filter(query, status == ^status)

  defp maybe_filter_issue_type(query, nil), do: query

  defp maybe_filter_issue_type(query, issue_type),
    do: Ash.Query.filter(query, issue_type == ^issue_type)

  defp maybe_filter_priority(query, nil), do: query

  defp maybe_filter_priority(query, priority),
    do: Ash.Query.filter(query, priority == ^priority)

  # ---- usage_summarize ----------------------------------------------------

  @doc """
  Roll up the token/cost usage ledger for the scope's workspace. Coordinator
  only. `by` is required (one of `Arbiter.Usage.valid_groupings/0`, or the
  deprecated `campaign` alias for `epic`); `since` (ISO-8601) and `limit` are
  optional. `workspace_id` is forced to the scope's workspace. Backs onto
  `Arbiter.Usage.summarize/1`.

  Also surfaces a `warnings` list (bd-2fzwlc) when a provider's rows are
  wholly zero-token over the same `since`/workspace window — the same
  blindness `Arbiter.Loop.Analysis` flags in the loop report, so a
  coordinator reading this tool directly gets the same signal.
  """
  @spec usage_summarize(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def usage_summarize(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, by} <- require_enum(args, "by", Usage.acceptable_groupings()),
         {:ok, since} <- optional_datetime(args, "since"),
         {:ok, limit} <- optional_integer(args, "limit") do
      opts =
        [by: by, workspace_id: ws_id]
        |> maybe_put_kw(:since, since)
        |> maybe_put_kw(:limit, limit)

      zero_token_opts =
        [workspace_id: ws_id] |> maybe_put_kw(:since, since)

      with {:ok, rollups} <- Usage.summarize(opts),
           {:ok, flagged} <- Usage.zero_token_providers(zero_token_opts) do
        {:ok,
         %{
           by: Atom.to_string(Usage.normalize_by(by)),
           rollups: rollups,
           count: length(rollups),
           warnings: Enum.map(flagged, &zero_token_warning/1)
         }}
      else
        {:error, reason} -> {:error, {:invalid, "usage_summarize failed: #{inspect(reason)}"}}
      end
    end
  end

  defp zero_token_warning(%{provider: provider, rows: rows}) do
    "⚠ #{provider}: all #{rows} usage_events row(s) in this window carry zero tokens — " <>
      "likely a stream parser silently dropping usage rather than a genuinely free provider."
  end

  # ---- tracker_claim ------------------------------------------------------

  @doc """
  Claim an external tracker issue into a task (`arb claim`). Coordinator only.
  Fetches the issue by `ref` via the workspace's tracker, verifies it is
  assigned to the workspace user (the claim signal; skip with `force: true`),
  and creates a linked task. Idempotent — returns the existing task if one
  already references the issue. Backs onto `Arbiter.Tasks.Claim.claim/3`.
  """
  @spec tracker_claim(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def tracker_claim(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, ref} <- require_string(args, "ref"),
         {:ok, force} <- fetch_bool(args, "force", false),
         {:ok, workspace} <- fetch_workspace(ws_id) do
      case Claim.claim(workspace, ref, force: force) do
        {:ok, status, task} -> {:ok, Map.put(serialize_task(task), :claim_status, to_str(status))}
        {:error, reason} -> {:error, {:invalid, claim_error_message(reason)}}
      end
    end
  end

  # ---- tracker_sync -------------------------------------------------------

  @doc """
  Reconcile the workspace's tasks against its external tracker (`arb sync`): open
  assigned issues with no task get a linked task; open tasks whose issue is
  closed upstream or reassigned away get closed (an issue that is merely
  unassigned is left alone — bd-83ojwi); closed tasks whose close was meant to
  propagate upstream — a recorded close intent (bd-bsco7f), or for rows closed
  before that was recorded a non-blank `pr_ref` (bd-83ojwi) — but whose tracker
  issue is still open are reported as `drift` (bd-2wilou — a close that never
  propagated upstream). `task`-type and `review_only` tasks are exempt: they
  are expected to close with their ticket still open.
  Drift entries are report-only and never mutate the local task.
  Coordinator only. With `dry: true` the plan is returned without acting.
  No-ops cleanly when the tracker does not support reconciliation. Backs onto
  `Arbiter.Tasks.Claim.plan/1` + `apply_plan/2`.
  """
  @spec tracker_sync(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def tracker_sync(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, dry} <- fetch_bool(args, "dry", false),
         {:ok, workspace} <- fetch_workspace(ws_id),
         {:ok, plan} <- claim_plan(workspace) do
      actions = Enum.map(plan, &serialize_claim_action/1)

      if dry do
        {:ok, %{applied: false, actions: actions, count: length(actions)}}
      else
        {:ok, results} = Claim.apply_plan(workspace, plan)

        {:ok,
         %{
           applied: true,
           actions: actions,
           results: Enum.map(results, &serialize_claim_result/1),
           count: length(actions)
         }}
      end
    end
  end

  # ---- workspace_list -----------------------------------------------------

  @doc """
  List the configured workspaces (id, name, prefix, tracker type). Coordinator
  only. This is a deliberate exception to the per-call workspace isolation every
  other tool enforces: it is a read-only *enumeration* of non-sensitive summary
  fields (no config, no security posture — those stay behind `workspace_show`
  for the bound workspace), the discovery surface the operator/coordinator needs
  to know which workspaces exist. Backs onto `Ash.read(Workspace)`.
  """
  @spec workspace_list(Scope.t(), map()) :: {:ok, map()}
  def workspace_list(%Scope{}, _args) do
    workspaces =
      Workspace
      |> Ash.read!()
      |> Enum.map(&serialize_workspace_summary/1)

    {:ok, %{workspaces: workspaces, count: length(workspaces)}}
  end

  # ---- queue_resume -------------------------------------------------------

  @doc """
  Resume a paused graph branch by re-dispatching the failed task that blocked
  it (C5 of #482). Coordinator only.

  Searches all running Conductors for one that has `task_id` in its failed
  set and calls `Conductor.resume/2` on it. On success the task is
  re-dispatched and its downstream branch is unpaused.

  Returns `%{resumed: true, task_id: task_id}` on success, or an error if no
  conductor holds the task as failed.
  """
  @spec queue_resume(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def queue_resume(%Scope{} = _scope, args) do
    with {:ok, task_id} <- require_string(args, "task_id") do
      case Arbiter.Workflows.Conductor.resume_task(task_id) do
        :ok ->
          {:ok, %{resumed: true, task_id: task_id}}

        {:error, :not_found} ->
          {:error, {:not_found, "task #{task_id} is not in any running conductor's failed set"}}

        {:error, :not_member} ->
          {:error, {:not_found, "task #{task_id} is not a member of a running graph"}}

        {:error, :not_failed} ->
          {:error, {:invalid, "task #{task_id} has not failed — nothing to resume"}}

        {:error, :dispatch_failed} ->
          {:error, {:invalid, "dispatch of #{task_id} failed — check worker logs"}}

        {:error, reason} ->
          {:error, {:invalid, "resume failed: #{inspect(reason)}"}}
      end
    end
  end

  # ---- queue_retry_auto_resolve --------------------------------------------

  @doc """
  Re-arm one more auto-resolve attempt on a task's merge Watchdog after it
  has exhausted `max_auto_resolve_attempts` on a `:ci_failed` block and
  parked indefinitely (bd-bspakl).

  Without this, once exhausted there is no supported way to try again short
  of pushing a fix to the branch by hand, outside Arbiter's normal
  worker/review flow. Calls `Arbiter.Worker.Watchdog.retry_auto_resolve/1`,
  which bumps this episode's budget by exactly one attempt and immediately
  re-polls. No cap on how many times a coordinator calls this — but the
  Watchdog itself never re-arms on its own.

  Returns `%{retried: true, task_id: task_id}` on success, or an error if no
  Watchdog is running for the task or it isn't parked on an exhausted
  `:ci_failed` block.
  """
  @spec queue_retry_auto_resolve(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def queue_retry_auto_resolve(%Scope{} = _scope, args) do
    with {:ok, task_id} <- require_string(args, "task_id") do
      case Arbiter.Worker.Watchdog.retry_auto_resolve(task_id) do
        :ok ->
          {:ok, %{retried: true, task_id: task_id}}

        {:error, :not_found} ->
          {:error, {:not_found, "no merge watchdog is currently running for task #{task_id}"}}

        {:error, :not_parked_on_ci_failed} ->
          {:error,
           {:invalid,
            "task #{task_id} is not currently parked on an exhausted :ci_failed block " <>
              "— there is nothing to re-arm"}}
      end
    end
  end

  # ---- repo_list ----------------------------------------------------------

  @doc """
  List registered repos with their paths, sources, active worker counts, and git worktree counts.
  Coordinator only. Mirrors the data from `GET /api/repos` and `arb repo list`.
  """
  @spec repo_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def repo_list(%Scope{}, _args) do
    repos =
      list_repos_impl()
      |> Enum.map(&serialize_repo/1)

    {:ok, %{repos: repos, count: length(repos)}}
  rescue
    e -> {:error, {:internal, "repo_list failed: #{Exception.message(e)}"}}
  end

  # ---- repo_show ----------------------------------------------------------

  @doc """
  Show details for a single repo: path, source, active worker count, and git worktree count.
  Coordinator only. Returns not-found if the repo name does not exist.
  """
  @spec repo_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def repo_show(%Scope{}, args) do
    with {:ok, name} <- require_string(args, "name") do
      repos = list_repos_impl()

      case Enum.find(repos, fn repo -> repo.name == name end) do
        nil -> {:error, {:not_found, "repo #{inspect(name)} not found"}}
        repo -> {:ok, serialize_repo(repo)}
      end
    end
  rescue
    e -> {:error, {:internal, "repo_show failed: #{Exception.message(e)}"}}
  end

  # Get repos using the same logic as the API controller. Imports the logic
  # from ArbiterWeb.Api.RepoController.list_repos/0.
  defp list_repos_impl do
    alias Arbiter.Tasks.RepoConfig
    alias Arbiter.Tasks.Workspace

    workspaces =
      try do
        Ash.read!(Workspace)
      rescue
        _ -> []
      end

    paths_by_repo = collect_repo_paths(workspaces)
    workers_by_repo = group_workers_by_repo()

    paths_by_repo
    |> Map.merge(repos_from_workers(workers_by_repo, paths_by_repo))
    |> Enum.map(fn {name, entry} ->
      path = entry.path

      worktree_count =
        case path do
          nil -> 0
          p when is_binary(p) -> safe_worktree_count(p)
        end

      %{
        name: name,
        path: path,
        source: entry.source,
        workers: Map.get(workers_by_repo, name, 0),
        worktrees: worktree_count
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp collect_repo_paths(workspaces) do
    alias Arbiter.Tasks.RepoConfig

    app_paths =
      :arbiter
      |> Application.get_env(:repo_paths, %{})
      |> Map.new(fn {name, raw} ->
        {name, %{path: RepoConfig.repo_path_from_config(raw), source: "(app)"}}
      end)

    Enum.reduce(workspaces, app_paths, fn ws, acc ->
      ws_repo_paths =
        case ws.config do
          %{"repo_paths" => paths} when is_map(paths) -> paths
          _ -> %{}
        end

      Enum.reduce(ws_repo_paths, acc, fn {name, raw}, acc ->
        Map.put(acc, name, %{path: RepoConfig.repo_path_from_config(raw), source: ws.name})
      end)
    end)
  end

  defp group_workers_by_repo do
    try do
      Arbiter.Worker.list_children()
    rescue
      _ -> []
    end
    |> Enum.reduce(%{}, fn p, acc ->
      repo = p.repo || "(none)"
      Map.update(acc, repo, 1, &(&1 + 1))
    end)
  end

  defp repos_from_workers(workers_by_repo, configured) do
    workers_by_repo
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(configured, &1))
    |> Map.new(fn name -> {name, %{path: nil, source: "(unconfigured)"}} end)
  end

  defp safe_worktree_count(path) do
    Arbiter.Worker.Worktree.list(path) |> length()
  rescue
    _ -> 0
  end

  defp serialize_repo(repo) when is_map(repo) do
    %{
      name: repo.name,
      path: repo.path,
      source: repo.source,
      workers: repo.workers,
      worktrees: repo.worktrees
    }
  end

  # ======================================================================
  # Graph CRUD + lifecycle tools (C7 of #482)
  # ======================================================================

  # ---- graph_create -------------------------------------------------------

  @doc "Create a Graph in the scope's workspace. Coordinator only."
  @spec graph_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def graph_create(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, name} <- require_string(args, "name") do
      attrs =
        %{"name" => name, "workspace_id" => ws_id}
        |> maybe_put("description", fetch_string(args, "description"))

      case Ash.create(Graph, attrs) do
        {:ok, graph} ->
          Logger.info("[graph_create] graph #{graph.id} created in workspace #{ws_id}")
          {:ok, serialize_graph(graph)}

        {:error, err} ->
          {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- graph_add_directive ------------------------------------------------

  @doc "Add a directive (Issue) to a Graph. Coordinator only."
  @spec graph_add_directive(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def graph_add_directive(%Scope{} = scope, args) do
    with {:ok, graph_id} <- require_string(args, "graph_id"),
         {:ok, issue_id} <- require_string(args, "issue_id"),
         {:ok, graph} <- fetch_graph(scope, graph_id),
         {:ok, _issue} <- fetch_task_in_workspace(graph.workspace_id, issue_id) do
      attrs = %{"graph_id" => graph_id, "issue_id" => issue_id}
      attrs = if repo = fetch_string(args, "repo"), do: Map.put(attrs, "repo", repo), else: attrs

      case Ash.create(GraphMember, attrs) do
        {:ok, member} ->
          Logger.info("[graph_add_directive] directive #{issue_id} added to graph #{graph_id}")
          {:ok, %{graph_id: graph_id, issue_id: issue_id, member_id: member.id}}

        {:error, err} ->
          {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- graph_remove_directive ---------------------------------------------

  @doc "Remove a directive (Issue) from a Graph. Idempotent. Coordinator only."
  @spec graph_remove_directive(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def graph_remove_directive(%Scope{} = scope, args) do
    with {:ok, graph_id} <- require_string(args, "graph_id"),
         {:ok, issue_id} <- require_string(args, "issue_id"),
         {:ok, _graph} <- fetch_graph(scope, graph_id) do
      members =
        GraphMember
        |> Ash.Query.filter(graph_id == ^graph_id and issue_id == ^issue_id)
        |> Ash.read!()

      _ = Enum.each(members, &Ash.destroy!/1)

      Logger.info(
        "[graph_remove_directive] directive #{issue_id} removed from graph #{graph_id}, " <>
          "removed: #{length(members)}"
      )

      {:ok, %{graph_id: graph_id, issue_id: issue_id, removed: length(members)}}
    end
  end

  # ---- graph_add_edge -----------------------------------------------------

  @doc """
  Add a dependency edge between two directives for graph ordering / mutual
  exclusion. Coordinator only. `type` is one of `depends_on`, `blocks`,
  `conflicts_with`.
  """
  @spec graph_add_edge(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def graph_add_edge(%Scope{} = scope, args) do
    graph_edge_types = [:depends_on, :blocks, :conflicts_with]

    with {:ok, graph_id} <- require_string(args, "graph_id"),
         {:ok, from_id} <- require_string(args, "from_issue_id"),
         {:ok, to_id} <- require_string(args, "to_issue_id"),
         {:ok, type} <- require_enum(args, "type", graph_edge_types),
         {:ok, graph} <- fetch_graph(scope, graph_id),
         {:ok, _from} <- fetch_task_in_workspace(graph.workspace_id, from_id),
         {:ok, _to} <- fetch_task_in_workspace(graph.workspace_id, to_id) do
      attrs =
        %{"from_issue_id" => from_id, "to_issue_id" => to_id, "type" => type}
        |> maybe_put("notes", fetch_string(args, "notes"))

      case Ash.create(Dependency, attrs) do
        {:ok, dep} ->
          Logger.info(
            "[graph_add_edge] #{type} edge #{from_id}→#{to_id} added for graph #{graph_id}"
          )

          {:ok, serialize_dependency(dep)}

        {:error, err} ->
          {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- graph_start --------------------------------------------------------

  @doc """
  Start a Graph: validate acyclicity, transition `:draft → :running`, and start
  the Conductor. Rejects cyclic graphs with the named cycle. Coordinator only.
  """
  @spec graph_start(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def graph_start(%Scope{} = scope, args) do
    with {:ok, graph_id} <- require_string(args, "graph_id"),
         {:ok, _graph} <- fetch_graph(scope, graph_id) do
      Logger.info("[graph_start] starting graph #{graph_id}")

      case Conductor.kickoff(graph_id) do
        {:ok, _pid} ->
          {:ok, graph} = Ash.get(Graph, graph_id)
          Logger.info("[graph_start] graph #{graph_id} transitioned to #{graph.run_state}")
          {:ok, serialize_graph(graph)}

        {:error, :graph_not_found} ->
          {:error, {:not_found, "graph #{graph_id} not found"}}

        {:error, {:not_draft, state}} ->
          {:error, {:invalid, "graph #{graph_id} is not in draft state (current: #{state})"}}

        {:error, {:cyclic, cycle}} ->
          cycle_str = Enum.join(cycle, " → ")
          {:error, {:invalid, "graph #{graph_id} contains a cycle: #{cycle_str}"}}

        {:error, reason} ->
          {:error, {:invalid, "graph start failed: #{inspect(reason)}"}}
      end
    end
  end

  # ---- graph_pause --------------------------------------------------------

  @doc """
  Pause a running Graph: transition `:running → :paused` and stop its Conductor.
  No new directives are dispatched while paused. Coordinator only.
  """
  @spec graph_pause(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def graph_pause(%Scope{} = scope, args) do
    with {:ok, graph_id} <- require_string(args, "graph_id"),
         {:ok, graph} <- fetch_graph(scope, graph_id) do
      if graph.run_state != :running do
        {:error, {:invalid, "graph #{graph_id} is not running (current: #{graph.run_state})"}}
      else
        case Ash.update(graph, %{run_state: :paused}) do
          {:ok, updated} ->
            ConductorSupervisor.stop_conductor(graph_id)
            Logger.info("[graph_pause] graph #{graph_id} paused")
            {:ok, serialize_graph(updated)}

          {:error, err} ->
            {:error, {:invalid, ash_error_message(err)}}
        end
      end
    end
  end

  # ---- graph_resume -------------------------------------------------------

  @doc """
  Resume a paused Graph: transition `:paused → :running` and start a new
  Conductor to continue dispatching. Coordinator only.
  """
  @spec graph_resume(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def graph_resume(%Scope{} = scope, args) do
    with {:ok, graph_id} <- require_string(args, "graph_id"),
         {:ok, graph} <- fetch_graph(scope, graph_id) do
      if graph.run_state != :paused do
        {:error, {:invalid, "graph #{graph_id} is not paused (current: #{graph.run_state})"}}
      else
        case Ash.update(graph, %{run_state: :running}) do
          {:ok, updated} ->
            ConductorSupervisor.start_conductor(graph_id)
            Logger.info("[graph_resume] graph #{graph_id} resumed")
            {:ok, serialize_graph(updated)}

          {:error, err} ->
            {:error, {:invalid, ash_error_message(err)}}
        end
      end
    end
  end

  # ---- graph_status -------------------------------------------------------

  @doc """
  Return the running/ready/paused/blocked breakdown of a Graph's members.
  Coordinator only.
  """
  @spec graph_status(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def graph_status(%Scope{} = scope, args) do
    with {:ok, graph_id} <- require_string(args, "graph_id"),
         {:ok, graph} <- fetch_graph(scope, graph_id) do
      member_ids =
        GraphMember
        |> Ash.Query.filter(graph_id == ^graph_id)
        |> Ash.read!()
        |> Enum.map(& &1.issue_id)

      member_set = MapSet.new(member_ids)

      member_issues =
        case member_ids do
          [] ->
            []

          ids ->
            Issue
            |> Ash.Query.filter(id in ^ids)
            |> Ash.read!()
        end

      total = length(member_issues)
      by_status = Enum.group_by(member_issues, & &1.status)

      closed_count = length(Map.get(by_status, :closed, []))
      running_count = length(Map.get(by_status, :in_progress, []))

      open_ids =
        by_status
        |> Map.get(:open, [])
        |> Enum.map(& &1.id)
        |> MapSet.new()

      ready_ids =
        [workspace_id: graph.workspace_id]
        |> Issue.ready()
        |> Enum.filter(&MapSet.member?(member_set, &1.id))
        |> Enum.map(& &1.id)
        |> MapSet.new()

      ready_count = MapSet.size(ready_ids)
      blocked_count = MapSet.size(MapSet.difference(open_ids, ready_ids))

      {failed_count, paused_count} = conductor_failure_counts(graph_id, member_set)

      {:ok,
       %{
         graph_id: graph_id,
         run_state: to_str(graph.run_state),
         total: total,
         running: running_count,
         ready: ready_count,
         blocked: blocked_count,
         paused: paused_count,
         failed: failed_count,
         closed: closed_count
       }}
    end
  end

  # ---- scheduler (autopilot) pause/resume --------------------------------

  @doc """
  Pause the board autopilot: stop promoting Ready cards to Running.
  Workers already dispatched continue to completion. Resume with `scheduler_resume`.
  Coordinator only.
  """
  @spec scheduler_pause(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def scheduler_pause(%Scope{} = _scope, _args) do
    case Arbiter.Board.Autopilot.pause() do
      :ok ->
        Logger.info("[scheduler_pause] autopilot paused")
        {:ok, %{paused: true}}

      {:error, reason} ->
        {:error, {:invalid, "pause failed: #{inspect(reason)}"}}
    end
  rescue
    e ->
      {:error, {:invalid, "pause failed: #{inspect(e)}"}}
  catch
    :exit, reason ->
      {:error, {:invalid, "pause failed: process error #{inspect(reason)}"}}
  end

  @doc """
  Resume the board autopilot: start promoting Ready cards to Running again.
  The autopilot must be in paused state. Coordinator only.
  """
  @spec scheduler_resume(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def scheduler_resume(%Scope{} = _scope, _args) do
    case Arbiter.Board.Autopilot.resume() do
      :ok ->
        Logger.info("[scheduler_resume] autopilot resumed")
        {:ok, %{paused: false}}

      {:error, reason} ->
        {:error, {:invalid, "resume failed: #{inspect(reason)}"}}
    end
  rescue
    e ->
      {:error, {:invalid, "resume failed: #{inspect(e)}"}}
  catch
    :exit, reason ->
      {:error, {:invalid, "resume failed: process error #{inspect(reason)}"}}
  end

  @doc """
  Return the current pause state of the board autopilot.
  Coordinator only.
  """
  @spec scheduler_status(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def scheduler_status(%Scope{} = _scope, _args) do
    paused? = Arbiter.Board.Autopilot.paused?()
    {:ok, %{paused: paused?}}
  rescue
    e ->
      {:error, {:invalid, "status check failed: #{inspect(e)}"}}
  catch
    :exit, reason ->
      {:error, {:invalid, "status check failed: process error #{inspect(reason)}"}}
  end

  # ---- shared resolution / fetch -----------------------------------------

  # Resolve + authorize the target task id for this scope from the named arg
  # (default "id"). Worker: own task only; coordinator: id required.
  def resolve_task_id(scope, args, key \\ "id") do
    case Scope.own_task(scope, fetch_string(args, key)) do
      {:ok, id} ->
        {:ok, id}

      {:error, :unauthorized} ->
        {:error, {:unauthorized, "this scope may only act on its own task"}}

      {:error, :missing} ->
        {:error, {:invalid, "`#{key}` is required"}}
    end
  end

  # Fetch a graph, enforcing workspace isolation for the scope.
  defp fetch_graph(%Scope{} = scope, graph_id) when is_binary(graph_id) do
    case Ash.get(Graph, graph_id) do
      {:ok, %Graph{} = graph} ->
        if Scope.same_workspace?(scope, graph.workspace_id),
          do: {:ok, graph},
          else: {:error, {:not_found, "graph #{graph_id} not found"}}

      _ ->
        {:error, {:not_found, "graph #{graph_id} not found"}}
    end
  end

  # Read failed/paused task counts from the running Conductor, if any. A
  # freshly-started Conductor can be mid-dispatch (handle_continue) and
  # unable to service a :state call promptly, so this uses a short timeout
  # and degrades to {0, 0} rather than let a slow/stale Conductor turn
  # graph_status into an unhandled `:exit` (GenServer.call raises `:exit` on
  # timeout, which `rescue` alone does not catch).
  defp conductor_failure_counts(graph_id, member_set) do
    pid = ConductorSupervisor.whereis(graph_id)

    if is_pid(pid) do
      snap = GenServer.call(pid, :state, 1_000)
      failed = snap.failed_ids |> MapSet.intersection(member_set) |> MapSet.size()
      paused = snap.paused_ids |> MapSet.intersection(member_set) |> MapSet.size()
      {failed, paused}
    else
      {0, 0}
    end
  rescue
    _ -> {0, 0}
  catch
    :exit, _ -> {0, 0}
  end

  # Fetch a task and enforce workspace isolation. Honors an optional `workspace`
  # arg (name or id): a workspace-bound scope may only ever reach its own
  # workspace; a workspace-agnostic coordinator either targets the named
  # workspace or, with no arg, infers it from the task itself (entity inference).
  # A task outside the resolved workspace is reported not-found so existence does
  # not leak across workspaces.
  def fetch_task(scope, args, id) do
    with {:ok, target_ws} <- authorized_workspace(scope, args) do
      case Ash.get(Issue, id) do
        {:ok, %Issue{} = issue} ->
          if workspace_match?(issue.workspace_id, target_ws),
            do: {:ok, issue},
            else: {:error, {:not_found, "task #{id} not found"}}

        _ ->
          {:error, {:not_found, "task #{id} not found"}}
      end
    end
  end

  # Fetch a task and require it to live in `ws_id` exactly — the second-endpoint
  # check for dependency tools, so both endpoints of an edge stay in one
  # workspace even for a workspace-agnostic coordinator inferring from the first.
  def fetch_task_in_workspace(ws_id, id) do
    case Ash.get(Issue, id) do
      {:ok, %Issue{workspace_id: ^ws_id} = issue} -> {:ok, issue}
      _ -> {:error, {:not_found, "task #{id} not found"}}
    end
  end

  # A `nil` target means "any workspace" (a workspace-agnostic coordinator that
  # named no workspace — the task's own workspace stands).
  def workspace_match?(_ws, nil), do: true
  def workspace_match?(ws, ws), do: true
  def workspace_match?(_ws, _target), do: false

  # The workspace this call is authorized to operate in, honoring an optional
  # `workspace` arg (name or id). Returns `{:ok, ws_id}` where `ws_id` may be
  # `nil` — meaning the caller is a workspace-agnostic coordinator that named no
  # workspace, so entity inference / the installation default applies downstream.
  #
  # A scope bound to one workspace (every worker; a legacy workspace-bound
  # coordinator) may only ever resolve to its own workspace — naming a different
  # one is `{:error, {:unauthorized, …}}`.
  def authorized_workspace(%Scope{} = scope, args) do
    case fetch_string(args, "workspace") do
      nil ->
        {:ok, scope.workspace_id}

      ref ->
        with {:ok, ws} <- resolve_workspace_ref(ref) do
          cond do
            is_nil(scope.workspace_id) -> {:ok, ws.id}
            scope.workspace_id == ws.id -> {:ok, ws.id}
            true -> {:error, {:unauthorized, "this scope is bound to a single workspace"}}
          end
        end
    end
  end

  # A *concrete* workspace id for tools that operate within one workspace
  # (create + enumerate). Resolution order: explicit `workspace` arg → the
  # scope's bound workspace → the installation default workspace.
  def resolve_workspace_id(%Scope{} = scope, args) do
    with {:ok, ws_id} <- authorized_workspace(scope, args) do
      if is_binary(ws_id), do: {:ok, ws_id}, else: default_workspace_id()
    end
  end

  # Resolve a `workspace` arg (workspace id first, then name) to a Workspace.
  defp resolve_workspace_ref(ref) when is_binary(ref) do
    with :error <- workspace_by_id(ref),
         :error <- workspace_by_name(ref) do
      {:error, {:not_found, "workspace #{inspect(ref)} not found"}}
    end
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

  # The installation default workspace, for a workspace-agnostic coordinator that
  # named none: the lone workspace if there is exactly one, else the one named
  # "default" (the boot-seeded default). Ambiguous otherwise — the caller must
  # pass `workspace` explicitly.
  defp default_workspace_id do
    case Ash.read!(Workspace) do
      [%Workspace{id: id}] ->
        {:ok, id}

      [] ->
        {:error, {:invalid, "no workspaces exist on this installation"}}

      many ->
        case Enum.find(many, &(&1.name == "default")) do
          %Workspace{id: id} ->
            {:ok, id}

          nil ->
            {:error, {:invalid, "multiple workspaces; pass `workspace` (name or id) explicitly"}}
        end
    end
  end

  # ---- Phase 2 arg coercion + validation ---------------------------------

  # Build a string-keyed attrs map from `args`, taking only the keys in `spec`
  # and coercing each to its declared type. Returns `{:ok, map}` or
  # `{:error, {:invalid, msg}}` on the first bad value. Absent keys are skipped.
  def collect_attrs(args, spec) when is_map(args) do
    Enum.reduce_while(spec, {:ok, %{}}, fn {key, type}, {:ok, acc} ->
      case Map.fetch(args, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, raw} ->
          case coerce_field(type, raw) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, why} -> {:halt, {:error, {:invalid, "`#{key}` #{why}"}}}
          end
      end
    end)
  end

  def collect_attrs(_args, _spec), do: {:ok, %{}}

  def coerce_field(:string, v) when is_binary(v), do: {:ok, v}
  def coerce_field(:string, _), do: {:error, "must be a string"}

  def coerce_field(:integer, v) when is_integer(v), do: {:ok, v}

  def coerce_field(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end

  def coerce_field(:integer, _), do: {:error, "must be an integer"}

  def coerce_field(:boolean, v) when is_boolean(v), do: {:ok, v}
  def coerce_field(:boolean, "true"), do: {:ok, true}
  def coerce_field(:boolean, "false"), do: {:ok, false}
  def coerce_field(:boolean, _), do: {:error, "must be a boolean"}

  def coerce_field({:enum, allowed}, v) do
    case to_allowed_atom(v, allowed) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "must be one of: #{allowed_list(allowed)}"}
    end
  end

  # A required non-empty string argument.
  # internal — shared: a required non-empty string argument
  def require_string(args, key) do
    case fetch_string(args, key) do
      nil -> {:error, {:invalid, "`#{key}` is required"}}
      s -> {:ok, s}
    end
  end

  # A required enum argument coerced against `allowed`.
  def require_enum(args, key, allowed) do
    case fetch_string(args, key) do
      nil -> {:error, {:invalid, "`#{key}` is required"}}
      raw -> enum_or_error(raw, key, allowed)
    end
  end

  # An optional enum argument; `{:ok, nil}` when absent.
  def optional_enum(args, key, allowed) do
    case fetch_string(args, key) do
      nil -> {:ok, nil}
      raw -> enum_or_error(raw, key, allowed)
    end
  end

  # internal — shared
  def enum_or_error(raw, key, allowed) do
    case to_allowed_atom(raw, allowed) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid, "`#{key}` must be one of: #{allowed_list(allowed)}"}}
    end
  end

  # internal — shared
  def optional_integer(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      v when is_integer(v) ->
        {:ok, v}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} -> {:ok, n}
          _ -> {:error, {:invalid, "`#{key}` must be an integer"}}
        end

      _ ->
        {:error, {:invalid, "`#{key}` must be an integer"}}
    end
  end

  def optional_datetime(args, key) do
    case fetch_string(args, key) do
      nil ->
        {:ok, nil}

      raw ->
        case DateTime.from_iso8601(raw) do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> {:error, {:invalid, "`#{key}` must be an ISO-8601 datetime"}}
        end
    end
  end

  # internal — shared
  def fetch_bool(args, key, default) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      v when is_boolean(v) -> {:ok, v}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, {:invalid, "`#{key}` must be a boolean"}}
    end
  end

  # Tri-state bool: `{:ok, nil}` when the key is absent (so the callee can apply
  # its own default), `{:ok, true|false}` when present, error on a bad value.
  def fetch_optional_bool(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      v when is_boolean(v) -> {:ok, v}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, {:invalid, "`#{key}` must be a boolean"}}
    end
  end

  # internal — shared
  def require_some(attrs, msg) do
    if map_size(attrs) == 0, do: {:error, {:invalid, msg}}, else: :ok
  end

  # internal — shared
  def to_allowed_atom(v, allowed) when is_binary(v) do
    atom = String.to_existing_atom(v)
    if atom in allowed, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  def to_allowed_atom(_v, _allowed), do: :error

  # internal — shared
  def allowed_list(allowed), do: Enum.map_join(allowed, ", ", &Atom.to_string/1)

  # internal — shared
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  # internal — shared
  def maybe_put_kw(kw, _key, nil), do: kw
  def maybe_put_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # ---- Phase 2 dispatch guardrail + opts (docs/mcp-server-design.md §4.3) ----

  # internal — shared by Arbiter.MCP.Tools.Worker
  def ensure_can_dispatch(%Scope{can_dispatch: true}), do: :ok

  def ensure_can_dispatch(%Scope{}),
    do: {:error, {:unauthorized, "this scope may not dispatch (can_dispatch is not set)"}}

  # ---- Phase 2 fetch helpers ---------------------------------------------

  # The scope's own workspace, loaded for the tracker bridge tools.
  def fetch_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> {:error, {:not_found, "workspace #{ws_id} not found"}}
    end
  end

  # Wrap `Claim.plan/1` so an adapter/tracker error surfaces as a tool error
  # rather than crashing the handler.
  defp claim_plan(workspace) do
    case Claim.plan(workspace) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:error, {:invalid, claim_error_message(reason)}}
    end
  end

  defp claim_error_message(:tracker_not_supported),
    do: "workspace tracker does not support claim/sync (e.g. tracker is `none`)"

  defp claim_error_message({:not_assigned, who}),
    do:
      "issue is not assigned to the workspace user (#{inspect(who)}); pass force=true to override"

  defp claim_error_message({:already_claimed, _body}),
    do:
      "this issue has already been claimed by another Arbiter installation (force=true to override)"

  defp claim_error_message({:invalid_ref, raw}), do: "invalid issue ref: #{inspect(raw)}"

  defp claim_error_message(%{__struct__: _} = err) do
    if is_exception(err), do: Exception.message(err), else: inspect(err)
  end

  defp claim_error_message(other), do: inspect(other)

  # internal — shared
  def fetch_string(args, key) when is_map(args) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  def fetch_string(_args, _key), do: nil

  # An optional map argument; nil when absent or not a map.
  def fetch_map(args, key) when is_map(args) do
    case Map.get(args, key) do
      m when is_map(m) -> m
      _ -> nil
    end
  end

  def fetch_map(_args, _key), do: nil
  # Some MCP tool-calling clients serialize arguments into JSON-encoded strings
  # before sending them (bd-1dtufq) rather than native JSON values, even though
  # the tool's input_schema advertises the correct types. Detect that shape and
  # decode it, so `"[\"claude\", \"gemini\"]"` is treated as a real list.
  # Only unambiguous structural types (list/map) are unwrapped — scalars are left
  # as-is to preserve legitimate string values. workspace_config_set's schema
  # explicitly allows strings, so a client sending "5" as a config value should
  # not have it reinterpreted as the integer 5.
  def unwrap_stringified_json(v, allowed_types) when is_binary(v) do
    trimmed = String.trim(v)

    # Only attempt JSON decode if this looks like a JSON value (starts with
    # structural char, digit, true/false/null, or quote).
    starts_with_json = String.match?(trimmed, ~r/^[\[\{0-9"tfn]/)

    if starts_with_json do
      case Jason.decode(trimmed) do
        {:ok, decoded} ->
          decoded_type =
            cond do
              is_list(decoded) -> :list
              is_map(decoded) -> :map
              is_integer(decoded) -> :integer
              is_boolean(decoded) -> :boolean
              decoded === nil -> :null
              true -> :other
            end

          if decoded_type in allowed_types, do: decoded, else: v

        _ ->
          v
      end
    else
      v
    end
  end

  def unwrap_stringified_json(v, _allowed_types), do: v
  # ---- serializers (JSON-friendly, mirroring the REST shapes) -------------

  def serialize_task_summary(%Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      status: to_str(i.status),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: to_str(i.issue_type),
      workspace_id: i.workspace_id,
      refined: i.refined
    }
  end

  # internal — shared by Arbiter.MCP.Tools.Task (task_show's full view) and
  # tracker_claim below
  def serialize_task(%Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      description: i.description,
      acceptance: i.acceptance,
      notes: i.notes,
      qa_notes: i.qa_notes,
      deployment_notes: i.deployment_notes,
      status: to_str(i.status),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: to_str(i.issue_type),
      auto_close: i.auto_close,
      assignee: i.assignee,
      tracker_type: to_str(i.tracker_type),
      tracker_ref: i.tracker_ref,
      tracker_context_type: to_str(i.tracker_context_type),
      tracker_context_ref: i.tracker_context_ref,
      pr_ref: i.pr_ref,
      pr_body: i.pr_body,
      target_branch: i.target_branch,
      repo: i.repo,
      workspace_id: i.workspace_id,
      closed_at: iso(i.closed_at),
      created_at: iso(i.created_at),
      updated_at: iso(i.updated_at)
    }
    |> put_progress(i)
  end

  # internal — shared: the child-progress rollup, appended by both
  # serialize_task and Arbiter.MCP.Tools.Task's serialize_task_slim
  def put_progress(map, %Issue{child_total: t, child_closed: c})
      when is_integer(t) and is_integer(c) do
    Map.merge(map, %{child_total: t, child_closed: c, child_open: max(t - c, 0)})
  end

  def put_progress(map, _i), do: map

  defp serialize_graph(%Graph{} = g) do
    %{
      id: g.id,
      name: g.name,
      description: g.description,
      run_state: to_str(g.run_state),
      workspace_id: g.workspace_id,
      created_at: iso(g.created_at),
      updated_at: iso(g.updated_at)
    }
  end

  def serialize_dependency(%Dependency{} = d) do
    %{
      id: d.id,
      from_issue_id: d.from_issue_id,
      to_issue_id: d.to_issue_id,
      type: to_str(d.type),
      notes: d.notes,
      created_by: d.created_by,
      created_at: iso(d.created_at)
    }
  end

  def serialize_workspace(%Workspace{} = ws) do
    %{
      id: ws.id,
      name: ws.name,
      description: ws.description,
      prefix: ws.prefix,
      config: ws.config || %{},
      security: SecurityPolicy.summary(SecurityPolicy.resolve(ws))
    }
  end

  # The non-sensitive summary `workspace_list` returns — id/name/prefix/tracker
  # only, never config or security posture.
  defp serialize_workspace_summary(%Workspace{} = ws) do
    %{
      id: ws.id,
      name: ws.name,
      prefix: ws.prefix,
      tracker_type: to_str(Trackers.workspace_type(ws))
    }
  end

  # The planned reconcile actions / per-action results from the tracker bridge,
  # mirroring `ArbiterWeb.Api.ClaimController`'s shapes.
  defp serialize_claim_action({:create, ref, summary}),
    do: %{action: "create", ref: ref, title: summary[:title], html_url: summary[:html_url]}

  defp serialize_claim_action({:close, task_id, reason}),
    do: %{action: "close", task_id: task_id, reason: reason}

  defp serialize_claim_action({:drift, task_id, reason}),
    do: %{action: "drift", task_id: task_id, reason: reason}

  defp serialize_claim_result({:created, task}),
    do: %{outcome: "created", task: serialize_task_summary(task)}

  defp serialize_claim_result({:closed, task}),
    do: %{outcome: "closed", task: serialize_task_summary(task)}

  defp serialize_claim_result({:drifted, task}),
    do: %{outcome: "drifted", task: serialize_task_summary(task)}

  defp serialize_claim_result({:error, action, reason}),
    do: %{outcome: "error", action: serialize_claim_action(action), reason: inspect(reason)}

  # internal — shared
  def to_str(nil), do: nil
  def to_str(a) when is_atom(a), do: Atom.to_string(a)
  def to_str(s) when is_binary(s), do: s

  # internal — shared
  def iso(nil), do: nil
  def iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  # internal — shared
  def ash_error_message(%{__struct__: _} = err) do
    if is_exception(err), do: Exception.message(err), else: inspect(err)
  rescue
    _ -> "update failed"
  end

  def ash_error_message(err), do: inspect(err)

  # ---- delegation to split-out submodules ---------------------------------
  #
  # Implementation for these tool groups lives in the submodules below (see
  # the moduledoc); delegating keeps `&Tools.function/2` captures in
  # `Arbiter.MCP.Catalog` and every existing `Tools.function(...)` call site
  # working unchanged.

  defdelegate skill_create(scope, args), to: Arbiter.MCP.Tools.Skills
  defdelegate skill_update(scope, args), to: Arbiter.MCP.Tools.Skills
  defdelegate skill_delete(scope, args), to: Arbiter.MCP.Tools.Skills
  defdelegate skill_list(scope, args), to: Arbiter.MCP.Tools.Skills
  defdelegate skill_get(scope, args), to: Arbiter.MCP.Tools.Skills

  defdelegate loop_pending_list(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_pending_diff(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_pending_apply(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_pending_reject(scope, args), to: Arbiter.MCP.Tools.LoopPending

  defdelegate task_show(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_ready(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_update_progress(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_create(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_update(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_close(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_reopen(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_promote(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_sync_upstream_close(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate dep_add(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate dep_remove(scope, args), to: Arbiter.MCP.Tools.Task

  defdelegate workspace_show(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_config_get(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_config_overview(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_config_set(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_config_unset(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate installation_config_get(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate installation_config_set(scope, args), to: Arbiter.MCP.Tools.Workspace

  defdelegate inbox_check(scope, args), to: Arbiter.MCP.Tools.Messaging
  defdelegate coordinator_inbox(scope, args), to: Arbiter.MCP.Tools.Messaging
  defdelegate message_send(scope, args), to: Arbiter.MCP.Tools.Messaging
  defdelegate notify_list(scope, args), to: Arbiter.MCP.Tools.Messaging

  defdelegate worker_dispatch(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_resume(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_review(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_stop(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_list(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_show(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_runs(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_log(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_prompt(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate run_log_list(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate transcript_capture_stats(scope, args), to: Arbiter.MCP.Tools.Worker
end
