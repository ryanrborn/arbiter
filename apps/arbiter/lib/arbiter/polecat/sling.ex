defmodule Arbiter.Polecat.Sling do
  @moduledoc """
  Spawn a polecat for a bead and attach it to the `Arbiter.Workflows.Work`
  workflow via `Arbiter.Workflows.Machine`.

  This is the "go work this bead" entry point — called by:

    * the `arb sling <bead-id>` CLI command (via the REST API),
    * the `Refinery` GenServer (when re-dispatching follow-ups),
    * Phoenix LiveView dashboards that have a "send polecat" button.

  Single responsibility: orchestrate the three steps needed to start a
  polecat working on a bead, in the right order, with the right cleanup if
  anything fails.

  ## Steps

  1. Load + validate the bead. Bead must not be `:closed`.
  2. Transition bead to `:in_progress` (via the bead's `:update` action,
     skipping the `:close` FSM path).
  3. Provision a git worktree on a per-bead branch — skipped when the
     rig isn't in `:arbiter, :rig_paths` or `provision_worktree: false`.
  4. Start a polecat under `Arbiter.Polecat.Supervisor` for the bead.
  5. **Optionally** spawn a Claude subprocess in the worktree via
     `ClaudeSession.start/1`. Opt-in via `start_claude: true` — defaults
     to `false` to avoid silent paid-API invocations. Requires a worktree.
  6. Attach `Arbiter.Workflows.Work` via `Workflows.Machine.attach/3`
     and start the machine.
  7. Start a `Arbiter.Polecat.Driver` under the same supervisor — it
     ticks the machine forward and closes the bead when the workflow
     completes. Skipped when `start_driver: false`.

  ## Returns

  ```
  {:ok, %{
    bead: %Issue{},              # updated, status: :in_progress
    polecat_pid: pid(),
    machine_id: String.t(),
    machine_pid: pid(),
    driver_pid: pid() | nil,     # nil if start_driver: false
    worktree_path: String.t() | nil,  # nil if rig unconfigured / opted out
    claude_port: port() | nil    # nil unless start_claude: true
  }}
  ```

  Or `{:error, reason}` for any step that fails. On error, partial work is
  best-effort-rolled-back (started polecat is stopped; bead status revert is
  NOT attempted because the user may want to inspect what happened).
  """

  alias Arbiter.Agents
  alias Arbiter.Agents.Preflight
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Messages.AdmiralNotifier
  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace
  alias Arbiter.Polecat
  alias Arbiter.Polecat.BranchNamer
  alias Arbiter.Polecat.ClaudeSession
  alias Arbiter.Polecat.Driver
  alias Arbiter.Polecat.ResumeContext
  alias Arbiter.Polecat.StopReason
  alias Arbiter.Polecat.Worktree
  alias Arbiter.Polecats.Run
  alias Arbiter.Workflows.CodeReview
  alias Arbiter.Workflows.Machine
  alias Arbiter.Workflows.Work

  require Ash.Query

  @type sling_opts :: [
          rig: String.t() | nil,
          base_branch: String.t() | nil,
          workflow_module: module(),
          start_driver: boolean(),
          start_claude: boolean(),
          claude_command: [String.t()] | nil,
          cleanup_worktree: boolean(),
          model: String.t() | nil,
          review: boolean(),
          security: map() | nil,
          security_mode: String.t() | atom() | nil,
          preflight: boolean(),
          probe_command: [String.t()] | nil,
          agent_adapter: module() | nil
        ]

  @type sling_result :: %{
          bead: Issue.t(),
          polecat_pid: pid(),
          machine_id: String.t(),
          machine_pid: pid(),
          driver_pid: pid() | nil,
          worktree_path: String.t() | nil,
          claude_port: port() | nil
        }

  @spec sling(String.t(), sling_opts()) :: {:ok, sling_result()} | {:error, term()}
  def sling(bead_id, opts \\ []) when is_binary(bead_id) do
    opts = normalize_opts(opts)

    with {:ok, bead} <- load_bead(bead_id),
         :ok <- ensure_not_closed(bead),
         {:ok, opts} <- maybe_resolve_rig_for_real_work(bead, opts),
         :ok <- maybe_preflight(bead, opts),
         {:ok, bead} <- transition_to_in_progress(bead),
         {:ok, worktree_path} <- maybe_provision_worktree(bead, opts),
         {:ok, polecat_pid} <- start_polecat(bead, worktree_path, opts),
         {:ok, claude_port} <-
           maybe_start_claude(bead, polecat_pid, worktree_path, opts),
         {:ok, machine_id, machine_pid} <-
           attach_and_start_machine(bead, worktree_path, opts),
         {:ok, driver_pid} <-
           maybe_start_driver(bead, polecat_pid, machine_id, machine_pid, worktree_path, opts) do
      {:ok,
       %{
         bead: bead,
         polecat_pid: polecat_pid,
         machine_id: machine_id,
         machine_pid: machine_pid,
         driver_pid: driver_pid,
         worktree_path: worktree_path,
         claude_port: claude_port
       }}
    else
      err -> err
    end
  end

  @doc """
  Resume a stopped acolyte (bd-auma3z): re-attach a **fresh** agent to the
  bead's **preserved** outpost worktree, briefed with a git-derived summary of
  the prior acolyte's committed + uncommitted work, so it continues from where
  the stopped run left off instead of restarting from scratch.

  This is the explicit `arb resume <bead>` path. It is provider-agnostic — no
  Claude/Gemini session-resume id; the continuity comes entirely from the
  preserved worktree state plus a `Arbiter.Polecat.ResumeContext` briefing
  prepended to the standard work prompt (Admiral sign-off 2026-06-05, approach
  (b)).

  ## Steps

  1. Load + validate the bead (must not be `:closed`).
  2. Refuse if a polecat is still **actively** working the bead — resume only
     applies to a stopped/failed/dead acolyte. Stop the active one first.
  3. Resolve the rig (explicit opt, else the bead's most recent run's rig).
  4. Require the outpost worktree to still exist on disk — `{:error,
     :no_outpost}` if it was cleaned up (nothing to resume; re-`sling` instead).
  5. Build the resume briefing from the worktree's git state.
  6. Stop any prior (failed) polecat still resident for the bead so a fresh
     `polecat_run` starts cleanly rather than the new sling attaching to the
     dead one (which would skip the run row and collide on the registry key —
     the same class of bug fixed in the conflict-resolver).
  7. Delegate to `sling/2` with the resume markers set: it reuses the existing
     worktree (idempotent `Worktree.create`), prepends the briefing, links the
     new run to the prior via `resumed_from_run_id`, and passes the bead's
     existing `pr_ref` so completion reuses any open PR rather than duplicating.

  Returns the same `{:ok, sling_result()}` / `{:error, reason}` shape as
  `sling/2`. Resume-specific errors: `{:error, :no_outpost}`,
  `{:error, {:acolyte_active, status}}`, `{:error, :rig_unknown}`.
  """
  @spec resume(String.t(), sling_opts()) :: {:ok, sling_result()} | {:error, term()}
  def resume(bead_id, opts \\ []) when is_binary(bead_id) do
    with {:ok, bead} <- load_bead(bead_id),
         :ok <- ensure_not_closed(bead),
         :ok <- ensure_not_active(bead_id),
         {:ok, rig} <- resolve_resume_rig(bead, opts),
         {:ok, worktree_path} <- resume_worktree(bead, rig),
         target_branch <- resolve_target_branch(bead, Keyword.put(opts, :rig, rig)),
         {:ok, context} <- ResumeContext.build(bead, worktree_path, target_branch) do
      prior_run_id = latest_run_id(bead_id)

      # Free the registry slot: a stopped acolyte's polecat lingers in :failed,
      # still registered under bead_id. Without stopping it, sling/2's
      # start_polecat would hit {:already_started, pid} and attach to the dead
      # one — no fresh run, no resumed_from_run_id. Stopping it does NOT touch
      # the worktree (terminate/2 never cleans up), so the outpost is preserved.
      _ = stop_prior_polecat(bead_id)

      resume_opts =
        opts
        |> Keyword.put(:rig, rig)
        |> Keyword.put(:start_claude, true)
        |> Keyword.put(:resume, true)
        |> Keyword.put(:resume_context, context)
        |> Keyword.put(:resumed_from_run_id, prior_run_id)
        |> Keyword.put(:existing_pr_ref, bead.pr_ref)

      sling(bead_id, resume_opts)
    end
  end

  # Resume only applies to a stopped/failed/dead acolyte. If a polecat is still
  # live in a working state, refuse rather than stomp in-flight work — the
  # operator should `arb polecat stop` it first. A :failed (the stopped state)
  # or :completed polecat, or no polecat at all, is resumable.
  defp ensure_not_active(bead_id) do
    case Polecat.whereis(bead_id) do
      nil ->
        :ok

      pid ->
        case safe_polecat_status(pid) do
          status when status in [:failed, :completed, nil] -> :ok
          status -> {:error, {:acolyte_active, status}}
        end
    end
  end

  defp safe_polecat_status(pid) do
    case Polecat.state(pid) do
      %{status: status} -> status
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # The rig: an explicit opt wins; otherwise inherit the bead's most recent run's
  # rig so `arb resume <bead>` works without re-specifying it. No run + no opt is
  # an error — we can't resolve the outpost without knowing the rig.
  defp resolve_resume_rig(%Issue{id: bead_id}, opts) do
    case Keyword.get(opts, :rig) do
      rig when is_binary(rig) and rig != "" ->
        {:ok, rig}

      _ ->
        case latest_run(bead_id) do
          %Run{rig: rig} when is_binary(rig) and rig != "" -> {:ok, rig}
          _ -> {:error, :rig_unknown}
        end
    end
  end

  # Resolve the preserved outpost path for the bead's per-bead branch and require
  # it to exist on disk. A missing worktree means there's nothing to resume.
  defp resume_worktree(%Issue{} = bead, rig) do
    case resolve_rig_path(bead, rig) do
      repo_path when is_binary(repo_path) ->
        path = Worktree.worktree_path(BranchNamer.derive(bead))
        if File.dir?(path), do: {:ok, path}, else: {:error, :no_outpost}

      _ ->
        {:error, :rig_unknown}
    end
  end

  defp stop_prior_polecat(bead_id) do
    case Polecat.whereis(bead_id) do
      nil -> :ok
      _pid -> Polecat.stop(bead_id, :normal)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp latest_run_id(bead_id) do
    case latest_run(bead_id) do
      %Run{id: id} -> id
      _ -> nil
    end
  end

  defp latest_run(nil), do: nil

  defp latest_run(bead_id) when is_binary(bead_id) do
    Run
    |> Ash.Query.filter(bead_id == ^bead_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  # `review: true` is the convenience hook used by `arb review`: it forces the
  # review-only defaults so the caller doesn't have to spell out four flags in
  # tandem (and so the CLI/REST surface can't accidentally request, say, a
  # worktree on a review). Explicit opts still win — tests and advanced callers
  # can opt back out of any individual default.
  defp normalize_opts(opts) do
    case Keyword.get(opts, :review, false) do
      true ->
        opts
        |> Keyword.put_new(:workflow_module, CodeReview)
        |> Keyword.put_new(:provision_worktree, false)

      _ ->
        opts
    end
  end

  defp load_bead(bead_id) do
    case Ash.get(Issue, bead_id) do
      {:ok, bead} -> {:ok, bead}
      {:error, _} -> {:error, {:bead_not_found, bead_id}}
    end
  end

  defp ensure_not_closed(%Issue{status: :closed, id: id}), do: {:error, {:bead_closed, id}}
  defp ensure_not_closed(_bead), do: :ok

  defp transition_to_in_progress(%Issue{status: :in_progress} = bead), do: {:ok, bead}

  defp transition_to_in_progress(%Issue{} = bead) do
    case Ash.update(bead, %{status: :in_progress}) do
      {:ok, updated} -> {:ok, updated}
      {:error, e} -> {:error, {:transition_failed, e}}
    end
  end

  defp start_polecat(%Issue{id: id, workspace_id: ws_id} = bead, worktree_path, opts) do
    rig = Keyword.get(opts, :rig) || "unknown"
    meta = build_polecat_meta(bead, worktree_path, opts)

    case Polecat.start(bead_id: id, rig: rig, workspace_id: ws_id, meta: meta) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        # Idempotency: a polecat for this bead already exists. That's fine;
        # we'll attach a (possibly new) workflow to the existing process.
        {:ok, pid}

      {:error, reason} ->
        {:error, {:polecat_start_failed, reason}}
    end
  end

  # Seed the polecat's :meta with everything its completion path needs to
  # integrate the branch when the acolyte finishes (see the arb-done handler in
  # `Arbiter.Polecat`).
  #
  # When a worktree was provisioned we know the per-bead branch and the rig
  # path (the local checkout where the target branch lives — the `repo_path`
  # the `Direct` merger runs `git merge --no-ff` inside). With no worktree
  # (rig unconfigured, or `provision_worktree: false`) there is nothing to
  # merge, so `:branch` stays absent and completion is a plain bead close.
  defp build_polecat_meta(%Issue{} = bead, worktree_path, opts) do
    base =
      case Keyword.get(opts, :review, false) do
        true -> %{worktree_path: worktree_path, review_only: true}
        _ -> %{worktree_path: worktree_path}
      end

    base = maybe_put_resume_meta(base, opts)

    case worktree_path && resolve_rig_path(bead, Keyword.get(opts, :rig)) do
      repo_path when is_binary(repo_path) ->
        Map.merge(base, %{
          branch: BranchNamer.derive(bead),
          repo_path: repo_path,
          target_branch: resolve_target_branch(bead, opts),
          merge_title: merge_title(bead)
        })

      _ ->
        base
    end
  end

  # bd-auma3z: stamp the resume markers into the polecat's :meta so (1) the
  # GenServer boots into `:resuming` rather than `:idle`, (2) `record_run_started`
  # links the new run to the prior one via `resumed_from_run_id`, and (3) the
  # completion path can reuse an already-open PR (`existing_pr_ref`) instead of
  # opening a duplicate. No-op on a normal fresh sling.
  defp maybe_put_resume_meta(base, opts) do
    case Keyword.get(opts, :resume, false) do
      true ->
        base
        |> Map.put(:resume, true)
        |> put_if_present(:resumed_from_run_id, Keyword.get(opts, :resumed_from_run_id))
        |> put_if_present(:existing_pr_ref, Keyword.get(opts, :existing_pr_ref))

      _ ->
        base
    end
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp merge_title(%Issue{id: id, title: title}) when is_binary(title) and title != "",
    do: "Merge #{id}: #{title}"

  defp merge_title(%Issue{id: id}), do: "Merge #{id}"

  defp attach_and_start_machine(%Issue{id: id}, worktree_path, opts) do
    workflow = Keyword.get(opts, :workflow_module, Work)
    vars = %{bead_id: id, worktree_path: worktree_path, rig: Keyword.get(opts, :rig)}

    with {:ok, machine_id} <- Machine.attach(workflow, id, vars),
         {:ok, pid} <- Machine.start(machine_id) do
      {:ok, machine_id, pid}
    else
      err -> {:error, {:machine_start_failed, err}}
    end
  end

  # Provision a fresh git worktree on a per-bead branch, cut from the upstream
  # tip of the resolved target branch (`origin/<target>`).
  #
  # The arbiter — not the acolyte — fetches from origin before creating the
  # worktree. The acolyte then starts on a clean, current branch with no git
  # plumbing in its context.
  #
  # Behaviour:
  #   - `provision_worktree: false` in opts → skip, return `{:ok, nil}`.
  #   - rig has no mapping in workspace config or Application env → skip,
  #     return `{:ok, nil}` (the default no-op stance).
  #   - Otherwise, derive a branch name and call `Worktree.create/3`, which
  #     `git fetch origin <target>` + `git worktree add -b <branch>
  #     origin/<target>`. A fetch or ref-resolve failure aborts with a clear
  #     error rather than silently falling back to a stale local base.
  #
  # ## Rig path lookup order
  #
  #   1. Bead's workspace config (`workspace.config["rig_paths"][rig]`)
  #      — per-workspace, runtime-settable, owns the source of truth.
  #   2. Application env (`:arbiter, :rig_paths`) — global fallback,
  #      configured in `config/dev.exs` for dev convenience.
  #
  # First hit wins. This lets workspaces override the global default
  # without changing application config.
  defp maybe_provision_worktree(%Issue{} = bead, opts) do
    cond do
      Keyword.get(opts, :provision_worktree, true) == false ->
        {:ok, nil}

      true ->
        rig = Keyword.get(opts, :rig)

        case resolve_rig_path(bead, rig) do
          nil ->
            {:ok, nil}

          repo_path when is_binary(repo_path) ->
            branch = BranchNamer.derive(bead)
            target_branch = resolve_target_branch(bead, opts)

            case Worktree.create(repo_path, branch, target_branch) do
              {:ok, path} ->
                {:ok, path}

              {:error, {:git_failed, msg}} when is_binary(msg) ->
                if String.contains?(msg, "already exists") do
                  case Worktree.attach(repo_path, branch) do
                    {:ok, path} -> {:ok, path}
                    {:error, reason} -> {:error, {:worktree_failed, reason}}
                  end
                else
                  {:error, {:worktree_failed, {:git_failed, msg}}}
                end

              {:error, reason} ->
                {:error, {:worktree_failed, reason}}
            end
        end
    end
  end

  defp resolve_rig_path(_bead, nil), do: nil

  defp resolve_rig_path(%Issue{workspace_id: ws_id}, rig) when is_binary(rig) do
    workspace_rig_path(ws_id, rig) || application_rig_path(rig)
  end

  # Resolve the integration branch — the branch the worktree is cut from and
  # the one the completed branch merges back into. Both must agree, or a
  # worktree cut from `develop` would try to merge into `main`.
  #
  # Resolution order:
  #   1. Explicit `:base_branch` opt — kept as an escape hatch for callers
  #      (and tests) that know better than the workspace config.
  #   2. Bead's own `:target_branch` field — per-bead override.
  #   3. Per-rig default in workspace config — the `rig_paths` map entry can
  #      be a string (the path) or a `{"path" => ..., "target_branch" => ...}`
  #      map for an integration branch shared by every bead worked in that rig.
  #   4. Workspace merge config (`workspace.config["merge"]["base"]`) — the
  #      same key the `Refinery` reads when opening PRs, so the worktree base
  #      and the eventual PR base stay in lockstep.
  #   5. `"main"` — the default integration branch.
  defp resolve_target_branch(%Issue{} = bead, opts) do
    Keyword.get(opts, :base_branch) ||
      bead_target_branch(bead) ||
      workspace_rig_target(bead, Keyword.get(opts, :rig)) ||
      workspace_base_branch(bead) ||
      "main"
  end

  defp bead_target_branch(%Issue{target_branch: t}) when is_binary(t) and t != "", do: t
  defp bead_target_branch(_), do: nil

  defp workspace_base_branch(%Issue{workspace_id: nil}), do: nil

  defp workspace_base_branch(%Issue{workspace_id: ws_id}) do
    case load_workspace_config(ws_id) do
      %{} = config ->
        case get_in(config, ["merge", "base"]) do
          base when is_binary(base) and base != "" -> base
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp workspace_rig_target(_bead, nil), do: nil

  defp workspace_rig_target(%Issue{workspace_id: nil}, _rig), do: nil

  defp workspace_rig_target(%Issue{workspace_id: ws_id}, rig) when is_binary(rig) do
    case load_workspace_config(ws_id) do
      %{} = config ->
        rig_target_from_config(get_in(config, ["rig_paths", rig]))

      _ ->
        nil
    end
  end

  defp rig_target_from_config(%{"target_branch" => t}) when is_binary(t) and t != "", do: t
  defp rig_target_from_config(_), do: nil

  defp workspace_rig_path(nil, _rig), do: nil

  defp workspace_rig_path(ws_id, rig) do
    case load_workspace_config(ws_id) do
      %{} = config ->
        rig_path_from_config(get_in(config, ["rig_paths", rig]))

      _ ->
        nil
    end
  end

  defp rig_path_from_config(p) when is_binary(p) and p != "", do: p
  defp rig_path_from_config(%{"path" => p}) when is_binary(p) and p != "", do: p
  defp rig_path_from_config(_), do: nil

  defp application_rig_path(rig) do
    rig_paths = Application.get_env(:arbiter, :rig_paths, %{})
    rig_path_from_config(Map.get(rig_paths, rig))
  end

  defp load_workspace_config(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{config: %{} = config}} -> config
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Real-work rig resolution (bd-1ziw04): when start_claude: true the dispatch
  # MUST bind a rig — a no-rig idle stub does nothing and looks dispatched.
  #
  # Contract (approach b):
  #   * Explicit rig that resolves in :rig_paths → proceed.
  #   * Explicit rig that does NOT resolve     → {:error, {:rig_not_found, rig}}.
  #   * No rig, exactly one rig in :rig_paths  → auto-select, update opts.
  #   * No rig, zero rigs in :rig_paths        → {:error, :no_rig_configured}.
  #   * No rig, multiple rigs in :rig_paths    → {:error, {:ambiguous_rig, rigs}}.
  #
  # The check fires only for `start_claude: true` dispatches; a dry/manual sling
  # (no agent) is allowed to park without a rig.
  defp maybe_resolve_rig_for_real_work(%Issue{} = bead, opts) do
    case Keyword.get(opts, :start_claude, false) do
      false -> {:ok, opts}
      true -> resolve_rig_for_dispatch(bead, opts)
    end
  end

  defp resolve_rig_for_dispatch(%Issue{} = bead, opts) do
    case Keyword.get(opts, :rig) do
      rig when is_binary(rig) and rig != "" ->
        case resolve_rig_path(bead, rig) do
          nil -> {:error, {:rig_not_found, rig}}
          _path -> {:ok, opts}
        end

      _ ->
        case all_available_rigs(bead) do
          [] -> {:error, :no_rig_configured}
          [sole] -> {:ok, Keyword.put(opts, :rig, sole)}
          rigs -> {:error, {:ambiguous_rig, rigs}}
        end
    end
  end

  # Enumerate all rig names that have a resolvable path, drawn from:
  #   1. The bead's workspace config `rig_paths` map.
  #   2. The global Application env `:rig_paths` map.
  # Both sources are combined, de-duplicated, and sorted.
  defp all_available_rigs(%Issue{workspace_id: ws_id}) do
    ws_rigs =
      case load_workspace_config(ws_id) do
        %{"rig_paths" => rp} when is_map(rp) ->
          Enum.flat_map(rp, fn {k, v} ->
            if rig_path_from_config(v) != nil, do: [k], else: []
          end)

        _ ->
          []
      end

    app_rigs =
      :arbiter
      |> Application.get_env(:rig_paths, %{})
      |> Enum.flat_map(fn {k, v} ->
        if rig_path_from_config(v) != nil, do: [k], else: []
      end)

    (ws_rigs ++ app_rigs) |> Enum.uniq() |> Enum.sort()
  end

  # Pre-flight auth check (bd-awi4nw): before transitioning the bead and
  # dispatching a (paid, autonomous) acolyte, verify the agent CLI can
  # authenticate with a single cheap probe. If it can't — the confirmed
  # OAuth-expiry case where every spawn 401s — REFUSE to sling, escalate to the
  # Admiral with a re-auth remediation, and abort before any bead/worktree state
  # is mutated.
  #
  # Only runs on the real-agent path: skipped unless `start_claude: true`, and
  # skipped when a `:claude_command` test override is in play (no real CLI to
  # probe) unless the caller injects a `:probe_command`. Opt out entirely with
  # `preflight: false`.
  defp maybe_preflight(%Issue{} = bead, opts) do
    cond do
      Keyword.get(opts, :preflight, true) == false ->
        :ok

      not Keyword.get(opts, :start_claude, false) ->
        :ok

      Keyword.has_key?(opts, :claude_command) and not Keyword.has_key?(opts, :probe_command) ->
        :ok

      true ->
        run_preflight(bead, opts)
    end
  end

  defp run_preflight(%Issue{} = bead, opts) do
    workspace = load_workspace(bead)
    :ok = Agents.prepare(workspace, :agent)
    adapter = preflight_adapter(bead, workspace, opts)

    # bd-5wchp1: if the CredentialWarden already knows this adapter's creds are
    # expired, refuse immediately without re-running the expensive probe. The
    # guard is skipped when the warden isn't running (returns false by default).
    if Arbiter.Agents.CredentialWarden.expired?(adapter) do
      reason = known_expired_stop_reason()
      AdmiralNotifier.preflight_failed(preflight_snapshot(bead, opts), reason)
      {:error, {:auth_check_failed, reason}}
    else
      probe_opts = preflight_opts(opts)

      case Preflight.check(adapter, probe_opts) do
        :ok ->
          :ok

        :skipped ->
          :ok

        {:error, reason} ->
          AdmiralNotifier.preflight_failed(preflight_snapshot(bead, opts), reason)
          {:error, {:auth_check_failed, reason}}
      end
    end
  end

  defp known_expired_stop_reason do
    %StopReason{
      category: :auth_expired,
      summary: "credentials known-expired (CredentialWarden flagged expiry)",
      remediation:
        "Re-authenticate the agent CLI (Claude: `claude` login; Gemini: refresh GEMINI_API_KEY), " <>
          "then re-sling. Check `arb inbox` for the original expiry escalation.",
      exit_status: nil,
      signal: nil
    }
  end

  # Resolve the workspace's worker adapter so we probe the CLI that will
  # actually be slung. A test `:agent_adapter` override wins (lets a test point
  # the probe at a stub adapter without a workspace).
  defp preflight_adapter(_bead, workspace, opts) do
    case Keyword.get(opts, :agent_adapter) do
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> Agents.for_workspace(workspace)
    end
  end

  defp preflight_opts(opts) do
    opts
    |> Keyword.take([:probe_command, :probe_env, :timeout_ms, :api_key, :model, :model_tier])
  end

  defp preflight_snapshot(%Issue{id: id, workspace_id: ws_id}, opts) do
    %{
      bead_id: id,
      workspace_id: ws_id,
      rig: Keyword.get(opts, :rig),
      meta: %{}
    }
  end

  # Spawn a Claude subprocess in the worktree, attached to the polecat.
  #
  # **Opt-in only.** Defaults to `start_claude: false` so callers must
  # explicitly authorize the (paid, autonomous) agent invocation. The CLI
  # surfaces this via the `--with-claude` flag on `arb sling`.
  #
  # Requires a worktree (Layer 3) — returns `{:error, :missing_worktree}`
  # if start_claude is true but worktree_path is nil. This prevents
  # silently launching Claude with `cd: nil`.
  #
  # The `:claude_command` opt is the test escape hatch: when set, it
  # overrides the default streaming `claude` argv so tests can spawn `echo`
  # or a script instead of the real Claude CLI.
  defp maybe_start_claude(_bead, _polecat_pid, _worktree_path, opts)
       when not is_list(opts) do
    {:ok, nil}
  end

  defp maybe_start_claude(%Issue{} = bead, polecat_pid, worktree_path, opts) do
    case Keyword.get(opts, :start_claude, false) do
      false ->
        {:ok, nil}

      true ->
        # Review dispatches skip worktree provisioning but still need a real
        # cwd for the Claude port. Fall back to the rig's local checkout so
        # the reviewer has `git`/`gh`/etc. in scope; an unmapped rig with no
        # worktree is still rejected — there's nowhere to `cd` to.
        cwd = worktree_path || review_cwd(bead, opts)

        case cwd do
          nil ->
            {:error, :missing_worktree}

          path when is_binary(path) ->
            with {:ok, session_opts} <-
                   build_agent_session_opts(bead, polecat_pid, path, opts),
                 {:ok, port} <- ClaudeSession.start(session_opts) do
              # Move the polecat out of :idle so UI/CLI report a meaningful
              # status while Claude works. In claude_driven mode the Driver
              # never ticks the Machine, so without this nudge the polecat
              # would remain :idle until "arb done" flipped it to :completed.
              _ = Polecat.advance(polecat_pid, :claude)
              {:ok, port}
            else
              {:error, reason} -> {:error, {:claude_start_failed, reason}}
            end
        end
    end
  end

  # Resolve a sensible cwd for a review session that has no per-bead worktree.
  # Only fires when `review: true` is set so a regular sling without
  # provision_worktree still surfaces `:missing_worktree` instead of silently
  # running Claude in the rig's main checkout.
  defp review_cwd(%Issue{} = bead, opts) do
    case Keyword.get(opts, :review, false) do
      true -> resolve_rig_path(bead, Keyword.get(opts, :rig))
      _ -> nil
    end
  end

  # Resolve the agent for this bead through the `Arbiter.Agents` dispatcher
  # and the configured `Arbiter.Agents.Routing` policy, then assemble the
  # `ClaudeSession.start/1` options. This is the seam where model-tiering
  # and key-rotation enter the spawn — both default off, so a workspace
  # that hasn't opted in sees today's argv + env unchanged.
  #
  # The `:claude_command` opt (used by tests to spawn an echo script
  # instead of the real Claude CLI) bypasses the adapter entirely — it's a
  # raw argv override and the routing policy has nothing to add.
  defp build_agent_session_opts(%Issue{} = bead, polecat_pid, worktree_path, opts) do
    base = [owner: polecat_pid, worktree_path: worktree_path]

    case Keyword.get(opts, :claude_command) do
      cmd when is_list(cmd) ->
        {:ok, base ++ [command: cmd]}

      _ ->
        workspace = load_workspace(bead)
        :ok = Agents.prepare(workspace, :agent)

        choice =
          bead
          |> Routing.choose(workspace, %{})
          |> apply_model_override(Keyword.get(opts, :model))

        adapter = Agents.for_type(choice.type)

        # Resolve the spawn's security posture from the workspace (per-domain),
        # with an optional per-dispatch override from sling opts. Threaded into
        # the adapter so it bakes the right permission-mode + deny/allow into
        # the argv — no inheritance of the operator's ~/.claude (bd-9u10op).
        policy = SecurityPolicy.resolve(workspace, security_override(opts))

        agent_opts = agent_opts_from_choice(choice) ++ [security: policy]
        prompt = prompt_for_bead(bead, opts)

        routing_config = %{
          provider: Atom.to_string(choice.type),
          model: Keyword.get(agent_opts, :model),
          model_tier: Keyword.get(agent_opts, :model_tier),
          thinking: Keyword.get(agent_opts, :thinking)
        }

        Polecat.report(polecat_pid, :routing_config, routing_config)

        case adapter.default_argv(prompt, agent_opts) do
          {:ok, argv} ->
            env = safe_spawn_env(adapter, agent_opts)
            {:ok, base ++ [command: argv, env: env]}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Translate a Routing.Policy.choice() config map (JSON string-keyed) into
  # the keyword opts the Agent behaviour expects (`:model`, `:model_tier`,
  # `:thinking`, ...). Unknown keys are passed through under `:config` so
  # future adapters can read adapter-specific keys without growing this
  # function.
  defp agent_opts_from_choice(%{config: config}) when is_map(config) do
    [
      model: Map.get(config, "model"),
      model_tier: Map.get(config, "model_tier"),
      thinking: Map.get(config, "thinking"),
      config: config
    ]
  end

  # A `:model` opt on `Sling.sling/2` is a one-shot, per-dispatch override —
  # the bead might be P2 (routing → sonnet) but the caller wants to try it
  # on Opus once. We splat the override on top of the routed config so it
  # wins over both the workspace default and any routing rule. A `nil` /
  # empty override is a no-op (the routed choice stands).
  defp apply_model_override(choice, override) when is_binary(override) and override != "" do
    %{choice | config: Map.put(choice.config || %{}, "model", override)}
  end

  defp apply_model_override(choice, _), do: choice

  # Optional per-dispatch (per-bead) security override. Accepts a raw map under
  # the `:security` sling opt (same shape as `workspace.config["agent"]["security"]`)
  # or the `:security_mode` shorthand for the common "just change the mode" case.
  # Returns `%{}` (no override) when neither is set.
  defp security_override(opts) do
    base =
      case Keyword.get(opts, :security) do
        %{} = map -> map
        _ -> %{}
      end

    case Keyword.get(opts, :security_mode) do
      mode when is_binary(mode) or (is_atom(mode) and not is_nil(mode)) ->
        Map.update(base, "permissions", %{"mode" => mode}, fn perms ->
          Map.put(perms, "mode", mode)
        end)

      _ ->
        base
    end
  end

  defp safe_spawn_env(adapter, agent_opts) do
    if function_exported?(adapter, :spawn_env, 1) do
      adapter.spawn_env(agent_opts)
    else
      []
    end
  end

  defp load_workspace(%Issue{workspace_id: nil}), do: nil

  defp load_workspace(%Issue{workspace_id: ws_id}) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  def prompt_for(%Issue{} = bead), do: prompt_for_bead(bead, [])

  @doc false
  def prompt_for_bead(%Issue{} = bead, opts) do
    case Keyword.get(opts, :review, false) do
      true -> review_prompt(bead)
      _ -> work_prompt(bead, opts)
    end
  end

  # When resuming (bd-auma3z) the work prompt is prefixed with a git-derived
  # briefing of the prior acolyte's committed + uncommitted work, so the fresh
  # agent continues from the preserved outpost instead of redoing finished
  # steps. `:resume_context` is built by `Arbiter.Polecat.ResumeContext`; it's
  # absent (empty prefix) on a normal fresh sling.
  defp work_prompt(%Issue{} = bead, opts) do
    resume_prefix = Keyword.get(opts, :resume_context) || ""
    resume_prefix <> base_work_prompt(bead)
  end

  defp base_work_prompt(%Issue{} = bead) do
    """
    You are a polecat working autonomously on bead #{bead.id}.

    Title: #{bead.title}

    Description:
    #{bead.description || "(none)"}

    Acceptance:
    #{bead.acceptance || "(none)"}

    Your current directory is a fresh git worktree on a per-bead branch.
    Work the bead to completion: load context, design, implement, test,
    commit on this branch, then push and open a PR if appropriate.
    #{completion_notes_step(bead)}
    Coordination: at the start of each step, check your mailbox by running

        arb inbox #{bead.id}

    This shows any direction from the Admiral or flags from sibling acolytes
    (e.g. an upstream API shape changed) and marks them read. To leave a flag
    for another acolyte, use `arb message <their-bead-id> <text>`.

    When you are completely done, print the line:

        arb done

    on a line by itself, exactly. The polecat watches your stdout and
    will mark the bead complete when it sees that marker.
    """
  end

  # For tracker-backed beads (an upstream Jira/etc. ticket), completing the
  # work includes producing the gated completion notes the tracker requires
  # before it will transition the ticket forward. We make this an explicit,
  # non-optional step in the acolyte's prompt and tell it exactly how to
  # persist the notes on the bead (`arb issue update`), so the downstream
  # tracker-sync has the fields to push. Untracked beads get nothing extra.
  defp completion_notes_step(%Issue{tracker_type: :none}), do: ""

  defp completion_notes_step(%Issue{tracker_ref: ref}) when ref in [nil, ""], do: ""

  defp completion_notes_step(%Issue{id: id}) do
    """

    This bead is backed by an external tracker ticket. Before you finish, you
    MUST produce its completion notes and persist them on the bead — the
    tracker gates the ticket's forward transition until both are filled:

        arb issue update #{id} \\
          --qa-notes "What QA should verify: the user-facing behaviour to
                      exercise, edge cases, and how to confirm the fix." \\
          --deployment-notes "Rollout considerations: DB migrations, feature
                      flags, config/env changes, ordering, and any backout
                      steps. Write 'None' only if there genuinely are none."

    Base the notes on the change you actually made. This is part of "done":
    do it before printing `arb done`.
    """
  end

  defp review_prompt(%Issue{} = bead) do
    tracker_line =
      case bead.pr_ref do
        pr when is_binary(pr) and pr != "" ->
          "Tracker ref (PR/MR to review): #{bead.tracker_type}:#{pr}\n\n"

        _ ->
          case bead.tracker_ref do
            ref when is_binary(ref) and ref != "" ->
              "Tracker ref (PR/MR to review): #{bead.tracker_type}:#{ref}\n\n"

            _ ->
              ""
          end
      end

    """
    You are a reviewer polecat. Review the pull/merge request linked to bead
    #{bead.id} and post a verdict. You are not the author; do not modify the
    branch.

    Title: #{bead.title}

    Description:
    #{bead.description || "(none)"}

    Acceptance:
    #{bead.acceptance || "(none)"}

    #{tracker_line}Your current directory is the rig's local checkout. There is
    no per-bead branch and no worktree was provisioned — this is a review-only
    directive.

    Steps:
      1. Read the PR/MR diff via the configured tracker's CLI (`gh pr diff
         <ref>` for GitHub, `glab mr diff <ref>` for GitLab, `git diff` for
         the Direct local strategy). Do not check out the branch.
      2. Identify real correctness, security, or contract issues against the
         bead's intent. Skip style nits.
      3. Post inline comments for each finding through the same tracker CLI.
      4. Post a single review-level verdict — `approve` or `request_changes`
         — with a one-paragraph summary.

    Forbidden:
      * Do NOT push code.
      * Do NOT merge or close the PR/MR.
      * Do NOT modify any branch, including the PR's head.

    When you are completely done, print the line:

        arb done

    on a line by itself, exactly.
    """
  end

  defp maybe_start_driver(
         %Issue{id: id},
         polecat_pid,
         machine_id,
         machine_pid,
         worktree_path,
         opts
       ) do
    case Keyword.get(opts, :start_driver, true) do
      false ->
        {:ok, nil}

      true ->
        # When Claude is in charge of doing the real work, the Driver
        # waits on the polecat's completion instead of ticking the
        # bookkeeping Machine to closure. This avoids the race where the
        # no-op workflow's 5 steps finish in ~500ms and close the bead
        # before Claude has time to respond.
        claude_driven =
          Keyword.get(opts, :claude_driven, Keyword.get(opts, :start_claude, false))

        driver_opts =
          [
            bead_id: id,
            polecat_pid: polecat_pid,
            machine_id: machine_id,
            machine_pid: machine_pid,
            worktree_path: worktree_path,
            cleanup_worktree: Keyword.get(opts, :cleanup_worktree, true),
            claude_driven: claude_driven
          ]
          |> maybe_put_opt(opts, :interval_ms)
          |> maybe_put_opt(opts, :max_ticks)

        case Driver.start(driver_opts) do
          {:ok, pid} -> {:ok, pid}
          {:error, reason} -> {:error, {:driver_start_failed, reason}}
        end
    end
  end

  defp maybe_put_opt(driver_opts, sling_opts, key) do
    case Keyword.fetch(sling_opts, key) do
      {:ok, val} -> Keyword.put(driver_opts, key, val)
      :error -> driver_opts
    end
  end
end
