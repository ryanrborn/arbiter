defmodule Arbiter.Workflows.PatrolServer do
  @moduledoc """
  Shared GenServer scaffold for patrol workers (bd-d825hp — resolving the
  duplication bd-4brb2j flagged between `PRPatrol` and `ReviewPatrol`):
  `start_link/1`, `tick/1`, `state/1`, the `:tick`/`:recheck` lazy-stop
  handling, adapter resolution, and the idle-backoff `schedule_next/1`.

  Each patrol keeps only its domain-specific tick logic by implementing this
  behaviour and calling `use Arbiter.Workflows.PatrolServer`:

      use Arbiter.Workflows.PatrolServer,
        priority_tag: :pr_patrol,
        log_label: "PRPatrol",
        no_work_message: "no open fleet-authored PR left to watch",
        recheck_stop_message: "last watched item closed",
        gate: :has_open_authored_pr?

      defstruct Arbiter.Workflows.PatrolServer.common_fields() ++ [...]

      @impl true
      def do_tick_body(state), do: ...

      @impl true
      def state_snapshot(state), do: %{...}

  `gate` names a public `(workspace_id, repo) :: boolean` function on the
  using module — the lazy-start/lazy-stop DB check (bd-7tr11p) — kept under
  its own domain-specific name (`has_open_authored_pr?/2`,
  `has_open_engagement?/2`) since callers outside the patrol reference it by
  that name too.
  """

  alias Arbiter.GitHub.Limiter
  alias Arbiter.Mergers
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.PatrolPacing

  @default_interval_ms 60_000
  @idle_backoff_ceiling_ms 15 * 60_000

  @doc "Struct fields shared by every patrol GenServer — prepend to the using module's `defstruct`."
  def common_fields do
    [
      :repo,
      :workspace_id,
      :workspace,
      :interval_ms,
      :timer_ref,
      ticks: 0,
      idle_ticks: 0,
      last_tick_at: nil
    ]
  end

  @doc """
  The common subset of `init/1`'s opts handling: reads `:repo`, `:workspace_id`,
  and `:interval_ms` (defaulting to #{@default_interval_ms}) from `opts`, and
  looks up the `Workspace`. Returns a keyword list to merge into the module's
  struct.
  """
  def base_init_fields(opts, default_interval_ms \\ @default_interval_ms) do
    repo = Keyword.fetch!(opts, :repo)
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    interval_ms = Keyword.get(opts, :interval_ms, default_interval_ms)

    [
      repo: repo,
      workspace_id: workspace_id,
      workspace: refetch_workspace(workspace_id),
      interval_ms: interval_ms
    ]
  end

  @doc "Re-fetch the workspace — call at the top of every tick so config changes apply without a restart."
  def refetch_workspace(workspace_id) do
    case Ash.get(Workspace, workspace_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  @doc false
  def resolve_adapter(workspace) do
    adapter = Mergers.for_workspace(workspace)

    # Force the adapter module to load before any `function_exported?/3` guard
    # inspects it. `function_exported?/3` returns false for a module that has
    # not been loaded yet and does NOT trigger loading — so under interactive
    # code loading (as in `mix test`) the guard would spuriously fail whenever
    # no prior call had loaded the adapter, no-op the whole tick, and dispatch
    # nothing. Releases run in embedded mode (all modules preloaded), which
    # masks this, but the guard must not depend on prior load order. See
    # bd-1hn1qw.
    Code.ensure_loaded(adapter)
    adapter
  rescue
    ArgumentError -> nil
  end

  @doc "Run `module.do_tick_body/1` tagged as background traffic for the limiter's priority report (bd-3p5vqc, bd-7qgxf9)."
  def do_tick(module, priority_tag, state) do
    Limiter.with_priority(:background, priority_tag, fn -> module.do_tick_body(state) end)
  end

  @doc """
  Delay until the next `:tick`: the idle-backed-off interval (bd-4brb2j —
  grows with consecutive idle ticks, capped at `idle_backoff_ceiling_ms`),
  then jittered +/- 15% so N patrols started within milliseconds of each
  other at boot drift apart instead of ticking in lockstep forever.
  """
  def schedule_next(state, idle_backoff_ceiling_ms \\ @idle_backoff_ceiling_ms) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    delay =
      state.idle_ticks
      |> PatrolPacing.idle_backoff_ms(state.interval_ms, idle_backoff_ceiling_ms)
      |> PatrolPacing.jitter()

    ref = Process.send_after(self(), :tick, delay)
    %{state | timer_ref: ref}
  end

  @doc "One patrol cycle. Threads any per-cycle bookkeeping (dispatch backoff, idle streak, ...) through the returned state."
  @callback do_tick_body(state :: struct()) :: struct()

  @doc "The domain-specific reply for `state/1` — the public snapshot map, not the raw struct."
  @callback state_snapshot(state :: struct()) :: map()

  defmacro __using__(opts) do
    priority_tag = Keyword.fetch!(opts, :priority_tag)
    log_label = Keyword.fetch!(opts, :log_label)
    no_work_message = Keyword.fetch!(opts, :no_work_message)
    recheck_stop_message = Keyword.fetch!(opts, :recheck_stop_message)
    gate = Keyword.fetch!(opts, :gate)

    quote do
      use GenServer, restart: :transient
      @behaviour Arbiter.Workflows.PatrolServer

      # ---- public API ----

      def start_link(opts) do
        {name, opts} = Keyword.pop(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @doc "Synchronously force a patrol cycle. Returns :ok after the cycle completes."
      def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

      @doc "Snapshot of internal state."
      def state(server \\ __MODULE__), do: GenServer.call(server, :state)

      # ---- GenServer callbacks ----

      @impl true
      def handle_call(:tick, _from, state) do
        new_state =
          Arbiter.Workflows.PatrolServer.do_tick(__MODULE__, unquote(priority_tag), state)

        {:reply, :ok, new_state}
      end

      def handle_call(:state, _from, state), do: {:reply, state_snapshot(state), state}

      # Lazy-stop gate (bd-7tr11p): re-check — with a cheap DB read, NOT a
      # forge call — whether this repo still has watchable work. When it
      # doesn't, terminate before touching GitHub, so an idle repo's patrol
      # makes zero background requests on the tick that reaps it.
      # `:transient` restart keeps it down; a crash still restarts.
      @impl true
      def handle_info(:tick, state) do
        if unquote(gate)(state.workspace_id, state.repo) do
          new_state =
            __MODULE__
            |> Arbiter.Workflows.PatrolServer.do_tick(unquote(priority_tag), state)
            |> schedule_next()

          {:noreply, new_state}
        else
          require Logger

          Logger.info(
            "#{unquote(log_label)}[#{state.repo}]: stopping — #{unquote(no_work_message)} " <>
              "(workspace #{state.workspace_id})"
          )

          {:stop, :normal, state}
        end
      end

      # Prompt lazy-stop nudge (bd-7tr11p): sent when a watched item in this
      # workspace closes, so the patrol re-checks and terminates immediately
      # rather than waiting for its next (idle-backed-off) scheduled tick. No
      # forge call — pure DB re-check. A no-op when work remains.
      def handle_info(:recheck, state) do
        if unquote(gate)(state.workspace_id, state.repo) do
          {:noreply, state}
        else
          require Logger

          Logger.info(
            "#{unquote(log_label)}[#{state.repo}]: stopping — #{unquote(recheck_stop_message)} " <>
              "(workspace #{state.workspace_id})"
          )

          {:stop, :normal, state}
        end
      end

      defp resolve_adapter(workspace),
        do: Arbiter.Workflows.PatrolServer.resolve_adapter(workspace)

      defp schedule_next(state), do: Arbiter.Workflows.PatrolServer.schedule_next(state)

      defoverridable resolve_adapter: 1, schedule_next: 1
    end
  end
end
