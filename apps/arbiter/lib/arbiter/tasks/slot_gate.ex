defmodule Arbiter.Tasks.SlotGate do
  @moduledoc """
  One answer to "what occupies a worker slot?" — the companion predicate to
  `Arbiter.Tasks.EdgeGate`, for the other half of the same dispatch decision.

  `EdgeGate` answers *may* this task be dispatched given its edges.
  `SlotGate` answers *is there room* to dispatch anything at all. The board
  scheduler (`Arbiter.Board.Snapshot` → `Arbiter.Board.Scheduler` →
  `Arbiter.Board.Autopilot`) is the only dispatcher, and it used to answer
  this itself, inline in `derive/1`. Both halves of the dispatch decision now
  live beside each other as pure predicates so neither can drift from what the
  board renders.

  ## A slot is a live agent, not a record (bd-aw2cyt)

  Before this module, a slot meant "an author worker record in one of
  `#{inspect([:idle, :resuming, :running, :awaiting, :awaiting_review_gate])}`".
  That is not what the operator's cap is for. A worker record outlives its
  agent by a long way: once the main `claude --print` process exits, the
  record stays alive to shepherd the ReviewGate, the implementer rounds, CI
  and the merge — spending nothing, burning no quota, and still holding a slot
  that blocked the next dispatch. `:awaiting` was the sharpest case: a worker
  that asked a human a question and has no agent at all held a slot until
  somebody answered.

  So a slot is occupied by a **live agent subprocess**, whatever role it
  belongs to: the main author session, a ReviewGate reviewer, an implementer
  round, a CI fix pass, a conflict resolver. Each is a separate paid session,
  so each costs a slot. A worker record with no live agent — waiting on CI,
  waiting on a merge, waiting on a person, between rounds — occupies none.

  ## The cap gates new dispatches only

  Counting review / implementer / fix-pass rounds toward the cap is what makes
  the number honest, but it must never be what *stops* them: a cap of 1 with
  one author in flight would deadlock the moment that author needed a review
  round, because the round could not start and the author could never finish.
  So the rounds always spawn when the work needs them, and the cap they push
  over is only consulted when deciding whether to start something **new**.
  The callers enforce that by construction — only the board scheduler's
  admission path asks this module anything — and `Arbiter.Worker.ReviewGate` /
  the merge-queue dispatchers never do.

  ## Liveness is an input

  `occupies_slot?/2` reads `:agent_live` off the worker snapshot
  (`Arbiter.Worker` stamps it from its own open ports — see
  `Arbiter.Worker.agent_session_live?/1`), so the predicate stays pure and the
  board's `derive/1` can be tested with plain maps. A snapshot that carries no
  `:agent_live` key at all is *unknown*, not "not live", and degrades to the
  old status rule — an unreadable liveness must never read as a free slot,
  which would over-dispatch.

  ## `conductor.slot_basis`

  `:agents` (the default) is the rule above. `:issues` restores the
  pre-bd-aw2cyt record-based counting, for an operator who wants the old
  behaviour back when quota loosens:

      config :arbiter, conductor_slot_basis: :issues

  ## A slot is a task, not an agent (bd-45pwo1)

  `occupies_slot?/2` / `occupied/2` above answer "is an agent burning quota
  right now" — useful for the `agents live: X of N` header, and left alone.
  They are **not** what gates a new dispatch any more.

  The operator's rule (2026-09-21, restated 2026-09-22): "another slot
  doesn't open until the issue occupying it is merged." A slot belongs to
  the **task**, from dispatch until its PR merges (or it closes, fails,
  stops, or parks for a human) — not to whichever agent happens to be live
  for it at the moment the board is drawn. Under the agent-liveness rule
  alone, a task sitting between ReviewGate rounds (no agent live, but not
  done either) held no slot, and the fleet ran three author tasks at once
  against a cap of two.

  `occupied_tasks/2` counts this instead: one slot per distinct task whose
  `Arbiter.Worker.Phase` is not released. A phase is released only at
  `:done` (the worker completed — merged, closed, or otherwise finalized) or
  `:waiting_on_you` (the worker asked a question, or parked failed — a human
  might take arbitrarily long to answer, so a slot must not pin on that).
  Every other phase — `:implementing`, `:in_review`, `:addressing_review`,
  `:fixing_ci`, `:resolving_conflict`, `:waiting_ci_merge`, and
  `:handing_off` (the gap between rounds) — still holds the slot. A worker
  explicitly stopped drops out of the registry entirely, so it stops being
  counted the same way a card would stop being rendered.

  `occupied_tasks/2` takes the worker list already annotated with `:phase`
  (`Arbiter.Worker.Phase.annotate/1`) rather than computing it itself:
  `Phase` already aliases this module, so the reverse dependency would be
  circular, and the board already annotates the list for its cards anyway.

  Exactly one slot per task regardless of how many subordinate rounds
  (reviewer, implementer, fix pass, conflict resolver) are live for it: only
  the task's own author row is consulted, because `Phase.of/2` already folds
  every sibling's liveness into that row's phase.
  """

  @typedoc "How a slot is counted."
  @type basis :: :agents | :issues

  @default_basis :agents

  @bases [:agents, :issues]

  # Worker statuses that held a slot under the `:issues` basis — an author
  # record with a workflow still in its hands. `:awaiting_review` is absent: it
  # holds an MR, not a subprocess.
  @slot_statuses [:idle, :resuming, :running, :awaiting, :awaiting_review_gate]

  # A reviewer / implementer runs under its *own* synthetic task id on behalf
  # of an author, so under the `:issues` basis it folds into the author's card
  # rather than holding a record of its own. `:fix_pass` / `:conflict_resolver`
  # share the author's task id and were counted as author rows before this
  # module existed; that is preserved exactly.
  @gate_roles [:reviewer, :implementer]

  @doc """
  The statuses that occupy a slot under the `:issues` basis.
  """
  @spec slot_statuses() :: [atom()]
  def slot_statuses, do: @slot_statuses

  @doc """
  How slots are counted on this install: `:agents` (default) or `:issues`.

  Reads `:arbiter, :conductor_slot_basis`. Accepts an atom or a string; an
  unrecognised value is not configuration, so it falls back to the default
  rather than silently adopting something nobody asked for.
  """
  @spec basis() :: basis()
  def basis do
    normalize_basis(Application.get_env(:arbiter, :conductor_slot_basis))
  rescue
    _ -> @default_basis
  end

  @doc """
  Coerce a caller-supplied basis (atom, string or `nil`) to a known one.

  Pure: `nil` and anything unrecognised resolve to the default (`:agents`),
  *not* to the configured basis — reading config here would make every slot
  predicate impure, and `basis/0` itself calls this on the env value, so the
  two would recurse. Callers that want the install's configured basis read
  `basis/0` at their own impure boundary and pass the result down; that is
  what `Arbiter.Board.Snapshot.load/1` does.
  """
  @spec normalize_basis(term()) :: basis()
  def normalize_basis(nil), do: @default_basis
  def normalize_basis(b) when b in @bases, do: b

  def normalize_basis(b) when is_binary(b) do
    # Never `String.to_atom/1` on a config value — match the known set.
    Enum.find(@bases, @default_basis, &(Atom.to_string(&1) == b))
  end

  def normalize_basis(_), do: @default_basis

  @doc """
  Does this worker snapshot occupy a worker slot?

  `basis` defaults to `:agents` (see `normalize_basis/1` — it does *not* read
  config); pass the install's basis explicitly, resolved once via `basis/0` at
  an impure boundary, so the answer stays a function of its inputs.
  """
  @spec occupies_slot?(map(), basis() | nil) :: boolean()
  def occupies_slot?(worker, basis \\ nil)

  def occupies_slot?(worker, basis) when is_map(worker) do
    case normalize_basis(basis) do
      :issues -> record_slot?(worker)
      :agents -> agent_slot?(worker)
    end
  end

  def occupies_slot?(_worker, _basis), do: false

  @doc """
  How many of `workers` occupy a slot.
  """
  @spec occupied([map()], basis() | nil) :: non_neg_integer()
  def occupied(workers, basis \\ nil) when is_list(workers) do
    basis = normalize_basis(basis)
    Enum.count(workers, &occupies_slot?(&1, basis))
  end

  @doc """
  Slots left out of `total` once `workers` have taken theirs. Never negative:
  review / fix-pass rounds are allowed to push past the cap (see the moduledoc),
  so the occupied count legitimately exceeds `total` sometimes, and "-1 slots
  free" is not a thing a scheduler or a header should ever say.
  """
  @spec free(non_neg_integer(), [map()], basis() | nil) :: non_neg_integer()
  def free(total, workers, basis \\ nil) when is_integer(total) and is_list(workers) do
    max(total - occupied(workers, basis), 0)
  end

  @doc """
  Is this worker snapshot's agent subprocess live?

  `nil` when the snapshot does not carry the answer — a caller that could not
  ask (a pure test fixture, an older serialized row) gets "unknown", never a
  false "no".
  """
  @spec agent_live(map()) :: boolean() | nil
  def agent_live(worker) when is_map(worker) do
    case Map.get(worker, :agent_live, Map.get(worker, "agent_live")) do
      true -> true
      false -> false
      _ -> nil
    end
  end

  # Phases that release a task's slot early. See the moduledoc's "A slot is
  # a task, not an agent" section for why only these two.
  @released_phases [:done, :waiting_on_you]

  # A reviewer / implementer / fix pass / conflict resolver never holds a
  # second slot for the task it belongs to — `occupied_tasks/2` counts from
  # each task's own author row only.
  @subordinate_roles [:reviewer, :implementer, :fix_pass, :conflict_resolver]

  @doc """
  Does this phase still hold a task's slot? False only at `:done` or
  `:waiting_on_you` — see the moduledoc.
  """
  @spec task_occupies_slot?(atom()) :: boolean()
  def task_occupies_slot?(phase) when is_atom(phase), do: phase not in @released_phases

  @doc """
  How many distinct tasks occupy a slot, given `annotated_workers` — the full
  worker list with `:phase` already stamped
  (`Arbiter.Worker.Phase.annotate/1`).

  Under `:agents` (the default), one slot per task whose phase is not
  released (`task_occupies_slot?/1`), read off the task's own author row —
  a live reviewer, implementer, fix pass or conflict resolver never adds a
  second slot for the same task. Under `:issues`, falls back to the
  pre-bd-aw2cyt per-record rule (`record_slot?/1`), deduplicated by task id
  so a fix pass or conflict resolver sharing its author's task id does not
  double-count either.
  """
  @spec occupied_tasks([map()], basis() | nil) :: non_neg_integer()
  def occupied_tasks(annotated_workers, basis \\ nil) when is_list(annotated_workers) do
    case normalize_basis(basis) do
      :issues -> issues_task_count(annotated_workers)
      :agents -> phase_task_count(annotated_workers)
    end
  end

  @doc """
  Task slots left out of `total`, mirroring `free/3` but for task occupancy
  (`occupied_tasks/2`) rather than agent-session occupancy. Never negative,
  for the same reason `free/3` never is.
  """
  @spec task_free(non_neg_integer(), [map()], basis() | nil) :: non_neg_integer()
  def task_free(total, annotated_workers, basis \\ nil)
      when is_integer(total) and is_list(annotated_workers) do
    max(total - occupied_tasks(annotated_workers, basis), 0)
  end

  # ---- internals ------------------------------------------------------------

  defp phase_task_count(workers) do
    workers
    |> Enum.filter(&author_row?/1)
    |> Enum.uniq_by(&Map.get(&1, :task_id))
    |> Enum.count(&task_occupies_slot?(Map.get(&1, :phase)))
  end

  defp issues_task_count(workers) do
    workers
    |> Enum.filter(&record_slot?/1)
    |> Enum.uniq_by(&Map.get(&1, :task_id))
    |> length()
  end

  defp author_row?(worker), do: role_of(worker) not in @subordinate_roles

  defp agent_slot?(worker) do
    case agent_live(worker) do
      true -> true
      false -> false
      # Unknown liveness degrades to the record rule rather than to "free".
      nil -> record_slot?(worker)
    end
  end

  defp record_slot?(worker) do
    Map.get(worker, :status) in @slot_statuses and role_of(worker) not in @gate_roles
  end

  defp role_of(worker) do
    Map.get(worker, :role) || get_in_meta(worker, :role)
  end

  defp get_in_meta(worker, key) do
    case Map.get(worker, :meta) do
      %{} = meta -> Map.get(meta, key) || Map.get(meta, to_string(key))
      _ -> nil
    end
  end
end
