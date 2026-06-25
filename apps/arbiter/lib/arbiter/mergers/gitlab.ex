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

  Returns the task-domain view of the MR:

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

  require Logger

  alias Arbiter.Mergers.Gitlab.{Config, Error}

  @stub_name Arbiter.Mergers.Gitlab.HTTP

  # ---- Merger behaviour ----------------------------------------------------

  @impl true
  def open(branch, title, description, opts)
      when is_binary(branch) and is_binary(title) and is_binary(description) and is_map(opts) do
    with {:ok, cfg} <- Config.resolve(),
         :ok <- maybe_push_branch(branch, opts) do
      target_branch = Map.get(opts, :target_branch) || cfg.default_target_branch

      payload =
        %{
          "source_branch" => branch,
          "target_branch" => target_branch,
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

        {:ok, %Req.Response{status: 422, body: body}} ->
          if duplicate_mr_error?(body) do
            adopt_existing_mr(cfg, branch, target_branch)
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
         {:ok, iid} <- iid_from_ref(mr_ref) do
      case request(cfg, :get, "/merge_requests/#{iid}", []) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          merge_status = Map.get(body, "merge_status", "")
          pipeline = fetch_pipeline_status(cfg, iid)
          status = map_state(Map.get(body, "state"))

          {:ok,
           %{
             ref: ref_for(iid),
             status: status,
             approved: approved?(body),
             changes_requested: false,
             latest_review_id: nil,
             pipeline: pipeline,
             ci_clean: merge_status == "can_be_merged",
             conflicting:
               Map.get(body, "has_conflicts", false) == true or
                 merge_status == "cannot_be_merged",
             block_reason: block_reason(cfg, body, status, pipeline),
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

  @impl true
  def ref_for_pr(pr, _opts) when is_binary(pr) do
    pr = String.trim(pr)

    cond do
      # Full forge URL: https://<host>/<group>/<project>/-/merge_requests/<iid>
      m = Regex.run(~r{/-/merge_requests/(\d+)}, pr) ->
        [_, iid] = m
        {:ok, ref_for(iid)}

      # Bare iid or GitLab's own "!<iid>" shorthand.
      m = Regex.run(~r/^!?(\d+)$/, pr) ->
        [_, iid] = m
        {:ok, ref_for(iid)}

      true ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: nil,
           message:
             "could not parse #{inspect(pr)} as a GitLab MR reference — expected an MR URL " <>
               "(…/-/merge_requests/N), a bare iid, or \"!N\". The MR is resolved within the " <>
               "workspace's configured project_id.",
           raw: pr
         }}
    end
  end

  @impl true
  def get_diff(mr_ref, _opts) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref) do
      case request(cfg, :get, "/merge_requests/#{iid}/changes", []) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, changes_to_diff(body)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, http_error(status, body)}

        {:error, exception} ->
          {:error, transport_error(exception)}
      end
    end
  end

  @impl true
  def post_inline_comment(mr_ref, finding, _opts)
      when is_binary(mr_ref) and is_map(finding) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref) do
      %{severity: sev, file: file, line: line, message: msg} = finding
      body = "**#{sev |> Atom.to_string() |> String.upcase()}** at `#{file}:#{line}`: #{msg}"

      request(cfg, :post, "/merge_requests/#{iid}/notes", json: %{"body" => body})
      |> handle_json()
    end
  end

  @impl true
  def submit_review(mr_ref, verdict, body, _opts)
      when is_binary(mr_ref) and verdict in [:approve, :request_changes] do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref) do
      case verdict do
        :approve ->
          approve_result =
            request(cfg, :post, "/merge_requests/#{iid}/approve", json: %{}) |> handle_json()

          case approve_result do
            {:ok, _} ->
              post_summary_note(cfg, iid, body, "Approved")

            {:error, %Error{} = err} ->
              if self_approve_error?(err) do
                Logger.warning(
                  "GitLab self-review: approve rejected (#{err.message}); " <>
                    "falling back to verdict note for MR #{iid}"
                )

                note_body = "VERDICT: APPROVE\n\n#{body || ""}" |> String.trim()
                post_summary_note(cfg, iid, note_body, "Approved (comment fallback)")
              else
                {:error, err}
              end
          end

        :request_changes ->
          # GitLab has no native "request changes" REST verb. Post a
          # clearly-marked note so reviewers see the verdict in the
          # discussion timeline, and unapprove if previously approved (the
          # endpoint is idempotent and tolerates "not currently approved").
          with {:ok, _} <-
                 request(cfg, :post, "/merge_requests/#{iid}/unapprove", json: %{})
                 |> handle_unapprove(),
               {:ok, _} = ok <-
                 post_summary_note(cfg, iid, body, "Requesting changes") do
            ok
          end
      end
    end
  end

  # GitLab has no native "request changes" review verb (see submit_review/4),
  # so there is no distinct CHANGES_REQUESTED signal to ingest. The auto-revise
  # path is GitHub-shaped (bd-95lsjb); GitLab no-ops here rather than guessing a
  # verdict from discussion notes.
  @impl true
  def list_review_feedback(mr_ref) when is_binary(mr_ref),
    do: {:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}}

  # The unresolved review threads on an MR — the provider-agnostic "open review
  # feedback" signal PRPatrol triggers on (bd-823q7e). GitLab models a review
  # thread as a *discussion* whose notes carry `resolvable` / `resolved`; a
  # discussion is open when it has at least one resolvable note that is not
  # resolved. Non-resolvable, system, and individual (non-discussion) notes are
  # ignored. Each open discussion is normalized to a `t:review_thread/0`.
  @impl true
  def list_open_review_threads(mr_ref) when is_binary(mr_ref) do
    with {:ok, cfg} <- Config.resolve(),
         {:ok, iid} <- iid_from_ref(mr_ref),
         {:ok, discussions} <-
           request(cfg, :get, "/merge_requests/#{iid}/discussions", params: [per_page: 100])
           |> handle_json() do
      threads =
        discussions
        |> List.wrap()
        |> Enum.filter(&unresolved_discussion?/1)
        |> Enum.map(&normalize_discussion/1)

      {:ok, threads}
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

  # ---- Internals: duplicate-MR adoption ------------------------------------

  # GitLab returns 422 with a message list containing "another open merge
  # request already exists for this source branch" when the worker created
  # the MR itself (via `glab mr create`) before the merger fired. Match
  # case-insensitively against the canonical substring.
  defp duplicate_mr_error?(%{"message" => messages}) when is_list(messages) do
    Enum.any?(messages, fn
      msg when is_binary(msg) ->
        msg |> String.downcase() |> String.contains?("open merge request already exists")

      _ ->
        false
    end)
  end

  defp duplicate_mr_error?(%{"message" => msg}) when is_binary(msg) do
    msg |> String.downcase() |> String.contains?("open merge request already exists")
  end

  defp duplicate_mr_error?(_), do: false

  # When the branch already has an open MR, look it up and return its ref so
  # the merger can adopt it instead of failing.
  defp adopt_existing_mr(cfg, branch, target_branch) do
    params = [state: "opened", source_branch: branch, target_branch: target_branch]

    case request(cfg, :get, "/merge_requests", params: params) do
      {:ok, %Req.Response{status: status, body: [%{"iid" => iid} | _]}}
      when status in 200..299 and is_integer(iid) ->
        Logger.info(
          "GitLab merger: adopting existing open MR !#{iid} for branch #{inspect(branch)}"
        )

        {:ok, ref_for(iid)}

      {:ok, %Req.Response{status: status, body: []}} when status in 200..299 ->
        {:error,
         %Error{
           kind: :conflict,
           status: 422,
           message: "another open merge request already exists but none found in listing",
           raw: []
         }}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:error,
         %Error{
           kind: :validation_failed,
           status: status,
           message: "unexpected response shape when listing open merge requests",
           raw: body
         }}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, exception} ->
        {:error, transport_error(exception)}
    end
  end

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

  # Classify *why* an open MR can't merge, or nil when it is mergeable (or
  # already terminal). The block-reason surface Phase 1 (#354) escalates on so an
  # approved-but-unmergeable MR never parks silently. Prefers GitLab's
  # `detailed_merge_status` (richest signal); falls back to `merge_status` /
  # `has_conflicts` on older GitLab versions that omit it.
  #
  #   :conflict                  — merge conflict with the target branch
  #   :behind_base               — fast-forward-only target needs a rebase
  #   :ci_failed                 — required pipeline actually failed
  #   :needs_approval            — required approvals not yet satisfied
  #   :needs_nonauthor_approval  — `not_approved` on a fleet-authored MR (GitLab's
  #                                approval rules forbid the author self-approving)
  #   :draft                     — MR is a draft / work in progress
  #   :blocked_other             — blocked by some other settled rule (threads, …)
  #
  # In-progress / transient statuses map to `nil` (not a block): "ci_still_running"
  # / "ci_must_pass" mean CI is required but not yet green — it may still be
  # running — so a CI block is keyed off the *resolved* `pipeline == :failed`,
  # never the detailed-status string; and "preparing" / "checking" / "unchecked"
  # mean GitLab is still computing the merge status. Escalating any of these
  # would fire while the MR is merely being prepared, not genuinely blocked.
  defp block_reason(_cfg, _body, status, _pipeline) when status in [:merged, :closed], do: nil

  defp block_reason(cfg, body, _status, pipeline) do
    draft? = Map.get(body, "draft") == true or Map.get(body, "work_in_progress") == true
    detailed = Map.get(body, "detailed_merge_status")
    merge_status = Map.get(body, "merge_status")
    conflicts? = Map.get(body, "has_conflicts") == true

    cond do
      draft? or detailed == "draft_status" ->
        :draft

      conflicts? or detailed in ["conflict", "broken_status"] ->
        :conflict

      detailed == "need_rebase" ->
        :behind_base

      # Only a settled, failed pipeline is a CI block. "ci_must_pass" /
      # "ci_still_running" are handled in the in-progress bucket below.
      pipeline == :failed ->
        :ci_failed

      detailed in ["not_approved", "approvals_syncing", "requested_changes"] ->
        approval_block_reason(cfg, body, detailed)

      detailed == "mergeable" ->
        nil

      # In-progress / transient — CI not yet green, or merge status still being
      # computed. Non-blocking until it settles (findings: ci_still_running is
      # not a failure; preparing/checking/unchecked are not a block).
      detailed in ["ci_must_pass", "ci_still_running", "preparing", "checking", "unchecked"] ->
        nil

      is_nil(detailed) and merge_status == "cannot_be_merged" ->
        :conflict

      is_nil(detailed) and merge_status in ["can_be_merged", "unchecked", "checking", nil, ""] ->
        nil

      is_nil(detailed) ->
        nil

      true ->
        :blocked_other
    end
  end

  # `not_approved` on an otherwise-green MR means the only thing left is a
  # required approval. If the MR was opened by the fleet's own identity, GitLab's
  # approval rules require an approval from someone *other than the author* (a
  # project commonly enables "prevent author approval"), which the fleet can't
  # supply. The Watchdog parks + summons a human once on `:needs_nonauthor_approval`
  # rather than failing at the poll ceiling (bd-c3lchp). `requested_changes` is a
  # genuine review action and `approvals_syncing` is transient, so both stay
  # `:needs_approval`; non-fleet authorship also falls back to `:needs_approval`.
  defp approval_block_reason(cfg, body, "not_approved") do
    if fleet_authored?(cfg, body), do: :needs_nonauthor_approval, else: :needs_approval
  end

  defp approval_block_reason(_cfg, _body, _detailed), do: :needs_approval

  # True only when the MR's author username matches the authenticated token's own
  # username. Skips the `/user` lookup when the MR carries no author, so the
  # common path (and stubs that don't model `/user`) never make the call.
  defp fleet_authored?(cfg, body) do
    case get_in(body, ["author", "username"]) do
      name when is_binary(name) and name != "" -> name == authenticated_username(cfg)
      _ -> false
    end
  end

  # The username of the token's own identity (`GET /user`, at the API root rather
  # than the project-scoped base `request/4` uses). Best-effort: any failure
  # yields nil so the caller falls back to the generic block reason. Reached only
  # in the narrow `not_approved` branch, not on every poll.
  defp authenticated_username(cfg) do
    opts =
      [
        method: :get,
        url: "https://#{cfg.host}/api/v4/user",
        headers: headers(cfg),
        receive_timeout: 15_000,
        retry: false
      ]
      |> Keyword.merge(stub_opts())

    case Req.request(opts) do
      {:ok, %Req.Response{status: status, body: %{"username" => name}}}
      when status in 200..299 and is_binary(name) and name != "" ->
        name

      _ ->
        nil
    end
  end

  # Fetch the latest pipeline for the MR and map its status to a domain atom.
  # Returns nil when there are no pipelines (no CI configured) or the request
  # fails (best-effort — a transient API error must not block the MR poll).
  defp fetch_pipeline_status(cfg, iid) do
    case request(cfg, :get, "/merge_requests/#{iid}/pipelines", params: [per_page: 1]) do
      {:ok, %Req.Response{status: status, body: [latest | _]}} when status in 200..299 ->
        map_pipeline_status(Map.get(latest, "status"))

      _ ->
        nil
    end
  end

  defp map_pipeline_status("success"), do: :success
  defp map_pipeline_status("failed"), do: :failed
  defp map_pipeline_status("canceled"), do: :failed
  defp map_pipeline_status("running"), do: :running
  defp map_pipeline_status(_), do: :pending

  defp handle_ok({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp handle_ok({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, http_error(status, body)}

  defp handle_ok({:error, exception}), do: {:error, transport_error(exception)}

  defp handle_json({:ok, %Req.Response{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_json({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, http_error(status, body)}

  defp handle_json({:error, exception}), do: {:error, transport_error(exception)}

  # POST `/unapprove` is idempotent in spirit but GitLab returns 401/404
  # depending on whether the caller was the original approver. Treat any
  # non-2xx that isn't a hard auth/transport failure as "best-effort" —
  # the summary note is the real signal of `:request_changes`.
  defp handle_unapprove({:ok, %Req.Response{status: status}}) when status in 200..299,
    do: {:ok, :unapproved}

  defp handle_unapprove({:ok, %Req.Response{status: 404}}), do: {:ok, :not_previously_approved}

  defp handle_unapprove({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, http_error(status, body)}

  defp handle_unapprove({:error, exception}), do: {:error, transport_error(exception)}

  # GitLab returns 401/403/422 when prevent_author_approval is enabled and the
  # reviewer is the MR author. The exact message varies across GitLab versions;
  # match on status + common message fragments that indicate identity conflict.
  defp self_approve_error?(%Error{status: status, message: msg})
       when status in [401, 403, 422] and is_binary(msg) do
    lower = String.downcase(msg)

    String.contains?(lower, "own merge request") or
      String.contains?(lower, "not allowed to approve") or
      String.contains?(lower, "not permitted to approve") or
      String.contains?(lower, "author of this merge request") or
      String.contains?(lower, "author cannot approve")
  end

  defp self_approve_error?(_), do: false

  # GitLab returns no top-level diff field on `/changes`; the diff sits in
  # `changes[].diff` per-file. Assemble a single unified-diff text the
  # check runner can feed to its reviewer.
  defp changes_to_diff(%{"changes" => changes}) when is_list(changes) do
    changes
    |> Enum.map(&render_change/1)
    |> Enum.join("")
  end

  defp changes_to_diff(_), do: ""

  defp render_change(%{} = change) do
    old_path = Map.get(change, "old_path") || Map.get(change, "new_path") || ""
    new_path = Map.get(change, "new_path") || Map.get(change, "old_path") || ""
    diff = Map.get(change, "diff") || ""

    "diff --git a/#{old_path} b/#{new_path}\n--- a/#{old_path}\n+++ b/#{new_path}\n" <> diff
  end

  # A discussion is an *open review thread* when it has at least one resolvable
  # note that is not yet resolved. GitLab marks the diff/inline notes that make
  # up a review thread as `resolvable: true`; general comments and system notes
  # are `resolvable: false` and never count.
  defp unresolved_discussion?(%{"notes" => notes}) when is_list(notes) do
    Enum.any?(notes, fn note ->
      Map.get(note, "resolvable") == true and Map.get(note, "resolved") != true
    end)
  end

  defp unresolved_discussion?(_), do: false

  defp normalize_discussion(%{} = discussion) do
    first = discussion |> Map.get("notes") |> List.wrap() |> List.first() || %{}
    position = Map.get(first, "position") || %{}

    %{
      id: Map.get(discussion, "id"),
      path: Map.get(position, "new_path") || Map.get(position, "old_path"),
      line: Map.get(position, "new_line") || Map.get(position, "old_line"),
      author: get_in(first, ["author", "username"]),
      body: Map.get(first, "body")
    }
  end

  defp post_summary_note(cfg, iid, body, prefix) do
    text =
      case body do
        b when is_binary(b) and b != "" -> "#{prefix}: #{b}"
        _ -> prefix
      end

    request(cfg, :post, "/merge_requests/#{iid}/notes", json: %{"body" => text})
    |> handle_json()
  end

  # ---- Internals: git operations ------------------------------------------

  defp maybe_push_branch(branch, opts) do
    case Map.get(opts, :repo_path) do
      path when is_binary(path) ->
        case System.cmd("git", ["push", "--set-upstream", "origin", branch],
               stderr_to_stdout: true,
               cd: path
             ) do
          {_output, 0} ->
            :ok

          {output, _nonzero} ->
            {:error,
             %Error{
               kind: :git_push_failed,
               status: nil,
               message: "Failed to push branch #{inspect(branch)}: #{String.trim(output)}",
               raw: output
             }}
        end

      _ ->
        :ok
    end
  rescue
    e in ErlangError ->
      {:error,
       %Error{
         kind: :git_push_failed,
         status: nil,
         message: "Failed to push branch #{inspect(branch)}: #{Exception.message(e)}",
         raw: e
       }}
  end

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
