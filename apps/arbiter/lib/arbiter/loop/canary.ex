defmodule Arbiter.Loop.Canary do
  @moduledoc """
  **Stage 3** of the loop-engineering epic (#1011, task bd-6edc0u): the one
  narrow slice of the proposal queue that Arbiter is allowed to apply to itself
  without a human — a **routing-tier adjustment**, applied to a *subset* of
  dispatches, measured against the untouched arm, and reverted automatically if
  it makes things worse.

  Everything else in the queue stays operator-applied. Skill bodies are prose
  that gets materialized into every matching run's worktree and pulled into
  the agent's context (`worker_runs.resolved_skills` records which): they
  bloat that context and can contradict each other, so the epic keeps them
  on the slower human path. `standing_orders` is operator-applied
  for a different reason: it's coordinator-facing config (surfaced in `arb
  prime`, never injected into any worker prompt — see
  `ArbiterCli.ConfigSchema`), so there's no per-dispatch prompt effect to
  canary in the first place. A routing rule is numeric, bounded, trivially
  reversible, and directly measurable — which is why it goes first, and alone.

  ## The gate

  Nothing here runs unless the workspace sets

      loop.autonomous_routing_enabled: true

  It defaults to `false` on **every** workspace, including `default`. With the
  flag unset, `active/1` returns `nil`, the routing overlay is never consulted,
  and `tick/2` is `{:ok, :disabled}` — behaviour is byte-for-byte what it was
  before this module existed. Unsetting the flag mid-canary is the kill switch:
  the overlay stops on the very next dispatch, with no config unwinding needed.

  The kill switch is **terminal**, not a pause. The first `tick/2` after the
  flag goes away drops the `loop.canary` block (one write, once), because a
  paused canary is worse than no canary: while the flag is off both arms route
  identically, so every dispatch in that window is baseline in *both* arms. If
  the block survived, re-arming the flag would judge — and possibly promote —
  on a window that contains dispatches the canary never influenced. Re-enabling
  starts a clean canary with a fresh `started_at` instead.

  ## What is eligible

  A `PendingWrite` is eligible only when **all** of these hold (`eligible/1`):

    * it is `:proposed` — i.e. it already cleared the Stage 2 evidence bar and
      was escalated to the operator at least once. Autonomous application never
      lowers that bar, and never applies a finding the operator has not already
      seen as a Stage 2 proposal;
    * its evidence still clears the workspace's bar *on its own terms* — a
      `:task`-scoped row that bypassed the bar by blast radius is refused here,
      because a fleet-affecting routing change is not blast-radius 1;
    * it is a `:config_set` whose patch is exactly one `D<n>` tier's
      `model_tier` / `thinking` — no other config key, no second tier, no
      `unset_paths`;
    * its workspace routes `by_difficulty` (any other policy never reads
      `routing.rules`, so the canary would measure nothing).

  ## The canary

  `start/3` writes a `loop.canary` block to the workspace config — it does
  **not** write `routing.rules`. The rule is instead overlaid at dispatch time
  by `Arbiter.Agents.Routing.ByDifficulty`, and only for tasks in the canary
  arm (`arm/2`): a stable 50/50 split of task ids, salted with the proposal id.
  Alternating dispatches, rather than the repo-selection layer, because
  `Routing.choose/3` is not given the dispatch's repo — the arm has to be
  derivable from what routing actually has in hand, and from what
  `worker_runs` records afterwards, or the measurement and the application
  would disagree about who was in which arm.

  A task's `#review` / `#impl` runs hash into the same arm as the task itself,
  so a canaried task is never half-canaried.

  ## The verdict

  `evaluate/2` compares the two arms over the runs recorded since the canary
  started (`Arbiter.Loop.Canary.Metrics`):

    * **first-pass ReviewGate convergence** — the fraction of reviewed tasks
      whose round-1 review approved with nothing left unmet. This is the
      target metric;
    * **cost per review round** — reported alongside, never the trigger.

  No verdict is returned before the canary arm has at least 20 dispatches
  (`min_dispatches`, floor-clamped — a workspace may raise it, never lower it).
  At current fleet volume that is a multi-day window by design, not an instant
  flip. It is not, however, an *unbounded* one: a canary that has not gathered
  its sample within `loop.canary_max_age_days` (default 14) expires — the block
  is dropped, the proposal is soft-rejected with the reason, and the operator is
  mailed. A tier too quiet to measure must not keep an unvalidated rule live on
  half of its dispatches forever.

  Then:

    * canary convergence **below** control (beyond `regression_tolerance`,
      default `0.0`) → `:revert`. The canary block is removed, the proposal is
      soft-rejected with the measurement attached, and nothing was ever written
      to `routing.rules` — so the revert is a deletion, not a repair;
    * otherwise → `:promote`. The rule lands on `routing.rules.D<n>` for the
      whole workspace and the proposal moves to `:applied`.

  Both outcomes are a `paper_trail` version on `Workspace` with `actor` set to
  `loop:proposal:<id>`, so `arb workspace history` shows exactly which proposal
  moved the routing table and when it was taken back.
  """

  alias Arbiter.Agents.Routing
  alias Arbiter.Loop
  alias Arbiter.Loop.Canary.Metrics
  alias Arbiter.Loop.PendingWrite
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Workspace

  require Logger

  @enforce_keys [:proposal_id, :difficulty, :rule, :started_at]
  defstruct [
    :proposal_id,
    :difficulty,
    :rule,
    :baseline_rule,
    :started_at,
    arm_strategy: :alternating,
    min_dispatches: 20,
    regression_tolerance: 0.0,
    max_age_days: 14
  ]

  @type t :: %__MODULE__{}

  @type arm :: :canary | :control
  @type stats :: map()

  @flag_path ["loop", "autonomous_routing_enabled"]
  @canary_path ["loop", "canary"]

  # The epic's own number: fewer than this in the canary arm and the comparison
  # is noise. A workspace may raise it; it may never lower it.
  @min_dispatches 20

  # How far below control the canary arm's convergence may sit before it counts
  # as a regression. Beyond half the metric's own range the threshold would
  # forgive any conceivable drop, which is not a tolerance — it is autonomy
  # with the brake removed.
  @max_regression_tolerance 0.5

  # How long a canary may run without reaching `min_dispatches`. A multi-day
  # window is the design; an indefinite one is a rule nobody validated sitting
  # live on half a tier's dispatches with no second operator notice.
  @default_max_age_days 14

  # ...and the longest a workspace may stretch that. Past a quarter it is not a
  # deadline, it is the absence of one.
  @max_max_age_days 90

  # The knobs a canaried routing rule may carry. Anything else (a pinned
  # `model`, an adapter override) is out of scope for autonomous application.
  @rule_keys ~w(model_tier thinking)

  @doc "The floor on canary-arm dispatches before any verdict is possible."
  @spec min_dispatches() :: pos_integer()
  def min_dispatches, do: @min_dispatches

  @doc "The widest revert threshold a workspace may configure."
  @spec max_regression_tolerance() :: float()
  def max_regression_tolerance, do: @max_regression_tolerance

  @doc "How long a canary may run before it expires unjudged, by default."
  @spec default_max_age_days() :: pos_integer()
  def default_max_age_days, do: @default_max_age_days

  @doc "The longest expiry a workspace may configure."
  @spec max_age_days_ceiling() :: pos_integer()
  def max_age_days_ceiling, do: @max_max_age_days

  # ---- the flag -----------------------------------------------------------

  @doc """
  Whether this workspace has opted in to autonomous routing-tier application.

  Only the literal boolean `true` counts — a stray `"true"` string in config is
  not an opt-in.
  """
  @spec enabled?(Workspace.t() | map() | nil) :: boolean()
  def enabled?(%Workspace{config: config}), do: enabled?(config)
  def enabled?(config) when is_map(config), do: get_in(config, @flag_path) == true
  def enabled?(_), do: false

  # ---- the running canary -------------------------------------------------

  @doc """
  The canary currently running on this workspace, or `nil`.

  `nil` whenever the opt-in flag is unset — that is the kill switch: the config
  block may still be there, but it is inert, so routing falls straight back to
  the workspace's own rules on the very next dispatch.

  A malformed block also reads as `nil` rather than raising: a canary that
  cannot be parsed must not be able to steer a dispatch.
  """
  @spec active(Workspace.t() | nil) :: t() | nil
  def active(%Workspace{config: config} = ws) do
    if enabled?(ws), do: from_config(config), else: nil
  end

  def active(_), do: nil

  defp from_config(config) when is_map(config) do
    with block when is_map(block) <- get_in(config, @canary_path),
         "running" <- Map.get(block, "status"),
         id when is_binary(id) and id != "" <- Map.get(block, "proposal_id"),
         d when is_integer(d) and d in 0..4 <- Map.get(block, "difficulty"),
         {:ok, rule} <- validate_rule(Map.get(block, "rule")),
         {:ok, started_at} <- parse_started_at(Map.get(block, "started_at")) do
      %__MODULE__{
        proposal_id: id,
        difficulty: d,
        rule: rule,
        baseline_rule: Map.get(block, "baseline_rule"),
        started_at: started_at,
        arm_strategy: :alternating,
        min_dispatches: clamp_min_dispatches(Map.get(block, "min_dispatches")),
        regression_tolerance: clamp_tolerance(Map.get(block, "regression_tolerance")),
        max_age_days: clamp_max_age(Map.get(block, "max_age_days"))
      }
    else
      _ -> nil
    end
  end

  defp from_config(_), do: nil

  defp parse_started_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  defp parse_started_at(_), do: :error

  defp clamp_min_dispatches(n) when is_integer(n), do: max(n, @min_dispatches)
  defp clamp_min_dispatches(_), do: @min_dispatches

  defp clamp_tolerance(t) when is_number(t) and t >= 0,
    do: min(t / 1, @max_regression_tolerance)

  defp clamp_tolerance(_), do: 0.0

  defp clamp_max_age(n) when is_integer(n) and n > 0, do: min(n, @max_max_age_days)
  defp clamp_max_age(_), do: @default_max_age_days

  # ---- arms ---------------------------------------------------------------

  @doc """
  Which arm a task belongs to.

  A stable hash of the *base* task id (the `#review` / `#impl` suffixes are
  stripped so a task's review rounds never land in the other arm), salted with
  the proposal id so two successive canaries do not partition the fleet the
  same way. Deterministic: routing at dispatch time and the metrics pass days
  later must agree on who was in which arm, and nothing is recorded to tell
  them.
  """
  @spec arm(t(), String.t() | nil) :: arm()
  def arm(%__MODULE__{proposal_id: proposal_id}, task_id) when is_binary(task_id) do
    base = task_id |> String.split("#") |> hd()

    case :erlang.phash2({proposal_id, base}, 2) do
      0 -> :canary
      _ -> :control
    end
  end

  def arm(_canary, _task_id), do: :control

  @doc """
  The routing-rule overlay for one dispatch: the canaried rule when this task
  is in the canary arm at the canaried tier, `nil` otherwise.

  Called by `Arbiter.Agents.Routing.ByDifficulty` on every dispatch, so the
  no-canary path is a single map lookup.
  """
  @spec overlay(Workspace.t() | nil, String.t() | nil, integer()) :: map() | nil
  def overlay(workspace, task_id, difficulty) do
    with %__MODULE__{} = canary <- active(workspace),
         true <- canary.difficulty == difficulty,
         :canary <- arm(canary, task_id) do
      canary.rule
    else
      _ -> nil
    end
  end

  # ---- eligibility --------------------------------------------------------

  @doc """
  Whether a queued proposal may be applied autonomously, and what it would do.

  Returns `{:ok, %{proposal_id:, workspace_id:, difficulty:, rule:}}` or
  `{:error, reason}` with an operator-readable reason.
  """
  @spec eligible(PendingWrite.t()) ::
          {:ok,
           %{proposal_id: String.t(), workspace_id: String.t(), difficulty: 0..4, rule: map()}}
          | {:error, String.t()}
  def eligible(%PendingWrite{} = row) do
    with :ok <- check_state(row),
         :ok <- check_kind(row),
         {:ok, ws_id} <- check_workspace_id(row),
         {:ok, ws} <- fetch_workspace(ws_id),
         :ok <- check_evidence(row, ws),
         :ok <- check_policy(ws),
         {:ok, difficulty, rule} <- parse_routing_patch(row.payload) do
      {:ok, %{proposal_id: row.id, workspace_id: ws_id, difficulty: difficulty, rule: rule}}
    end
  end

  defp check_state(%PendingWrite{state: :proposed, escalated_at: nil}) do
    {:error,
     "this proposal has never been escalated to an operator; autonomous application only " <>
       "applies findings the operator has already seen as a Stage 2 proposal"}
  end

  defp check_state(%PendingWrite{state: :proposed}), do: :ok

  defp check_state(%PendingWrite{state: state}),
    do:
      {:error, "state is #{state} — only a :proposed row is eligible for autonomous application"}

  defp check_kind(%PendingWrite{kind: :config_set}), do: :ok

  defp check_kind(%PendingWrite{kind: kind}) do
    {:error,
     "kind is #{kind} — Stage 3 autonomy covers routing-tier :config_set proposals only " <>
       "(skill bodies and standing_orders stay operator-applied)"}
  end

  defp check_workspace_id(%PendingWrite{payload: payload, workspace_id: fallback}) do
    case Map.get(payload || %{}, "workspace_id") || fallback do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, "this proposal names no workspace to configure"}
    end
  end

  defp fetch_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> {:ok, ws}
      _ -> {:error, "no workspace #{ws_id}"}
    end
  end

  # The Stage 2 bar, re-checked on its own terms. A `:task`-scoped row reaches
  # `:proposed` by bypassing the bar (blast radius 1) — but a routing rule is
  # not blast-radius 1, so the bypass does not carry over here.
  defp check_evidence(%PendingWrite{} = row, ws) do
    bar = Loop.evidence_bar(ws)

    if row.evidence_count >= bar.min_incidents and row.distinct_tasks >= bar.min_distinct_tasks do
      :ok
    else
      {:error,
       "evidence is #{row.evidence_count} incident(s) across #{row.distinct_tasks} distinct " <>
         "task(s); autonomous application needs ≥ #{bar.min_incidents} across " <>
         "≥ #{bar.min_distinct_tasks} — the same Stage 2 bar, never a lower one"}
    end
  end

  defp check_policy(ws) do
    if Routing.policy_for_workspace(ws) == Routing.ByDifficulty do
      :ok
    else
      {:error,
       "this workspace does not route by_difficulty, so a routing.rules tier adjustment " <>
         "would change nothing and could not be measured"}
    end
  end

  # The narrow shape: exactly `routing.rules.D<n> => %{model_tier/thinking}`.
  defp parse_routing_patch(payload) when is_map(payload) do
    with :ok <- refuse_unset(payload),
         {:ok, patch} <- fetch_patch(payload),
         {:ok, rules} <- fetch_rules(patch),
         {:ok, key, rule} <- single_tier(rules),
         {:ok, difficulty} <- tier_difficulty(key),
         {:ok, validated} <- validate_rule(rule) do
      {:ok, difficulty, validated}
    end
  end

  defp parse_routing_patch(_), do: {:error, "this proposal carries no payload"}

  defp refuse_unset(payload) do
    case Map.get(payload, "unset_paths") do
      nil ->
        :ok

      [] ->
        :ok

      _ ->
        {:error, "a canaried routing change only ever sets a value; unset_paths is not eligible"}
    end
  end

  defp fetch_patch(payload) do
    case Map.get(payload, "patch") do
      %{} = patch when map_size(patch) == 1 -> {:ok, patch}
      %{} -> {:error, "an autonomous routing change must touch nothing but routing.rules"}
      _ -> {:error, "this proposal carries no config patch"}
    end
  end

  defp fetch_rules(%{"routing" => %{} = routing}) when map_size(routing) == 1 do
    case Map.get(routing, "rules") do
      %{} = rules -> {:ok, rules}
      _ -> {:error, "an autonomous routing change must patch routing.rules, nothing else"}
    end
  end

  defp fetch_rules(_),
    do: {:error, "an autonomous routing change must patch routing.rules, nothing else"}

  defp single_tier(rules) when is_map(rules) and map_size(rules) == 1 do
    [{key, rule}] = Map.to_list(rules)
    {:ok, key, rule}
  end

  defp single_tier(_rules),
    do: {:error, "a canary adjusts exactly one D<n> tier at a time"}

  defp tier_difficulty("D" <> n) do
    case Integer.parse(n) do
      {d, ""} when d in 0..4 -> {:ok, d}
      _ -> {:error, "#{inspect("D" <> n)} is not a D0..D4 routing tier"}
    end
  end

  defp tier_difficulty(key), do: {:error, "#{inspect(key)} is not a D0..D4 routing tier"}

  defp validate_rule(rule) when is_map(rule) and map_size(rule) > 0 do
    extra = Map.keys(rule) -- @rule_keys

    cond do
      extra != [] ->
        {:error,
         "a canaried rule may set model_tier / thinking only; #{inspect(extra)} is out of scope " <>
           "for autonomous application"}

      not Enum.all?(Map.values(rule), &is_binary/1) ->
        {:error, "model_tier / thinking must be strings"}

      true ->
        {:ok, rule}
    end
  end

  defp validate_rule(_), do: {:error, "a canaried rule must be a non-empty map"}

  # ---- start --------------------------------------------------------------

  @doc """
  Begin a canary for `proposal` on `workspace`.

  Writes the `loop.canary` block (never `routing.rules` — the rule is overlaid
  per dispatch until it has earned its place) as a `paper_trail` version
  attributed to `loop:proposal:<id>`.
  """
  @spec start(Workspace.t(), PendingWrite.t(), keyword()) ::
          {:ok, Workspace.t()} | {:error, String.t()}
  def start(%Workspace{} = ws, %PendingWrite{} = proposal, opts \\ []) do
    cond do
      not enabled?(ws) ->
        {:error,
         "loop.autonomous_routing_enabled is not set on this workspace — autonomous " <>
           "application is opt-in and off by default"}

      active(ws) ->
        {:error,
         "a canary is already running on this workspace (proposal " <>
           "#{active(ws).proposal_id}); one at a time"}

      true ->
        do_start(ws, proposal, opts)
    end
  end

  defp do_start(ws, proposal, _opts) do
    with {:ok, spec} <- eligible(proposal),
         :ok <- same_workspace(spec, ws) do
      block = %{
        "proposal_id" => proposal.id,
        "difficulty" => spec.difficulty,
        "rule" => spec.rule,
        "baseline_rule" => baseline_rule(ws, spec.difficulty),
        "arm" => "alternating",
        "started_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "min_dispatches" => clamp_min_dispatches(configured_min_dispatches(ws)),
        "regression_tolerance" => clamp_tolerance(configured_tolerance(ws)),
        "max_age_days" => clamp_max_age(configured_max_age_days(ws)),
        "status" => "running"
      }

      case patch(ws, %{"loop" => %{"canary" => block}}, [], attribution(proposal.id)) do
        {:ok, updated} ->
          announce_start(updated, proposal, spec)
          {:ok, updated}

        {:error, reason} ->
          {:error, "could not write the canary block: #{reason}"}
      end
    end
  end

  defp same_workspace(%{workspace_id: ws_id}, %Workspace{id: ws_id}), do: :ok

  defp same_workspace(%{workspace_id: ws_id}, %Workspace{id: other}),
    do: {:error, "this proposal targets workspace #{ws_id}, not #{other}"}

  # What the canaried tier resolves to *without* the canary — recorded so the
  # version history says what the change was measured against.
  defp baseline_rule(ws, difficulty) do
    base = Routing.ByDifficulty.default_mapping()[difficulty] || %{}
    override = get_in(ws.config || %{}, ["routing", "rules", "D#{difficulty}"]) || %{}
    Map.merge(base, override)
  end

  defp configured_min_dispatches(ws),
    do: get_in(ws.config || %{}, ["loop", "canary_min_dispatches"])

  defp configured_tolerance(ws),
    do: get_in(ws.config || %{}, ["loop", "canary_regression_tolerance"])

  defp configured_max_age_days(ws),
    do: get_in(ws.config || %{}, ["loop", "canary_max_age_days"])

  # ---- evaluate -----------------------------------------------------------

  @doc """
  Compare the two arms and return a verdict.

    * `{:insufficient_data, stats}` — the canary arm has not reached
      `min_dispatches`, or one of the arms has no reviewed task yet.
    * `{:revert, stats}` — first-pass convergence in the canary arm is below
      the control arm by more than `regression_tolerance`.
    * `{:promote, stats}` — it is not.
  """
  @spec evaluate(Workspace.t(), keyword()) ::
          {:insufficient_data, stats()}
          | {:revert, stats()}
          | {:promote, stats()}
          | {:error, String.t()}
  def evaluate(%Workspace{} = ws, opts \\ []) do
    case Keyword.get(opts, :canary) || active(ws) do
      nil -> {:error, "no canary is running on this workspace"}
      canary -> verdict(canary, Metrics.collect(ws.id, canary))
    end
  end

  defp verdict(canary, stats) do
    cond do
      stats.canary.dispatches < canary.min_dispatches ->
        {:insufficient_data, stats}

      is_nil(stats.canary.first_pass_convergence) or
          is_nil(stats.control.first_pass_convergence) ->
        {:insufficient_data, stats}

      stats.canary.first_pass_convergence <
          stats.control.first_pass_convergence - canary.regression_tolerance ->
        {:revert, stats}

      true ->
        {:promote, stats}
    end
  end

  # ---- tick (the driver) --------------------------------------------------

  @doc """
  One autonomy cycle for a workspace: judge the running canary, or start one.

  Returns `{:ok, :disabled}` when the opt-in flag is unset — which is every
  workspace until an operator sets it. The one thing a disabled workspace still
  does is clear a canary block left behind by the kill switch (`{:ok,
  {:stopped, _}}`, once); see the moduledoc for why that has to be terminal.
  """
  @spec tick(Workspace.t(), keyword()) ::
          {:ok, :disabled}
          | {:ok, :nothing_eligible}
          | {:ok, {:started, t()}}
          | {:ok, {:abandoned, map()}}
          | {:ok, {:stopped, map()}}
          | {:ok, {:expired, map()}}
          | {:ok, {:running | :reverted | :promoted, stats()}}
          | {:error, String.t()}
  def tick(workspace, opts \\ [])

  def tick(%Workspace{} = ws, opts) do
    cond do
      enabled?(ws) ->
        case active(ws) do
          nil -> maybe_start(ws, opts)
          canary -> judge(ws, canary, opts)
        end

      is_map(get_in(ws.config || %{}, @canary_path)) ->
        stop_for_kill_switch(ws)

      true ->
        {:ok, :disabled}
    end
  end

  def tick(_ws, _opts), do: {:ok, :disabled}

  # The kill switch, made terminal. While the flag was off the overlay returned
  # `nil` for every dispatch, so both arms were the *same* arm: judging a window
  # that includes those dispatches would compare a rule against itself and read
  # the tie as a pass. Dropping the block is one write, and it happens once —
  # after it, re-enabling the flag starts a clean canary rather than resuming a
  # window that was never measured.
  defp stop_for_kill_switch(ws) do
    proposal_id = ws.config |> get_in(@canary_path) |> Map.get("proposal_id")

    case patch(ws, %{}, ["loop.canary"], attribution(proposal_id)) do
      {:ok, _updated} ->
        Logger.info(
          "Loop.Canary stopped on #{ws.id}: loop.autonomous_routing_enabled is unset, so the " <>
            "canary block for proposal #{inspect(proposal_id)} was dropped rather than paused"
        )

        {:ok, {:stopped, %{proposal_id: proposal_id, reason: :kill_switch}}}

      {:error, reason} ->
        {:error, "could not drop the canary block after the kill switch: #{reason}"}
    end
  end

  # An operator who rejects (or applies) the proposal mid-canary has overruled
  # the experiment. Autonomy never outranks that, however well the canary arm
  # is doing: the block is dropped and the rule is not landed.
  defp judge(ws, canary, opts) do
    case proposal_state(canary.proposal_id) do
      :proposed -> judge_age(ws, canary, opts)
      other -> abandon(ws, canary, other)
    end
  end

  # Before measuring: has this canary had long enough? A tier with too little
  # traffic never reaches `min_dispatches`, and `judge_metrics/3` would answer
  # `{:running, _}` forever while the unvalidated rule stayed live on half of
  # that tier's dispatches, with no operator notice after `announce_start/3`.
  defp judge_age(ws, canary, opts) do
    age_days = DateTime.diff(DateTime.utc_now(), canary.started_at, :day)

    if age_days >= canary.max_age_days do
      expire(ws, canary, age_days, opts)
    else
      judge_metrics(ws, canary, opts)
    end
  end

  defp expire(ws, canary, age_days, opts) do
    reason =
      "the canary ran #{age_days} day(s) without the canary arm reaching " <>
        "#{canary.min_dispatches} dispatch(es) at D#{canary.difficulty}, so it expired " <>
        "unjudged (loop.canary_max_age_days: #{canary.max_age_days}). Nothing was written to " <>
        "routing.rules; this tier does not see enough traffic to validate the change " <>
        "autonomously, so apply it by hand if you still want it"

    case patch(ws, %{}, ["loop.canary"], attribution(canary.proposal_id)) do
      {:ok, _updated} ->
        close_proposal(canary.proposal_id, :expire, expiry_delta(canary, age_days), reason, opts)
        notify(ws, canary, "expired unjudged", reason)

        Logger.info(
          "Loop.Canary expired on #{ws.id}: proposal #{canary.proposal_id} ran #{age_days} " <>
            "day(s) without a verdict"
        )

        {:ok,
         {:expired,
          %{
            proposal_id: canary.proposal_id,
            difficulty: canary.difficulty,
            age_days: age_days,
            max_age_days: canary.max_age_days
          }}}

      {:error, reason} ->
        {:error, "could not expire the canary: #{reason}"}
    end
  end

  defp proposal_state(proposal_id) do
    case Loop.get_pending(proposal_id) do
      {:ok, %PendingWrite{state: state}} -> state
      _ -> :missing
    end
  end

  defp abandon(ws, canary, state) do
    case patch(ws, %{}, ["loop.canary"], attribution(canary.proposal_id)) do
      {:ok, _updated} ->
        Logger.info(
          "Loop.Canary abandoned on #{ws.id}: proposal #{canary.proposal_id} is #{state}"
        )

        {:ok, {:abandoned, %{proposal_id: canary.proposal_id, proposal_state: state}}}

      {:error, reason} ->
        {:error, "could not abandon the canary: #{reason}"}
    end
  end

  defp judge_metrics(ws, canary, opts) do
    case evaluate(ws, canary: canary) do
      {:insufficient_data, stats} -> {:ok, {:running, stats}}
      {:revert, stats} -> revert(ws, canary, stats, opts)
      {:promote, stats} -> promote(ws, canary, stats, opts)
      {:error, _} = err -> err
    end
  end

  # Try every eligible candidate, not just the first. A row whose payload names
  # a different workspace than the column `Loop.list_pending/1` filtered on
  # passes `eligible/1` and then fails `same_workspace/2` inside `start/3` — and
  # if that were the end of the cycle, one such row would wedge autonomy for the
  # whole workspace: every tick would error, and no other proposal would ever be
  # tried. So candidates are pre-filtered to those that actually target this
  # workspace, and a start that still fails falls through to the next.
  defp maybe_start(ws, opts) do
    Loop.list_pending(state: :proposed, kind: :config_set, workspace_id: ws.id)
    |> Enum.filter(&targets_workspace?(&1, ws))
    |> Enum.reduce_while({:ok, :nothing_eligible}, fn row, acc ->
      case start(ws, row, opts) do
        {:ok, started} ->
          {:halt, {:ok, {:started, active(started)}}}

        {:error, reason} ->
          Logger.warning(
            "Loop.Canary could not start proposal #{row.id} on #{ws.id}: #{reason}; " <>
              "trying the next candidate"
          )

          {:cont, acc}
      end
    end)
  end

  defp targets_workspace?(row, %Workspace{id: ws_id}) do
    match?({:ok, %{workspace_id: ^ws_id}}, eligible(row))
  end

  # ---- revert / promote ---------------------------------------------------

  @doc """
  Undo a canary: drop the `loop.canary` block and soft-reject the proposal with
  the measurement attached.

  Nothing was ever written to `routing.rules`, so this is a deletion rather
  than a repair — the arm falls back to the workspace's own rule on the next
  dispatch.
  """
  @spec revert(Workspace.t(), t(), stats(), keyword()) ::
          {:ok, {:reverted, stats()}} | {:error, String.t()}
  def revert(%Workspace{} = ws, %__MODULE__{} = canary, stats, opts \\ []) do
    reason = revert_reason(stats)

    case patch(ws, %{}, ["loop.canary"], attribution(canary.proposal_id)) do
      {:ok, _updated} ->
        close_proposal(canary.proposal_id, :revert, outcome_delta(:revert, stats), reason, opts)
        notify(ws, canary, "auto-reverted", reason)
        {:ok, {:reverted, stats}}

      {:error, reason} ->
        {:error, "could not remove the canary block: #{reason}"}
    end
  end

  @doc """
  Land a passing canary: write the rule onto `routing.rules.D<n>` for the whole
  workspace, drop the canary block, and mark the proposal `:applied`.
  """
  @spec promote(Workspace.t(), t(), stats(), keyword()) ::
          {:ok, {:promoted, stats()}} | {:error, String.t()}
  def promote(%Workspace{} = ws, %__MODULE__{} = canary, stats, opts \\ []) do
    patch_map = %{"routing" => %{"rules" => %{"D#{canary.difficulty}" => canary.rule}}}

    case patch(ws, patch_map, ["loop.canary"], attribution(canary.proposal_id)) do
      {:ok, _updated} ->
        close_proposal(
          canary.proposal_id,
          :promote,
          outcome_delta(:promote, stats),
          promote_reason(stats),
          opts
        )

        notify(ws, canary, "promoted fleet-wide", promote_reason(stats))
        {:ok, {:promoted, stats}}

      {:error, reason} ->
        {:error, "could not land the canaried rule: #{reason}"}
    end
  end

  defp revert_reason(stats) do
    "first-pass convergence regressed in the canary arm: " <>
      "#{pct(stats.canary.first_pass_convergence)} vs #{pct(stats.control.first_pass_convergence)} " <>
      "in the control arm over #{stats.canary.dispatches} canaried dispatch(es)"
  end

  defp promote_reason(stats) do
    "first-pass convergence held or improved in the canary arm: " <>
      "#{pct(stats.canary.first_pass_convergence)} vs #{pct(stats.control.first_pass_convergence)} " <>
      "in the control arm over #{stats.canary.dispatches} canaried dispatch(es)"
  end

  defp pct(nil), do: "—"
  defp pct(f) when is_number(f), do: "#{Float.round(f * 100, 1)}%"

  # The proposal is closed out through the same domain API an operator uses, so
  # the queue's own paper trail records the autonomous decision too.
  defp close_proposal(proposal_id, verdict, delta, reason, opts) do
    actor = Keyword.get(opts, :actor, "loop")

    with {:ok, row} <- Loop.get_pending(proposal_id) do
      {:ok, row} =
        Ash.update(row, %{outcome_delta: delta, actor: actor},
          action: :record_outcome,
          actor: actor
        )

      case verdict do
        v when v in [:revert, :expire] ->
          Loop.reject_pending(row, reason: reason, actor: actor)

        :promote ->
          Ash.update(row, %{state: :applied, actor: actor}, action: :mark_applied, actor: actor)
      end
    end
  rescue
    e ->
      Logger.warning(
        "Loop.Canary could not close proposal #{proposal_id}: #{Exception.message(e)}"
      )

      :error
  end

  defp outcome_delta(verdict, stats) do
    %{
      "verdict" => Atom.to_string(verdict),
      "metric" => "first-pass ReviewGate convergence",
      "difficulty" => stats.difficulty,
      "min_dispatches" => stats.min_dispatches,
      "canary" => arm_delta(stats.canary),
      "control" => arm_delta(stats.control),
      "measured_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  # An expiry has no measurement to attach — that *is* the outcome: the tier
  # never produced enough dispatches to compare. Recording it keeps the reason
  # on the proposal rather than only in mail.
  defp expiry_delta(canary, age_days) do
    %{
      "verdict" => "expired",
      "metric" => "first-pass ReviewGate convergence",
      "difficulty" => canary.difficulty,
      "min_dispatches" => canary.min_dispatches,
      "age_days" => age_days,
      "max_age_days" => canary.max_age_days,
      "measured_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp arm_delta(arm) do
    %{
      "dispatches" => arm.dispatches,
      "reviewed_tasks" => arm.reviewed_tasks,
      "first_pass_convergence" => arm.first_pass_convergence,
      "cost_usd" => arm.cost_usd,
      "review_rounds" => arm.review_rounds,
      "cost_per_round" => arm.cost_per_round
    }
  end

  # ---- plumbing -----------------------------------------------------------

  # A malformed block may carry no proposal id at all; the version still has to
  # say who wrote it, and "loop:proposal:" alone would not.
  defp attribution(proposal_id) when is_binary(proposal_id) and proposal_id != "",
    do: "loop:proposal:#{proposal_id}"

  defp attribution(_), do: "loop"

  # Invariant 4 of `Arbiter.Loop`: config changes go through the deep-merge
  # `:patch_config` action, never a raw overwrite — and `actor` is accepted so
  # the version row carries the proposal that made the change.
  defp patch(ws, patch_map, unset_paths, actor) do
    case Ash.update(ws, %{patch: patch_map, unset_paths: unset_paths, actor: actor},
           action: :patch_config,
           actor: actor
         ) do
      {:ok, updated} -> {:ok, updated}
      {:error, err} -> {:error, ash_message(err)}
    end
  end

  defp announce_start(ws, proposal, spec) do
    notify(
      ws,
      %__MODULE__{
        proposal_id: proposal.id,
        difficulty: spec.difficulty,
        rule: spec.rule,
        started_at: DateTime.utc_now()
      },
      "started",
      "canarying #{inspect(spec.rule)} at D#{spec.difficulty} on half of this workspace's " <>
        "dispatches; it will be judged once the canary arm has #{@min_dispatches} of them"
    )
  end

  # Best-effort operator visibility. An autonomous change nobody was told about
  # is the failure mode this whole stage is trying to avoid — but a mail hiccup
  # must never abort (or, worse, half-abort) the change itself.
  defp notify(%Workspace{} = ws, %__MODULE__{} = canary, headline, detail) do
    Message.send_mail(%{
      kind: :escalation,
      to_ref: Message.coordinator_ref(),
      from_ref: "loop",
      workspace_id: ws.id,
      subject: "loop canary #{headline}: D#{canary.difficulty} routing tier",
      body: """
      Stage 3 autonomous routing canary (proposal #{canary.proposal_id}) #{headline}.

      Tier:   D#{canary.difficulty}
      Rule:   #{inspect(canary.rule)}
      Detail: #{detail}

      This ran without operator action because `loop.autonomous_routing_enabled`
      is set on this workspace. Unset it to stop autonomous routing changes:

          arb config set loop.autonomous_routing_enabled false --workspace #{ws.id}
      """
    })

    :ok
  rescue
    e ->
      Logger.debug("Loop.Canary notify swallowed: #{Exception.message(e)}")
      :ok
  end

  defp ash_message(%Ash.Error.Invalid{errors: errors}),
    do: errors |> Enum.map_join("; ", &Exception.message/1)

  defp ash_message(err) when is_exception(err), do: Exception.message(err)
  defp ash_message(err), do: inspect(err)
end
