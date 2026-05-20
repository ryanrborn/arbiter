defmodule GtElixir.Polecat.Sling do
  @moduledoc """
  Spawn a polecat for a bead and attach it to the `GtElixir.Workflows.Work`
  workflow via `GtElixir.Workflows.Machine`.

  This is the "go work this bead" entry point — called by:

    * the `bd2 sling <bead-id>` CLI command (via the REST API),
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
     rig isn't in `:gt_elixir, :rig_paths` or `provision_worktree: false`.
  4. Start a polecat under `GtElixir.Polecat.Supervisor` for the bead.
  5. **Optionally** spawn a Claude subprocess in the worktree via
     `ClaudeSession.start/1`. Opt-in via `start_claude: true` — defaults
     to `false` to avoid silent paid-API invocations. Requires a worktree.
  6. Attach `GtElixir.Workflows.Work` via `Workflows.Machine.attach/3`
     and start the machine.
  7. Start a `GtElixir.Polecat.Driver` under the same supervisor — it
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

  alias GtElixir.Beads.Issue
  alias GtElixir.Beads.Workspace
  alias GtElixir.Polecat
  alias GtElixir.Polecat.BranchNamer
  alias GtElixir.Polecat.ClaudeSession
  alias GtElixir.Polecat.Driver
  alias GtElixir.Polecat.Worktree
  alias GtElixir.Workflows.Machine
  alias GtElixir.Workflows.Work

  @type sling_opts :: [
          rig: String.t() | nil,
          workflow_module: module(),
          start_driver: boolean(),
          start_claude: boolean(),
          claude_command: [String.t()] | nil,
          cleanup_worktree: boolean()
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
    with {:ok, bead} <- load_bead(bead_id),
         :ok <- ensure_not_closed(bead),
         {:ok, bead} <- transition_to_in_progress(bead),
         {:ok, worktree_path} <- maybe_provision_worktree(bead, opts),
         {:ok, polecat_pid} <- start_polecat(bead, opts),
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

  defp start_polecat(%Issue{id: id, workspace_id: ws_id} = _bead, opts) do
    rig = Keyword.get(opts, :rig) || "unknown"

    case Polecat.start(bead_id: id, rig: rig, workspace_id: ws_id) do
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

  # Provision a fresh git worktree on a per-bead branch.
  #
  # Behaviour:
  #   - `provision_worktree: false` in opts → skip, return `{:ok, nil}`.
  #   - rig has no mapping in workspace config or Application env → skip,
  #     return `{:ok, nil}` (the default no-op stance).
  #   - Otherwise, derive a branch name from the bead via `BranchNamer` and
  #     call `Worktree.create/3`. Returns `{:ok, path}` or `{:error, ...}`.
  #
  # ## Rig path lookup order
  #
  #   1. Bead's workspace config (`workspace.config["rig_paths"][rig]`)
  #      — per-workspace, runtime-settable, owns the source of truth.
  #   2. Application env (`:gt_elixir, :rig_paths`) — global fallback,
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
            base_branch = Keyword.get(opts, :base_branch, "main")

            case Worktree.create(repo_path, branch, base_branch) do
              {:ok, path} -> {:ok, path}
              {:error, reason} -> {:error, {:worktree_failed, reason}}
            end
        end
    end
  end

  defp resolve_rig_path(_bead, nil), do: nil

  defp resolve_rig_path(%Issue{workspace_id: ws_id}, rig) when is_binary(rig) do
    workspace_path(ws_id, rig) || application_path(rig)
  end

  defp workspace_path(nil, _rig), do: nil

  defp workspace_path(ws_id, rig) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{config: %{} = config}} ->
        case get_in(config, ["rig_paths", rig]) do
          path when is_binary(path) and path != "" -> path
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp application_path(rig) do
    rig_paths = Application.get_env(:gt_elixir, :rig_paths, %{})
    case Map.get(rig_paths, rig) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  # Spawn a Claude subprocess in the worktree, attached to the polecat.
  #
  # **Opt-in only.** Defaults to `start_claude: false` so callers must
  # explicitly authorize the (paid, autonomous) agent invocation. The CLI
  # surfaces this via the `--with-claude` flag on `bd2 sling`.
  #
  # Requires a worktree (Layer 3) — returns `{:error, :missing_worktree}`
  # if start_claude is true but worktree_path is nil. This prevents
  # silently launching Claude with `cd: nil`.
  #
  # The `:claude_command` opt is the test escape hatch: when set, it
  # overrides the default `["claude", "--print", prompt]` argv so tests
  # can spawn `echo` or a script instead of the real Claude CLI.
  defp maybe_start_claude(_bead, _polecat_pid, _worktree_path, opts)
       when not is_list(opts) do
    {:ok, nil}
  end

  defp maybe_start_claude(%Issue{} = bead, polecat_pid, worktree_path, opts) do
    case Keyword.get(opts, :start_claude, false) do
      false ->
        {:ok, nil}

      true when is_nil(worktree_path) ->
        {:error, :missing_worktree}

      true ->
        session_opts =
          [owner: polecat_pid, worktree_path: worktree_path] ++
            case Keyword.get(opts, :claude_command) do
              nil -> [prompt: prompt_for(bead)]
              cmd when is_list(cmd) -> [command: cmd]
            end

        case ClaudeSession.start(session_opts) do
          {:ok, port} -> {:ok, port}
          {:error, reason} -> {:error, {:claude_start_failed, reason}}
        end
    end
  end

  @doc false
  def prompt_for(%Issue{} = bead) do
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

    When you are completely done, print the line:

        gt done

    on a line by itself, exactly. The polecat watches your stdout and
    will mark the bead complete when it sees that marker.
    """
  end

  defp maybe_start_driver(%Issue{id: id}, polecat_pid, machine_id, machine_pid, worktree_path, opts) do
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
            cleanup_worktree: Keyword.get(opts, :cleanup_worktree, false),
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
