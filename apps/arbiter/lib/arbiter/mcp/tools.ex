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
  """

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Claim
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Graph
  alias Arbiter.Tasks.GraphMember
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.MCP
  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.ReviewAutomation
  alias Arbiter.Trackers
  alias Arbiter.Usage
  alias Arbiter.Workflows.Conductor
  alias Arbiter.Workflows.ConductorSupervisor

  require Ash.Query
  require Logger

  @progress_fields ~w(notes qa_notes deployment_notes pr_body)
  @message_kinds_mcp ~w(notification completion failure escalation info)a

  # ---- task_show ----------------------------------------------------------

  @doc "Read a single task. Worker: its own task only. Coordinator: any in its workspace."
  @spec task_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_show(%Scope{} = scope, args) do
    full = Map.get(args, "full") == true

    with {:ok, id} <- resolve_task_id(scope, args),
         {:ok, issue} <- fetch_task(scope, args, id) do
      loaded = load_progress(issue)
      result = if(full, do: serialize_task(loaded), else: serialize_task_slim(loaded))
      # Strip pr_body from coordinator full-view (bandwidth; coordinators don't
      # need the body they didn't write). Worker full-view retains it so the
      # worker can verify its own authored body (bd-53xrmi).
      result =
        if full and scope.tier == :coordinator,
          do: Map.delete(result, :pr_body),
          else: result

      {:ok, result}
    end
  end

  # ---- task_ready ---------------------------------------------------------

  @doc """
  List ready (unblocked, open) tasks in a workspace. Coordinator only. The
  workspace is resolved from the optional `workspace` arg, else the scope's bound
  workspace, else the installation default.
  """
  @spec task_ready(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_ready(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      tasks =
        [workspace_id: ws_id]
        |> Issue.ready()
        |> Enum.map(&serialize_task_summary/1)

      {:ok, %{tasks: tasks, count: length(tasks)}}
    end
  end

  # ---- inbox_check --------------------------------------------------------

  @doc """
  The unread mailbox for a task, marked read on read (the structured replacement
  for `arb inbox <task>`). Worker: its own task. Coordinator: the `task_id`
  argument, within its workspace.
  """
  @spec inbox_check(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def inbox_check(%Scope{} = scope, args) do
    with {:ok, to_ref} <- resolve_task_id(scope, args, "task_id"),
         {:ok, task} <- fetch_task(scope, args, to_ref) do
      messages = Message.inbox(to_ref, workspace_id: task.workspace_id)
      _ = Enum.each(messages, &Message.mark_read/1)

      {:ok,
       %{
         task_id: to_ref,
         messages: Enum.map(messages, &serialize_message/1),
         count: length(messages)
       }}
    end
  end

  # ---- coordinator_inbox --------------------------------------------------

  @doc """
  The unread Admiral escalation mailbox for the bound workspace, marked read on
  return — the structured replacement for `arb message inbox` / `arb inbox`.
  Coordinator only; the worker tier is denied at the catalog level.

  Lists all unread messages where `to_ref == "admiral"` in the workspace and
  marks each one read, so the dashboard unread count drops to 0. Optional
  `clear: true` also destroys the already-read tail (`Message.clear_read/2`),
  mirroring `arb inbox clear`.
  """
  @spec coordinator_inbox(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def coordinator_inbox(%Scope{} = scope, args) do
    with {:ok, clear} <- fetch_bool(args, "clear", false),
         {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      messages = Message.inbox("admiral", workspace_id: ws_id)
      _ = Enum.each(messages, &Message.mark_read/1)

      {deleted_read, deleted_unread, remaining_unread} =
        if clear do
          {:ok, dr, du, ru} = Message.clear_read("admiral", workspace_id: ws_id)
          {dr, du, ru}
        else
          {0, 0, 0}
        end

      {:ok,
       %{
         messages: Enum.map(messages, &serialize_message/1),
         count: length(messages),
         deleted_read: deleted_read,
         deleted_unread: deleted_unread,
         remaining_unread: remaining_unread
       }}
    end
  end

  # ---- coordinator_inbox_peek ------------------------------------------------

  @doc """
  The unread Admiral escalation mailbox for the bound workspace, read-only —
  lists unread messages without marking them read, so the dashboard unread
  count is unchanged. Coordinator only; the worker tier is denied at the
  catalog level. This is the read-only counterpart to `coordinator_inbox`.

  Lists all unread messages where `to_ref == "admiral"` in the workspace
  without mutating state. Use this for read-only consumers like briefing
  tools that must not affect the coordinator's unread count.
  """
  @spec coordinator_inbox_peek(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def coordinator_inbox_peek(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      messages = Message.inbox("admiral", workspace_id: ws_id)

      {:ok,
       %{
         messages: Enum.map(messages, &serialize_message/1),
         count: length(messages)
       }}
    end
  end

  # ---- workspace_show -----------------------------------------------------

  @doc """
  A workspace: config and the resolved worker security posture.
  Resolved from the optional `workspace` arg (name or id), else the scope's bound
  workspace, else the installation default. A workspace-bound scope (worker) can
  only ever inspect its own workspace.
  """
  @spec workspace_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_show(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      case Ash.get(Workspace, ws_id) do
        {:ok, %Workspace{} = ws} -> {:ok, serialize_workspace(ws)}
        _ -> {:error, {:not_found, "workspace #{ws_id} not found"}}
      end
    end
  end

  # ---- workspace_config_get ----------------------------------------------

  @doc """
  Read the full workspace config or a single dotted.key. Secret values are
  never returned — only secret_keys (the names of configured secrets) and any
  `credentials_ref` pointers already embedded in the config JSON.
  Resolved from the optional `workspace` arg, else the scope's bound workspace,
  else the installation default.
  """
  @spec workspace_config_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_get(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, ws} <- fetch_workspace(ws_id) do
      config = ws.config || %{}
      key = fetch_string(args, "key")

      value =
        if key do
          config_get_in_path(config, String.split(key, "."))
        else
          config
        end

      if key != nil and value == nil do
        {:error, {:not_found, "config key not found: #{key}"}}
      else
        {:ok,
         %{
           workspace: ws.name,
           key: key,
           value: value,
           secret_keys: workspace_secret_keys(ws)
         }}
      end
    end
  end

  # ---- workspace_config_overview ------------------------------------------

  @doc """
  A grouped summary of the workspace config: tracker, merge, agent,
  review_agent, routing, review, review_gate, standing_orders, and the names
  of configured secrets (values never exposed). Mirrors `arb config overview`.
  Resolved from the optional `workspace` arg like `workspace_show`.
  """
  @spec workspace_config_overview(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_overview(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, ws} <- fetch_workspace(ws_id) do
      config = ws.config || %{}

      {:ok,
       %{
         workspace: %{id: ws.id, name: ws.name, prefix: ws.prefix},
         tracker: Map.get(config, "tracker", %{}),
         merge: Map.get(config, "merge", %{}),
         agent: Map.get(config, "agent", %{}),
         review_agent: Map.get(config, "review_agent", %{}),
         routing: Map.get(config, "routing", %{}),
         review: Map.get(config, "review", %{}),
         review_gate: Map.get(config, "review_gate", %{}),
         standing_orders: Map.get(config, "standing_orders", []),
         secret_keys: workspace_secret_keys(ws)
       }}
    end
  end

  # ---- workspace_config_set -----------------------------------------------

  @doc """
  Set a single dotted.key to a value via the deep-merge config endpoint.
  Coordinator only (enforced in `Arbiter.MCP.Catalog`). Sibling keys are
  preserved — this uses `PATCH /api/workspaces/:id/config`, not the
  whole-map replace path. Secret / credential top-level key prefixes are
  blocked; route those through `arb workspace secret`.
  Returns the workspace identity, the full updated config, and secret_keys.
  """
  @spec workspace_config_set(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_set(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, key} <- require_string(args, "key"),
         {:ok, value} <- require_config_value(args),
         :ok <- deny_secret_path(key),
         {:ok, ws} <- fetch_workspace(ws_id) do
      patch = config_put_in_path(%{}, String.split(key, "."), value)

      case Ash.update(ws, %{patch: patch, unset_paths: []}, action: :patch_config) do
        {:ok, updated} -> {:ok, serialize_workspace_config(updated)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- workspace_config_unset ---------------------------------------------

  @doc """
  Remove a single dotted.key from the config via the deep-merge endpoint.
  Coordinator only (enforced in `Arbiter.MCP.Catalog`). Sibling keys are
  preserved. Returns the workspace identity, the full updated config, and
  secret_keys. Errors if the key does not exist in the current config.
  """
  @spec workspace_config_unset(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def workspace_config_unset(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, key} <- require_string(args, "key"),
         :ok <- deny_secret_path(key),
         {:ok, ws} <- fetch_workspace(ws_id) do
      config = ws.config || %{}
      path = String.split(key, ".")

      if config_get_in_path(config, path) == nil do
        {:error, {:invalid, "config key not found: #{key}"}}
      else
        case Ash.update(ws, %{patch: %{}, unset_paths: [key]}, action: :patch_config) do
          {:ok, updated} -> {:ok, serialize_workspace_config(updated)}
          {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
        end
      end
    end
  end

  # ---- installation_config_get --------------------------------------------

  @install_settings_keys ~w(conductor_system_max_concurrent)

  @doc """
  Read an install-wide runtime setting (bd-2ogep0) — currently just
  `conductor_system_max_concurrent`, the Conductor's system-wide concurrency
  ceiling. Returns the full settings map when `key` is omitted. Available to
  both tiers (read-only, no workspace scoping — this is installation-wide).
  """
  @spec installation_config_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def installation_config_get(%Scope{} = _scope, args) do
    settings = %{
      conductor_system_max_concurrent: Arbiter.Settings.conductor_system_max_concurrent()
    }

    case fetch_string(args, "key") do
      nil ->
        {:ok, %{key: nil, value: settings, settings: settings}}

      key when key in @install_settings_keys ->
        {:ok,
         %{key: key, value: Map.get(settings, String.to_existing_atom(key)), settings: settings}}

      key ->
        {:error, {:not_found, "unknown installation setting: #{key}"}}
    end
  end

  # ---- installation_config_set --------------------------------------------

  @doc """
  Set an install-wide runtime setting (bd-2ogep0). Coordinator only (enforced
  in `Arbiter.MCP.Catalog`). Currently only `conductor_system_max_concurrent`
  is settable — a positive integer, or `null` to clear the override and fall
  back to the `:arbiter, :conductor_system_max_concurrent` application env /
  hardcoded default. Takes effect on the next Conductor drain cycle across
  every running graph — no restart required.
  """
  @spec installation_config_set(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def installation_config_set(%Scope{} = _scope, args) do
    with {:ok, key} <- require_string(args, "key"),
         :ok <- validate_install_key(key),
         {:ok, value} <- require_install_value(args) do
      case Arbiter.Settings.set_conductor_system_max_concurrent(value) do
        {:ok, updated} -> {:ok, %{key: key, value: updated}}
        {:error, reason} -> {:error, {:invalid, inspect(reason)}}
      end
    end
  end

  defp validate_install_key(key) when key in @install_settings_keys, do: :ok
  defp validate_install_key(key), do: {:error, {:invalid, "unknown installation setting: #{key}"}}

  defp require_install_value(args) do
    case Map.fetch(args, "value") do
      {:ok, nil} -> {:ok, nil}
      {:ok, n} when is_integer(n) and n > 0 -> {:ok, n}
      {:ok, _other} -> {:error, {:invalid, "value must be a positive integer or null"}}
      :error -> {:error, {:invalid, "value is required"}}
    end
  end

  # ---- skill_create -------------------------------------------------------

  @doc """
  Create a system-wide skill (bd-cj6i08). Coordinator only (enforced in
  `Arbiter.MCP.Catalog`). Requires `name` (unique, kebab-case) and `body`
  (markdown); optional `metadata` (object). The registry is NOT
  workspace-scoped — one definition is shared across the whole system.

  A `warning` is returned (non-fatal) when the name collides with a bundled
  skill; the create still succeeds.
  """
  @spec skill_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_create(%Scope{} = _scope, args) do
    with {:ok, name} <- require_string(args, "name"),
         {:ok, body} <- require_string(args, "body"),
         {:ok, code_only} <- fetch_optional_bool(args, "code_only") do
      attrs =
        %{"name" => name, "body" => body}
        |> maybe_put("metadata", fetch_map(args, "metadata"))
        |> maybe_put("activation_mode", fetch_string(args, "activation_mode"))
        |> maybe_put("code_only", code_only)

      case Arbiter.Skills.create_skill(attrs) do
        {:ok, skill} ->
          Logger.info("[skill_create] skill #{skill.id} (#{skill.name}) created")
          {:ok, skill |> serialize_skill() |> with_bundled_warning(skill.name)}

        {:error, err} ->
          {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- skill_update -------------------------------------------------------

  @doc """
  Update a system-wide skill by `skill` (id or name). Coordinator only. Any
  subset of `name` / `body` / `metadata` may be supplied. Returns the updated
  skill, with a non-fatal bundled-collision `warning` when the (new) name
  collides with a bundled skill.
  """
  @spec skill_update(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_update(%Scope{} = _scope, args) do
    with {:ok, ref} <- require_string(args, "skill"),
         {:ok, skill} <- fetch_skill(ref),
         {:ok, code_only} <- fetch_optional_bool(args, "code_only") do
      attrs =
        %{}
        |> maybe_put("name", fetch_string(args, "name"))
        |> maybe_put("body", fetch_string(args, "body"))
        |> maybe_put("metadata", fetch_map(args, "metadata"))
        |> maybe_put("activation_mode", fetch_string(args, "activation_mode"))
        |> maybe_put("code_only", code_only)

      case Arbiter.Skills.update_skill(skill, attrs) do
        {:ok, updated} ->
          Logger.info("[skill_update] skill #{updated.id} (#{updated.name}) updated")
          {:ok, updated |> serialize_skill() |> with_bundled_warning(updated.name)}

        {:error, err} ->
          {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- skill_delete -------------------------------------------------------

  @doc """
  Delete a system-wide skill by `skill` (id or name). Coordinator only.
  Returns `{deleted: true, id, name}`.
  """
  @spec skill_delete(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_delete(%Scope{} = _scope, args) do
    with {:ok, ref} <- require_string(args, "skill"),
         {:ok, skill} <- fetch_skill(ref) do
      case Arbiter.Skills.delete_skill(skill) do
        :ok ->
          Logger.info("[skill_delete] skill #{skill.id} (#{skill.name}) deleted")
          {:ok, %{deleted: true, id: skill.id, name: skill.name}}

        {:error, err} ->
          {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  defp fetch_skill(ref) do
    case Arbiter.Skills.get_skill(ref) do
      {:ok, skill} -> {:ok, skill}
      {:error, :not_found} -> {:error, {:not_found, "no skill matching #{inspect(ref)}"}}
    end
  end

  # ---- skill_list -----------------------------------------------------------

  @doc """
  List all system-wide skills (names + metadata, no `body`), ordered by name.
  Available to both tiers — a coordinator or any worker can discover what's
  in the registry on demand, the same source of truth as worktree
  materialization.
  """
  @spec skill_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_list(%Scope{} = _scope, _args) do
    skills = Arbiter.Skills.list_skills() |> Enum.map(&serialize_skill_summary/1)
    {:ok, %{skills: skills, count: length(skills)}}
  end

  # ---- skill_get ------------------------------------------------------------

  @doc """
  Fetch one system-wide skill's full markdown body by `skill` (id or name).
  Available to both tiers, so the coordinator (which is not worktree-isolated
  and can't rely on materialization) or any agent can pull a skill body on
  demand from the same registry workers are materialized from.
  """
  @spec skill_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def skill_get(%Scope{} = _scope, args) do
    with {:ok, ref} <- require_string(args, "skill"),
         {:ok, skill} <- fetch_skill(ref) do
      {:ok, serialize_skill(skill)}
    end
  end

  defp serialize_skill_summary(%Arbiter.Skills.Skill{} = skill) do
    %{
      id: skill.id,
      name: skill.name,
      metadata: skill.metadata || %{},
      activation_mode: skill.activation_mode,
      code_only: skill.code_only,
      created_at: iso(skill.created_at),
      updated_at: iso(skill.updated_at)
    }
  end

  defp serialize_skill(%Arbiter.Skills.Skill{} = skill) do
    %{
      id: skill.id,
      name: skill.name,
      body: skill.body,
      metadata: skill.metadata || %{},
      activation_mode: skill.activation_mode,
      code_only: skill.code_only,
      created_at: iso(skill.created_at),
      updated_at: iso(skill.updated_at)
    }
  end

  # Attach a non-fatal bundled-skill collision warning to a serialized skill,
  # or leave it untouched when there is no collision.
  defp with_bundled_warning(map, name) do
    case Arbiter.Skills.bundled_collision(name) do
      nil -> map
      warning -> Map.put(map, :warning, warning)
    end
  end

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

  # ---- task_update_progress ----------------------------------------------

  @doc """
  The worker's one write: record `notes` / `qa_notes` / `deployment_notes` /
  `pr_body` on its own task (the structured replacement for `arb issue update
  <id> --qa-notes …`). It cannot flip status, reprioritize, or touch another
  task. Coordinator: the same narrow write against any task in its workspace.
  """
  @spec task_update_progress(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_update_progress(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_task_id(scope, args),
         {:ok, issue} <- fetch_task(scope, args, id),
         {:ok, attrs} <- progress_attrs(args) do
      case Ash.update(issue, attrs, action: :update) do
        {:ok, updated} -> {:ok, serialize_task_summary(updated)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ======================================================================
  # Phase 2 — coordinator-only mutating tools (docs/mcp-server-design.md §8)
  # ======================================================================

  # ---- task_create --------------------------------------------------------

  @doc """
  Create a task in a workspace. Coordinator only. The target workspace is
  resolved from the optional `workspace` arg (name or id), else the scope's bound
  workspace, else the installation default — and `workspace_id` is then forced
  onto the task. Backs onto `Ash.create(Issue, …)` (the same path `arb create` /
  the REST `POST /api/issues` take), so a workspace with a tracker configured
  still mirrors the new task upstream.
  """
  @spec task_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_create(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, title} <- require_string(args, "title"),
         {:ok, attrs} <- collect_attrs(args, task_create_spec()) do
      attrs = attrs |> Map.put("title", title) |> Map.put("workspace_id", ws_id)

      case Ash.create(Issue, attrs) do
        {:ok, issue} -> {:ok, serialize_task_summary(issue)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- task_update --------------------------------------------------------

  @doc """
  Update a task in the scope's workspace (status / priority / title / …).
  Coordinator only. The `:closed` status is rejected here — closing goes through
  `task_close`, which runs the close FSM + teardown. Backs onto the task's
  `:update` action.
  """
  @spec task_update(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_update(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_task_id(scope, args),
         {:ok, issue} <- fetch_task(scope, args, id),
         {:ok, attrs} <- collect_attrs(args, task_update_spec()),
         :ok <- require_some(attrs, "provide at least one field to update") do
      case Ash.update(issue, attrs, action: :update) do
        {:ok, updated} -> {:ok, serialize_task_summary(updated)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- task_close ---------------------------------------------------------

  @doc """
  Close a task in the scope's workspace via the `:close` action (sets status,
  runs the worker/worktree teardown, and optionally syncs the close upstream
  when `close_upstream: true`). Coordinator only.
  """
  @spec task_close(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_close(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_task_id(scope, args),
         {:ok, issue} <- fetch_task(scope, args, id),
         {:ok, close_upstream} <- fetch_bool(args, "close_upstream", false) do
      attrs =
        %{close_upstream: close_upstream}
        |> maybe_put(:reason, fetch_string(args, "reason"))

      case Ash.update(issue, attrs, action: :close) do
        {:ok, closed} -> {:ok, serialize_task_summary(closed)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- task_reopen --------------------------------------------------------

  @doc """
  Reopen a closed task in the scope's workspace via the `:reopen` action (clears
  `closed_at`, returns it to `:open` and the ready queue, and best-effort
  reopens the linked tracker issue). Coordinator only. Reopening is the only
  supported path out of `:closed` — the `:update` FSM rejects that transition —
  so a non-closed task is reported as an operational error.
  """
  @spec task_reopen(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_reopen(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_task_id(scope, args),
         {:ok, issue} <- fetch_task(scope, args, id) do
      case Ash.update(issue, %{}, action: :reopen) do
        {:ok, reopened} -> {:ok, serialize_task_summary(reopened)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- task_sync_upstream_close --------------------------------------------

  @doc """
  Push a close to the linked tracker for a task that's already `:closed`
  locally but never synced upstream. Coordinator only. Backs onto the
  `:sync_upstream_close` action, which requires the task to already be
  `:closed` — a non-closed task is reported as an operational error — and
  makes no local status/closed_at change or close-time side effect (no
  StopWorker/CleanupWorktree/parent rollup).
  """
  @spec task_sync_upstream_close(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def task_sync_upstream_close(%Scope{} = scope, args) do
    with {:ok, id} <- resolve_task_id(scope, args),
         {:ok, issue} <- fetch_task(scope, args, id) do
      case Ash.update(issue, %{}, action: :sync_upstream_close) do
        {:ok, synced} -> {:ok, serialize_task_summary(synced)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- dep_add ------------------------------------------------------------

  @doc """
  Add a dependency edge between two tasks in the scope's workspace. Coordinator
  only. Both endpoints must resolve inside the workspace (a cross-workspace id is
  reported not-found). Backs onto `Ash.create(Dependency, …)`.
  """
  @spec dep_add(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_add(%Scope{} = scope, args) do
    with {:ok, from} <- require_string(args, "from_issue_id"),
         {:ok, to} <- require_string(args, "to_issue_id"),
         {:ok, type} <- require_enum(args, "type", Dependency.types()),
         {:ok, from_task} <- fetch_task(scope, args, from),
         {:ok, _to_task} <- fetch_task_in_workspace(from_task.workspace_id, to) do
      attrs =
        %{"from_issue_id" => from, "to_issue_id" => to, "type" => type}
        |> maybe_put("notes", fetch_string(args, "notes"))
        |> maybe_put("created_by", fetch_string(args, "created_by"))

      case Ash.create(Dependency, attrs) do
        {:ok, dep} -> {:ok, serialize_dependency(dep)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # ---- dep_remove ---------------------------------------------------------

  @doc """
  Remove dependency edges between two tasks in the scope's workspace. Coordinator
  only. With no `type` every edge between the pair is removed; with a `type`
  only that edge. Idempotent — removing an absent edge reports `removed: 0`.
  """
  @spec dep_remove(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_remove(%Scope{} = scope, args) do
    with {:ok, from} <- require_string(args, "from_issue_id"),
         {:ok, to} <- require_string(args, "to_issue_id"),
         {:ok, type} <- optional_enum(args, "type", Dependency.types()),
         {:ok, from_task} <- fetch_task(scope, args, from),
         {:ok, _to_task} <- fetch_task_in_workspace(from_task.workspace_id, to) do
      edges = find_dep_edges(from, to, type)
      _ = Enum.each(edges, &Ash.destroy!/1)
      {:ok, %{from_issue_id: from, to_issue_id: to, removed: length(edges)}}
    end
  end

  # ---- message_send -------------------------------------------------------

  @doc """
  Send a message to a task's mailbox — the structured replacement for
  `arb message <task> <text>`. Available to **both** tiers, with the envelope
  set from the scope so the sender identity cannot be spoofed:

    * a **coordinator** sends a `:direction` from `"coordinator"` down to any
      task in its workspace;
    * a **worker** raises a `:flag` from its own bound task to a sibling.

  `workspace_id` is pinned to the recipient task's own workspace (a worker to
  its bound workspace), so a message can only ever be created alongside its
  recipient. Backs onto `Messages.send_mail/1`.
  """
  @spec message_send(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def message_send(%Scope{} = scope, args) do
    with {:ok, to_ref} <- require_string(args, "task_id"),
         {:ok, body} <- require_string(args, "body"),
         {:ok, ws_id} <- message_workspace(scope, args, to_ref),
         {:ok, kind} <- validate_message_kind(fetch_string(args, "kind")) do
      attrs =
        scope
        |> message_envelope(ws_id, to_ref, kind)
        |> Map.put(:body, body)
        |> maybe_put(:subject, fetch_string(args, "subject"))
        |> maybe_put(:directive_ref, fetch_string(args, "directive_ref"))

      case Message.send_mail(attrs) do
        {:ok, message} -> {:ok, serialize_message(message)}
        {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
      end
    end
  end

  # The workspace a message lands in. A worker is pinned to its bound workspace.
  # A coordinator infers it from the recipient task itself (entity inference,
  # honoring an explicit `workspace` arg), which also validates the recipient
  # exists and is reachable by the scope.
  defp message_workspace(%Scope{tier: :worker, workspace_id: ws_id}, _args, _to_ref),
    do: {:ok, ws_id}

  defp message_workspace(%Scope{tier: :coordinator} = scope, args, to_ref) do
    with {:ok, task} <- fetch_task(scope, args, to_ref), do: {:ok, task.workspace_id}
  end

  # The sender identity + kind are derived from the scope, never the client: a
  # coordinator directs (`from: "coordinator"`); a worker flags from its own
  # bound task. Both are pinned to the resolved workspace. When kind is
  # explicitly provided, it overrides the auto-derived default.
  defp message_envelope(%Scope{tier: :coordinator}, ws_id, to_ref, nil) do
    %{
      kind: :direction,
      workspace_id: ws_id,
      from_ref: "coordinator",
      to_ref: to_ref,
      directive_ref: to_ref
    }
  end

  defp message_envelope(%Scope{tier: :coordinator}, ws_id, to_ref, kind) when is_atom(kind) do
    %{
      kind: kind,
      workspace_id: ws_id,
      from_ref: "coordinator",
      to_ref: to_ref,
      directive_ref: to_ref
    }
  end

  defp message_envelope(%Scope{tier: :worker, task_id: task_id}, ws_id, to_ref, nil) do
    %{
      kind: :flag,
      workspace_id: ws_id,
      from_ref: task_id,
      to_ref: to_ref,
      directive_ref: to_ref
    }
  end

  defp message_envelope(%Scope{tier: :worker, task_id: task_id}, ws_id, to_ref, kind)
       when is_atom(kind) do
    %{
      kind: kind,
      workspace_id: ws_id,
      from_ref: task_id,
      to_ref: to_ref,
      directive_ref: to_ref
    }
  end

  # Validate and convert message kind from string to atom. Returns {:ok, nil}
  # if not specified (use auto-derived kind), or {:ok, atom} if valid, or
  # {:error, {_, msg}} if invalid.
  defp validate_message_kind(nil), do: {:ok, nil}

  defp validate_message_kind(kind_str) when is_binary(kind_str) do
    case to_allowed_atom(kind_str, @message_kinds_mcp) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid, "invalid kind #{inspect(kind_str)}"}}
    end
  end

  # ---- worker_dispatch ------------------------------------------------------

  @doc """
  Dispatch a worker to work a task in the scope's workspace. **Coordinator only,
  and the strongest-gated tool.** It enforces the dispatch-recursion guardrail
  (`docs/mcp-server-design.md` §4.3):

    1. The scope must carry `can_dispatch` — a coordinator minted without it (and
       every worker, which never carries it) is refused.
    2. The scope's `depth` must be below the configured `Arbiter.MCP.max_depth/0`
       — cheap insurance against a misconfigured coordinator fan-out.

  The slung worker's own scope token is minted one level deeper (`depth + 1`),
  so a chain of dispatches is tracked. When `provider` is omitted, the workspace's
  `agent.type` config is consulted and the first healthy provider is selected via
  `ProviderPool` — identical to the REST dispatch default. Pass an explicit
  `provider` (`"claude"` | `"gemini"`, or the deprecated `with_claude: true` alias)
  to override. Set `no_agent: true` to park the task `:in_progress` without
  spawning a worker (hand-off / manual-attach path).
  Backs onto `Arbiter.Worker.Dispatch.dispatch/2`.
  """
  @spec worker_dispatch(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_dispatch(%Scope{} = scope, args) do
    with :ok <- ensure_can_dispatch(scope),
         :ok <- ensure_dispatch_depth(scope),
         {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- fetch_task(scope, args, task_id) do
      case Dispatch.dispatch(task_id, worker_dispatch_opts(scope, args)) do
        {:ok, result} -> {:ok, serialize_dispatch(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, dispatch_error_message(reason)}}
      end
    end
  end

  # ---- worker_resume -----------------------------------------------------

  @doc """
  Re-attach a fresh worker to a task's **preserved** worktree
  (`arb resume`). Coordinator only, and — like `worker_dispatch` — gated by the
  dispatch-recursion guardrail (`can_dispatch` + `depth`): resume spawns a worker, so
  the same recursion concerns apply. The child worker's scope is minted one
  level deeper. Backs onto `Arbiter.Worker.Dispatch.resume/2`.
  """
  @spec worker_resume(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_resume(%Scope{} = scope, args) do
    with :ok <- ensure_can_dispatch(scope),
         :ok <- ensure_dispatch_depth(scope),
         {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- fetch_task(scope, args, task_id) do
      case Dispatch.resume(task_id, dispatch_opts(scope, args)) do
        {:ok, result} -> {:ok, serialize_dispatch(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, dispatch_error_message(reason)}}
      end
    end
  end

  # ---- worker_review -----------------------------------------------------

  @doc """
  Dispatch a **review-only** worker (`arb review`): no worktree, no per-task
  branch, no route through the merge queue/merger. Coordinator only, and gated
  by the dispatch-recursion guardrail (`can_dispatch` + `depth`) — a review
  spawns an agent.

  Two shapes:

    * `task_id` → review the PR/MR linked to a task. Backs onto
      `Arbiter.Worker.Dispatch.dispatch/2` with `review: true`; the child
      worker's scope is minted one level deeper.
    * `pr` (URL or number, + optional `repo`/`workspace`) → review an
      **external / non-arbiter PR** through the MR adapter
      (`Arbiter.Reviews.ExternalReview`): no task, no branch. Findings + a
      verdict are posted to the PR.
  """
  @spec worker_review(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_review(%Scope{} = scope, args) do
    case fetch_string(args, "pr") do
      pr when is_binary(pr) -> worker_review_external(scope, args, pr)
      _ -> worker_review_task(scope, args)
    end
  end

  defp worker_review_task(%Scope{} = scope, args) do
    with :ok <- ensure_can_dispatch(scope),
         :ok <- ensure_dispatch_depth(scope),
         {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         {:ok, task} <- fetch_task(scope, args, task_id),
         {:ok, task} <- maybe_set_tracker_context(task, args),
         {:ok, _} <- persist_review_automation(task, scope, args) do
      opts =
        scope
        |> dispatch_opts(args)
        |> Keyword.put(:review, true)
        |> review_claude_flag(args)

      case Dispatch.dispatch(task_id, opts) do
        {:ok, result} -> {:ok, serialize_dispatch(result, scope.depth + 1)}
        {:error, reason} -> {:error, {:invalid, dispatch_error_message(reason)}}
      end
    end
  end

  # Resolve and persist the review_automation mode on the engagement task.
  #
  # Resolution order (most-specific wins):
  #   1. An explicit `automation` arg passed to `worker_review` — hard override.
  #   2. The workspace's `review_automation.repo_overrides[repo]` — per-repo hard gate.
  #   3. The workspace's `review_automation.auto_authors` list, then `default`.
  #   4. No config → :flag (conservative: never auto-post unless explicitly trusted).
  #
  # The result is written to `task.review_automation` so the ReviewPatrol poller
  # can read it from the task without re-loading workspace config on each cycle.
  defp persist_review_automation(task, scope, args) do
    mode = resolve_review_automation_mode(scope, args)

    case Ash.update(task, %{review_automation: mode}) do
      {:ok, updated} -> {:ok, updated}
      {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
    end
  end

  defp resolve_review_automation_mode(scope, args) do
    case ReviewAutomation.normalize(fetch_string(args, "automation")) do
      mode when mode in [:auto, :report_only, :flag] ->
        mode

      nil ->
        pr_author = fetch_string(args, "pr_author")
        rig_name = fetch_string(args, "repo")
        ws_config = load_workspace_config(scope.workspace_id)
        ReviewAutomation.resolve(ws_config, pr_author, rig_name)
    end
  end

  defp load_workspace_config(nil), do: nil

  defp load_workspace_config(ws_id) do
    case Ash.get(Arbiter.Tasks.Workspace, ws_id) do
      {:ok, %{config: config}} -> config
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # If `tracker_context_ref` is provided in args, persist it (and optionally
  # `tracker_context_type`) on the task before dispatch so the review prompt
  # can fetch the ticket's acceptance criteria. When `tracker_context_type` is
  # omitted, the workspace's default tracker type is used as the fallback —
  # the most common case (reviewee and reviewer share the same tracker).
  defp maybe_set_tracker_context(task, args) do
    case fetch_string(args, "tracker_context_ref") do
      ref when is_binary(ref) and ref != "" ->
        context_type =
          case fetch_string(args, "tracker_context_type") do
            t when is_binary(t) and t != "" ->
              try do
                String.to_existing_atom(t)
              rescue
                ArgumentError -> nil
              end

            _ ->
              case fetch_workspace(task.workspace_id) do
                {:ok, ws} -> Trackers.workspace_type(ws)
                _ -> nil
              end
          end

        attrs =
          %{"tracker_context_ref" => ref}
          |> then(fn m ->
            if context_type, do: Map.put(m, "tracker_context_type", context_type), else: m
          end)

        case Ash.update(task, attrs, action: :update) do
          {:ok, updated} -> {:ok, updated}
          {:error, err} -> {:error, {:invalid, ash_error_message(err)}}
        end

      _ ->
        {:ok, task}
    end
  end

  # External PR review: same dispatch gating (it spawns a reviewer), but resolves
  # the MR provider from the (scope-bound or named) workspace rather than a task.
  #
  # `follow_up` (Option A, bd-2ovun1) makes the review adopt the PR into
  # ReviewPatrol by opening a review_only engagement after the verdict posts.
  # When the arg is omitted, ExternalReview engages by default only if the
  # workspace has a ReviewPatrol running. `automation` / `tracker_context_*`
  # mirror the task-review path and are carried onto that engagement.
  defp worker_review_external(%Scope{} = scope, args, pr) do
    with :ok <- ensure_can_dispatch(scope),
         :ok <- ensure_dispatch_depth(scope),
         {:ok, ws_ref} <- authorized_workspace(scope, args),
         {:ok, follow_up} <- fetch_optional_bool(args, "follow_up") do
      opts =
        [
          pr: pr,
          repo: fetch_string(args, "repo"),
          workspace: ws_ref,
          automation: fetch_string(args, "automation"),
          tracker_context_ref: fetch_string(args, "tracker_context_ref"),
          tracker_context_type: fetch_string(args, "tracker_context_type")
        ]
        |> maybe_put_kw(:follow_up, follow_up)

      case Arbiter.Reviews.ExternalReview.dispatch(opts) do
        {:ok, ack} ->
          {:ok, ack}

        {:error, reason} ->
          {:error, {:invalid, Arbiter.Reviews.ExternalReview.describe_error(reason)}}
      end
    end
  end

  # ---- worker_stop -------------------------------------------------------

  @doc """
  Stop the worker currently working a task (`arb worker stop`). Coordinator
  only. The task is resolved through `fetch_task`, so a coordinator can only
  stop workers for tasks in its own workspace; a task with no live worker is
  reported as not-found. Stopping is teardown — it never spawns — so it does not
  require `can_dispatch`. Backs onto `Arbiter.Worker.stop/2`.
  """
  @spec worker_stop(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_stop(%Scope{} = scope, args) do
    with {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- fetch_task(scope, args, task_id) do
      case Worker.stop(task_id, :normal) do
        :ok -> {:ok, %{task_id: task_id, stopped: true}}
        {:error, :not_found} -> {:error, {:not_found, "no running worker for task #{task_id}"}}
      end
    end
  end

  # ---- worker_list -------------------------------------------------------

  @doc """
  List active workers in the scope's workspace. Coordinator only. Backs onto
  `Arbiter.Worker.list_children/0`, filtered to the scope's workspace_id so a
  coordinator never sees workers running in other workspaces.
  """
  @spec worker_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args) do
      children =
        Arbiter.Worker.list_children()
        |> Enum.filter(&(&1.workspace_id == ws_id))

      task_ids = Enum.map(children, & &1.task_id)
      costs = Arbiter.Worker.Stats.task_costs_usd(task_ids)

      workers =
        Enum.map(children, &serialize_worker_summary(&1, Map.get(costs, &1.task_id, 0.0)))

      {:ok, %{workers: workers, count: length(workers)}}
    end
  end

  # ---- worker_show --------------------------------------------------------

  @doc """
  Full snapshot for a single task's worker (`arb worker show <task-id>`).
  When a worker is currently live, returns its in-memory state (status,
  activity, recent output lines, etc). Otherwise falls back to the most
  recent durable `Arbiter.Workers.Run` row so a finished/exited run stays
  inspectable. Not-found only when neither a live worker nor any run has
  ever been recorded for the task.
  """
  @spec worker_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_show(%Scope{} = scope, args) do
    with {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- fetch_task(scope, args, task_id) do
      case Worker.whereis(task_id) do
        nil ->
          worker_show_historical(task_id)

        pid ->
          case Worker.state(pid) do
            %{} = snap -> {:ok, serialize_worker_snapshot(Map.put(snap, :pid, pid))}
            _ -> worker_show_historical(task_id)
          end
      end
    end
  end

  defp worker_show_historical(task_id) do
    case latest_run(task_id) do
      %Arbiter.Workers.Run{} = run -> {:ok, serialize_worker_run(run)}
      nil -> {:error, {:not_found, "no worker found for task #{task_id}"}}
    end
  end

  defp latest_run(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  # ---- worker_runs ----------------------------------------------------------

  @doc """
  List every historical `Arbiter.Workers.Run` recorded for a task, newest
  first (`arb worker runs <task-id>`). Mirrors `GET /api/workers/history?task_id=`:
  each entry is a run summary (no `output_lines` — fetch a single run's full
  output via `worker_log` for the transcript). Optional `limit` (default 20,
  max 200).
  """
  @spec worker_runs(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_runs(%Scope{} = scope, args) do
    require Ash.Query

    with {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- fetch_task(scope, args, task_id),
         {:ok, limit} <- parse_bounded_limit(args, "limit", 20, 200) do
      runs =
        Arbiter.Workers.Run
        |> Ash.Query.filter(task_id == ^task_id)
        |> Ash.Query.sort(started_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      {:ok, %{runs: Enum.map(runs, &serialize_worker_run_summary/1)}}
    end
  end

  # ---- worker_log ------------------------------------------------------------

  @doc """
  Full, uncapped durable transcript of a task's most recent run (`arb worker
  log <task-id>`) — the audit source of record, retaining every line however
  long the run. `exists` distinguishes "no file yet / never captured" (false,
  empty `lines`) from "captured but empty" (true, empty `lines`). Not-found
  only when no run has ever been recorded for the task.
  """
  @spec worker_log(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def worker_log(%Scope{} = scope, args) do
    with {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         {:ok, _task} <- fetch_task(scope, args, task_id) do
      case latest_run(task_id) do
        %Arbiter.Workers.Run{} = run ->
          {exists, lines} =
            case Arbiter.Worker.OutputLog.read_lines(run.id) do
              {:ok, lines} -> {true, lines}
              {:error, _} -> {false, []}
            end

          {:ok,
           %{
             task_id: run.task_id,
             run_id: run.id,
             path: Arbiter.Worker.OutputLog.path_for(run.id),
             exists: exists,
             line_count: length(lines),
             lines: lines
           }}

        nil ->
          {:error, {:not_found, "no worker run found for task #{task_id}"}}
      end
    end
  end

  defp serialize_worker_run_summary(%Arbiter.Workers.Run{} = run) do
    %{
      id: run.id,
      task_id: run.task_id,
      task_title: run.task_title,
      repo: run.repo,
      workspace_id: run.workspace_id,
      worker_type: to_str(run.worker_type),
      status: to_str(run.status),
      model: run.model,
      started_at: iso(run.started_at),
      completed_at: iso(run.completed_at),
      exit_code: run.exit_code,
      failure_reason: run.failure_reason
    }
  end

  # ---- external_review_list -----------------------------------------------

  @doc """
  List recent ExternalReview audit records for the scope's workspace (bd-31fh9e).
  Coordinator only. Returns records newest-first. Optional `limit` (default 20,
  max 200) and `status` filter.
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

  defp serialize_external_review(%Arbiter.Reviews.Record{} = r) do
    %{
      id: r.id,
      pr_ref: r.pr_ref,
      pr: r.pr,
      workspace_id: r.workspace_id,
      strategy: r.strategy,
      link: r.link,
      status: r.status,
      mode: r.mode,
      greenlight_status: r.greenlight_status,
      proposed_count: length(r.proposed_comments || []),
      verdict: r.verdict,
      finding_count: r.finding_count,
      findings_summary: r.findings_summary,
      model: r.model,
      cost_usd: r.cost_usd,
      tokens_in: r.tokens_in,
      tokens_out: r.tokens_out,
      dispatched_by: r.dispatched_by,
      engagement_id: r.engagement_id,
      started_at: iso_dt(r.started_at),
      completed_at: iso_dt(r.completed_at)
    }
  end

  defp parse_bounded_limit(args, key, default, max) do
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
  only. `by` is required (one of `Arbiter.Usage.valid_groupings/0`); `since`
  (ISO-8601) and `limit` are optional. `workspace_id` is forced to the scope's
  workspace. Backs onto `Arbiter.Usage.summarize/1`.
  """
  @spec usage_summarize(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def usage_summarize(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, by} <- require_enum(args, "by", Usage.valid_groupings()),
         {:ok, since} <- optional_datetime(args, "since"),
         {:ok, limit} <- optional_integer(args, "limit") do
      opts =
        [by: by, workspace_id: ws_id]
        |> maybe_put_kw(:since, since)
        |> maybe_put_kw(:limit, limit)

      case Usage.summarize(opts) do
        {:ok, rollups} ->
          {:ok, %{by: Atom.to_string(by), rollups: rollups, count: length(rollups)}}

        {:error, reason} ->
          {:error, {:invalid, "usage_summarize failed: #{inspect(reason)}"}}
      end
    end
  end

  # ---- notify_list --------------------------------------------------------

  @doc """
  The most recent notifications (broadcast events: completions, milestones,
  system events) for the scope's workspace. Available to both tiers and always
  scoped to the bound workspace. Read-only — notifications are never consumed.
  Optional `limit` (default 20). Backs onto `Messages.recent_notifications/2`.
  """
  @spec notify_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def notify_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, limit} <- optional_integer(args, "limit") do
      notifications =
        (limit || 20)
        |> Message.recent_notifications(workspace_id: ws_id)
        |> Enum.map(&serialize_message/1)

      {:ok, %{notifications: notifications, count: length(notifications)}}
    end
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
  unassigned/closed get closed. Coordinator only. With `dry: true` the plan is
  returned without acting. No-ops cleanly when the tracker does not support
  reconciliation. Backs onto `Arbiter.Tasks.Claim.plan/1` + `apply_plan/2`.
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
          %{"rig_paths" => paths} when is_map(paths) -> paths
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
      case Ash.create(GraphMember, %{"graph_id" => graph_id, "issue_id" => issue_id}) do
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

  # ---- shared resolution / fetch -----------------------------------------

  # Resolve + authorize the target task id for this scope from the named arg
  # (default "id"). Worker: own task only; coordinator: id required.
  defp resolve_task_id(scope, args, key \\ "id") do
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
  defp fetch_task(scope, args, id) do
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
  defp fetch_task_in_workspace(ws_id, id) do
    case Ash.get(Issue, id) do
      {:ok, %Issue{workspace_id: ^ws_id} = issue} -> {:ok, issue}
      _ -> {:error, {:not_found, "task #{id} not found"}}
    end
  end

  # A `nil` target means "any workspace" (a workspace-agnostic coordinator that
  # named no workspace — the task's own workspace stands).
  defp workspace_match?(_ws, nil), do: true
  defp workspace_match?(ws, ws), do: true
  defp workspace_match?(_ws, _target), do: false

  # The workspace this call is authorized to operate in, honoring an optional
  # `workspace` arg (name or id). Returns `{:ok, ws_id}` where `ws_id` may be
  # `nil` — meaning the caller is a workspace-agnostic coordinator that named no
  # workspace, so entity inference / the installation default applies downstream.
  #
  # A scope bound to one workspace (every worker; a legacy workspace-bound
  # coordinator) may only ever resolve to its own workspace — naming a different
  # one is `{:error, {:unauthorized, …}}`.
  defp authorized_workspace(%Scope{} = scope, args) do
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
  defp resolve_workspace_id(%Scope{} = scope, args) do
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

  # Load the child-progress rollup calcs for a task so the serializer can emit
  # `child_total` / `child_closed`. Best-effort: on any load error the task is
  # returned unchanged (the serializer then omits the progress fields).
  defp load_progress(%Issue{} = issue) do
    Ash.load!(issue, [:child_total, :child_closed])
  rescue
    _ -> issue
  end

  # Keep only the three allowed progress fields; require at least one.
  defp progress_attrs(args) do
    attrs =
      for field <- @progress_fields, (val = fetch_string(args, field)) != nil, into: %{} do
        {String.to_existing_atom(field), val}
      end

    if map_size(attrs) == 0 do
      {:error, {:invalid, "provide at least one of: #{Enum.join(@progress_fields, ", ")}"}}
    else
      {:ok, attrs}
    end
  end

  # ---- Phase 2 arg coercion + validation ---------------------------------

  # Build a string-keyed attrs map from `args`, taking only the keys in `spec`
  # and coercing each to its declared type. Returns `{:ok, map}` or
  # `{:error, {:invalid, msg}}` on the first bad value. Absent keys are skipped.
  defp collect_attrs(args, spec) when is_map(args) do
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

  defp collect_attrs(_args, _spec), do: {:ok, %{}}

  defp coerce_field(:string, v) when is_binary(v), do: {:ok, v}
  defp coerce_field(:string, _), do: {:error, "must be a string"}

  defp coerce_field(:integer, v) when is_integer(v), do: {:ok, v}

  defp coerce_field(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end

  defp coerce_field(:integer, _), do: {:error, "must be an integer"}

  defp coerce_field(:boolean, v) when is_boolean(v), do: {:ok, v}
  defp coerce_field(:boolean, "true"), do: {:ok, true}
  defp coerce_field(:boolean, "false"), do: {:ok, false}
  defp coerce_field(:boolean, _), do: {:error, "must be a boolean"}

  defp coerce_field({:enum, allowed}, v) do
    case to_allowed_atom(v, allowed) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "must be one of: #{allowed_list(allowed)}"}
    end
  end

  # A required non-empty string argument.
  defp require_string(args, key) do
    case fetch_string(args, key) do
      nil -> {:error, {:invalid, "`#{key}` is required"}}
      s -> {:ok, s}
    end
  end

  # A required enum argument coerced against `allowed`.
  defp require_enum(args, key, allowed) do
    case fetch_string(args, key) do
      nil -> {:error, {:invalid, "`#{key}` is required"}}
      raw -> enum_or_error(raw, key, allowed)
    end
  end

  # An optional enum argument; `{:ok, nil}` when absent.
  defp optional_enum(args, key, allowed) do
    case fetch_string(args, key) do
      nil -> {:ok, nil}
      raw -> enum_or_error(raw, key, allowed)
    end
  end

  defp enum_or_error(raw, key, allowed) do
    case to_allowed_atom(raw, allowed) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid, "`#{key}` must be one of: #{allowed_list(allowed)}"}}
    end
  end

  defp optional_integer(args, key) do
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

  defp optional_datetime(args, key) do
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

  defp fetch_bool(args, key, default) do
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
  defp fetch_optional_bool(args, key) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      v when is_boolean(v) -> {:ok, v}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, {:invalid, "`#{key}` must be a boolean"}}
    end
  end

  defp require_some(attrs, msg) do
    if map_size(attrs) == 0, do: {:error, {:invalid, msg}}, else: :ok
  end

  defp to_allowed_atom(v, allowed) when is_binary(v) do
    atom = String.to_existing_atom(v)
    if atom in allowed, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp to_allowed_atom(_v, _allowed), do: :error

  defp allowed_list(allowed), do: Enum.map_join(allowed, ", ", &Atom.to_string/1)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_kw(kw, _key, nil), do: kw
  defp maybe_put_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # ---- Phase 2 field specs (arg key → coercion type) ---------------------

  defp task_create_spec do
    [
      {"description", :string},
      {"acceptance", :string},
      {"notes", :string},
      {"qa_notes", :string},
      {"deployment_notes", :string},
      {"priority", :integer},
      {"difficulty", :integer},
      {"issue_type", {:enum, Issue.issue_types()}},
      {"auto_close", :boolean},
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"assignee", :string},
      {"tracker_ref", :string},
      {"tracker_context_type", {:enum, Issue.tracker_types()}},
      {"tracker_context_ref", :string},
      {"target_branch", :string}
    ]
  end

  defp task_update_spec do
    [
      {"title", :string},
      {"description", :string},
      {"acceptance", :string},
      {"notes", :string},
      {"qa_notes", :string},
      {"deployment_notes", :string},
      {"status", {:enum, Issue.statuses()}},
      {"priority", :integer},
      {"difficulty", :integer},
      {"issue_type", {:enum, Issue.issue_types()}},
      {"auto_close", :boolean},
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"assignee", :string},
      {"tracker_ref", :string},
      {"tracker_context_type", {:enum, Issue.tracker_types()}},
      {"tracker_context_ref", :string},
      {"pr_ref", :string},
      {"target_branch", :string}
    ]
  end

  # ---- Phase 2 dispatch guardrail + opts (docs/mcp-server-design.md §4.3) ----

  defp ensure_can_dispatch(%Scope{can_dispatch: true}), do: :ok

  defp ensure_can_dispatch(%Scope{}),
    do: {:error, {:unauthorized, "this scope may not dispatch (can_dispatch is not set)"}}

  defp ensure_dispatch_depth(%Scope{depth: depth}) do
    max = MCP.max_depth()

    if depth < max,
      do: :ok,
      else: {:error, {:unauthorized, "dispatch depth limit (#{max}) reached"}}
  end

  # The opts common to every worker-dispatch tool (dispatch / resume / review):
  # the optional `repo` / `model` overrides plus the child scope depth, minted
  # one level deeper (`depth + 1`) so a chain of dispatches stays tracked.
  defp dispatch_opts(%Scope{depth: depth}, args) do
    [depth: depth + 1]
    |> maybe_put_kw(:repo, fetch_string(args, "repo"))
    |> maybe_put_kw(:model, fetch_string(args, "model"))
  end

  # Map `worker_dispatch` arguments onto `Dispatch.dispatch/2` opts, mirroring the
  # REST `POST /api/workers/dispatch` contract: an explicit `provider` (or deprecated
  # `with_claude`) forces that agent via `agent_type`; `no_agent: true` parks the
  # task `:in_progress` (hand-off path); otherwise the workspace's `agent.type`
  # config is used to pick the first healthy provider.
  defp worker_dispatch_opts(scope, args) do
    base = dispatch_opts(scope, args)

    case dispatch_provider(args) do
      :park ->
        Keyword.put(base, :start_driver, false)

      nil ->
        # No provider specified — resolve from workspace `agent.type` config.
        Keyword.put(base, :start_claude, true)

      type when is_atom(type) ->
        base |> Keyword.put(:start_claude, true) |> Keyword.put(:agent_type, type)
    end
  end

  # Resolve the worker provider from `worker_dispatch` args. Returns `:park` for
  # an explicit `no_agent` opt-in, a provider atom when specified via `provider`
  # or the deprecated `with_claude`, or `nil` to signal "use the workspace default".
  defp dispatch_provider(args) do
    cond do
      Map.get(args, "no_agent") in [true, "true"] ->
        :park

      Map.get(args, "provider") == "claude" ->
        :claude

      Map.get(args, "provider") == "gemini" ->
        :gemini

      Map.get(args, "provider") == "codex" ->
        :codex

      Map.get(args, "with_claude") in [true, "true"] ->
        :claude

      true ->
        nil
    end
  end

  # `worker_review` is claude-driven by default (a reviewer with no agent has
  # nothing to do), mirroring `POST /api/workers/review`. `with_claude: false`
  # dispatches the review without spawning an agent (the test affordance).
  defp review_claude_flag(opts, args) do
    case Map.get(args, "with_claude") do
      v when v in [false, "false"] -> Keyword.put(opts, :start_claude, false)
      _ -> Keyword.put(opts, :start_claude, true)
    end
  end

  defp dispatch_error_message({:task_closed, id}),
    do: "task #{id} is closed; reopen it before dispatching"

  defp dispatch_error_message(:no_repo_configured), do: "no repos configured for this workspace"

  defp dispatch_error_message({:repo_not_found, repo}),
    do: "repo #{inspect(repo)} is not configured"

  defp dispatch_error_message({:ambiguous_repo, repos}),
    do: "multiple repos available (#{Enum.join(repos, ", ")}); pass `repo` explicitly"

  defp dispatch_error_message({:task_awaiting_review, id}),
    do: "task #{id} is already awaiting review"

  # Resume-specific (`Dispatch.resume/2`).
  defp dispatch_error_message(:no_outpost),
    do: "no preserved worktree for this task — nothing to resume; dispatch it fresh instead"

  defp dispatch_error_message(:repo_unknown),
    do: "could not resolve the repo for this task; pass `repo` explicitly"

  defp dispatch_error_message({:acolyte_active, status}),
    do: "a worker is still active for this task (#{status}); stop it before resuming"

  defp dispatch_error_message(other), do: "dispatch failed: #{inspect(other)}"

  # ---- Phase 2 fetch helpers ---------------------------------------------

  defp find_dep_edges(from, to, nil) do
    Dependency
    |> Ash.Query.filter(from_issue_id == ^from and to_issue_id == ^to)
    |> Ash.read!()
  end

  defp find_dep_edges(from, to, type) do
    Dependency
    |> Ash.Query.filter(from_issue_id == ^from and to_issue_id == ^to and type == ^type)
    |> Ash.read!()
  end

  # The scope's own workspace, loaded for the tracker bridge tools.
  defp fetch_workspace(ws_id) do
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

  defp fetch_string(args, key) when is_map(args) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  defp fetch_string(_args, _key), do: nil

  # An optional map argument; nil when absent or not a map.
  defp fetch_map(args, key) when is_map(args) do
    case Map.get(args, key) do
      m when is_map(m) -> m
      _ -> nil
    end
  end

  defp fetch_map(_args, _key), do: nil

  # ---- workspace_config helpers -------------------------------------------

  # Sorted names of the workspace's configured secrets; values are never
  # returned. Mirrors ArbiterWeb.Api.WorkspaceJSON.secret_key_names/1.
  defp workspace_secret_keys(%Workspace{} = ws) do
    ws |> Workspace.secrets_map() |> Map.keys() |> Enum.sort()
  end

  # Top-level config key prefixes that the MCP write tools refuse to set.
  # Secrets live in the encrypted `secrets` column, not the config JSON;
  # routing them here would silently store a plaintext ref with no effect.
  defp deny_secret_path(key) when is_binary(key) do
    blocked = ~w(secret secrets credentials)
    prefix = key |> String.split(".") |> List.first() |> String.downcase()

    if prefix in blocked do
      {:error,
       {:unauthorized,
        "cannot set #{inspect(key)} via config tools — use `arb workspace secret` for secrets"}}
    else
      :ok
    end
  end

  # Fetch the `value` argument; accepts any JSON-decoded type (boolean,
  # integer, string, object, array, or null). Distinguishing absent from null
  # requires Map.fetch rather than Map.get.
  defp require_config_value(args) do
    case Map.fetch(args, "value") do
      :error -> {:error, {:invalid, "`value` is required"}}
      {:ok, v} -> {:ok, unwrap_stringified_json(v)}
    end
  end

  # Some MCP tool-calling clients serialize an array/object argument into a
  # JSON-encoded string before sending it (bd-1dtufq) rather than an actual
  # JSON array/object value, even though the tool's input_schema advertises
  # array/object as valid. Detect that shape and decode it, so
  # `agent.type: "[\"claude\", \"gemini\"]"` is treated the same as a real
  # `["claude", "gemini"]`. A string that merely starts with `[`/`{` but
  # isn't valid JSON, or decodes to a scalar, is left untouched — only
  # unambiguous list/map decodes are unwrapped.
  defp unwrap_stringified_json(v) when is_binary(v) do
    trimmed = String.trim(v)

    if String.starts_with?(trimmed, "[") or String.starts_with?(trimmed, "{") do
      case Jason.decode(trimmed) do
        {:ok, decoded} when is_list(decoded) or is_map(decoded) -> decoded
        _ -> v
      end
    else
      v
    end
  end

  defp unwrap_stringified_json(v), do: v

  # Build a nested map from a dotted-path segment list and a leaf value.
  defp config_put_in_path(map, [k], value) when is_map(map), do: Map.put(map, k, value)

  defp config_put_in_path(map, [k | rest], value) when is_map(map) do
    sub =
      case Map.get(map, k) do
        %{} = s -> s
        _ -> %{}
      end

    Map.put(map, k, config_put_in_path(sub, rest, value))
  end

  # Navigate a nested config map by path segments; nil if any segment is missing.
  defp config_get_in_path(value, []), do: value

  defp config_get_in_path(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      nil -> nil
      sub -> config_get_in_path(sub, rest)
    end
  end

  defp config_get_in_path(_, _), do: nil

  # The standard config result: workspace identity, full (secret-safe) config,
  # and the names of configured secrets so the caller can confirm the merge.
  defp serialize_workspace_config(%Workspace{} = ws) do
    %{
      workspace: %{id: ws.id, name: ws.name, prefix: ws.prefix},
      config: ws.config || %{},
      secret_keys: workspace_secret_keys(ws)
    }
  end

  # ---- serializers (JSON-friendly, mirroring the REST shapes) -------------

  defp serialize_task(%Issue{} = i) do
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
      workspace_id: i.workspace_id,
      closed_at: iso(i.closed_at),
      created_at: iso(i.created_at),
      updated_at: iso(i.updated_at)
    }
    |> put_progress(i)
  end

  # Slim serializer for worker task_show (full: false). Omits review/human
  # fields that bloat worker context without aiding task execution.
  defp serialize_task_slim(%Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      description: i.description,
      acceptance: i.acceptance,
      status: to_str(i.status),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: to_str(i.issue_type)
    }
    |> put_progress(i)
  end

  # Include the child-progress rollup when the calcs are loaded (task_show loads
  # them). Omitted when not loaded so other serialize paths stay cheap.
  defp put_progress(map, %Issue{child_total: t, child_closed: c})
       when is_integer(t) and is_integer(c) do
    Map.merge(map, %{child_total: t, child_closed: c, child_open: max(t - c, 0)})
  end

  defp put_progress(map, _i), do: map

  defp serialize_task_summary(%Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      status: to_str(i.status),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: to_str(i.issue_type)
    }
  end

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

  defp serialize_dependency(%Dependency{} = d) do
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

  # The dispatch result carries live pids/ports; render the JSON-safe subset (pids
  # inspected to strings), mirroring `ArbiterWeb.Api.WorkerJSON.dispatch/1`. `depth`
  # is the slung worker's scope depth (parent + 1).
  defp serialize_dispatch(result, depth) do
    %{
      task: serialize_task_summary(result.task),
      worker: %{task_id: result.task.id, pid: inspect(result.worker_pid)},
      machine: %{id: result.machine_id, pid: inspect(result.machine_pid)},
      worktree_path: result.worktree_path,
      claude_started: not is_nil(result.claude_port),
      depth: depth
    }
  end

  defp serialize_worker_summary(snap, cost_usd) do
    meta = Map.get(snap, :meta, %{}) || %{}
    routing = Map.get(meta, :routing_config) || %{}
    model_id = Map.get(meta, :model) || Map.get(routing, :model)

    %{
      task_id: snap.task_id,
      status: to_str(snap.status),
      repo: snap.repo,
      started_at: iso(snap.started_at),
      activity: Map.get(meta, :activity),
      provider: Map.get(meta, :provider) || Map.get(routing, :provider),
      model: Arbiter.Worker.Stats.short_model_name(model_id),
      cost_usd: cost_usd
    }
  end

  defp serialize_worker_snapshot(snap) do
    meta = Map.get(snap, :meta, %{}) || %{}

    %{
      source: "live",
      task_id: snap.task_id,
      workspace_id: snap.workspace_id,
      repo: snap.repo,
      current_step: snap.current_step,
      claude_session: Map.get(meta, :claude_session, false),
      activity: Map.get(meta, :activity),
      status: to_str(snap.status),
      started_at: iso(snap.started_at),
      step_started_at: iso(Map.get(snap, :step_started_at)),
      mr_ref: Map.get(snap, :mr_ref),
      merger_url: Map.get(snap, :merger_url),
      last_merger_status: Map.get(meta, :last_merger_status),
      last_checked_at: iso(Map.get(meta, :last_checked_at)),
      pid: inspect(snap.pid),
      output_lines: Map.get(meta, :output_lines, []),
      exit_status: Map.get(meta, :exit_status),
      exited_at: iso(Map.get(meta, :exited_at)),
      result: Map.get(meta, :result),
      failure_reason: stringify_reason(Map.get(meta, :failure_reason))
    }
  end

  defp serialize_worker_run(%Arbiter.Workers.Run{} = run) do
    %{
      source: "history",
      task_id: run.task_id,
      task_title: run.task_title,
      workspace_id: run.workspace_id,
      repo: run.repo,
      worker_type: to_str(run.worker_type),
      current_step: nil,
      claude_session: false,
      activity: nil,
      status: to_str(run.status),
      model: run.model,
      started_at: iso(run.started_at),
      completed_at: iso(run.completed_at),
      exit_status: run.exit_code,
      output_lines: run.output_lines || [],
      failure_reason: run.failure_reason
    }
  end

  defp stringify_reason(nil), do: nil
  defp stringify_reason(v) when is_binary(v), do: v
  defp stringify_reason(v), do: inspect(v)

  defp serialize_message(%Message{} = m) do
    %{
      id: m.id,
      kind: to_str(m.kind),
      from_ref: m.from_ref,
      to_ref: m.to_ref,
      subject: m.subject,
      body: m.body,
      directive_ref: m.directive_ref,
      inserted_at: iso(m.inserted_at)
    }
  end

  defp serialize_workspace(%Workspace{} = ws) do
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

  defp serialize_claim_result({:created, task}),
    do: %{outcome: "created", task: serialize_task_summary(task)}

  defp serialize_claim_result({:closed, task}),
    do: %{outcome: "closed", task: serialize_task_summary(task)}

  defp serialize_claim_result({:error, action, reason}),
    do: %{outcome: "error", action: serialize_claim_action(action), reason: inspect(reason)}

  defp to_str(nil), do: nil
  defp to_str(a) when is_atom(a), do: Atom.to_string(a)
  defp to_str(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  defp ash_error_message(%{__struct__: _} = err) do
    if is_exception(err), do: Exception.message(err), else: inspect(err)
  rescue
    _ -> "update failed"
  end

  defp ash_error_message(err), do: inspect(err)
end
