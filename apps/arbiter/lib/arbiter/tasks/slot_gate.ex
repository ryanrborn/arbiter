defmodule Arbiter.Tasks.SlotGate do
  @moduledoc """
  One answer to "what occupies a worker slot?" — the companion predicate to
  `Arbiter.Tasks.EdgeGate`, for the other half of the same dispatch decision.

  `EdgeGate` answers *may* this task be dispatched given its edges.
  `SlotGate` answers *is there room* to dispatch anything at all. Arbiter's
  two schedulers — `Arbiter.Workflows.Conductor` for a graph's members, and
  `Arbiter.Board.Snapshot` → `Arbiter.Board.Scheduler` →
  `Arbiter.Board.Autopilot` for the Ready queue — both need it, and both used
  to answer it themselves. They live here together so they cannot drift.

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
  The callers enforce that by construction — only the two schedulers'
  admission paths ask this module anything — and
  `Arbiter.Worker.ReviewGate` / the merge-queue dispatchers never do.

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
  """

  @typedoc "How a slot is counted."
  @type basis :: :agents | :issues

  @default_basis :agents

  @bases [:agents, :issues]

  @typedoc """
  Worker statuses that held a slot under the `:issues` basis — an author
  record with a workflow still in its hands. `:awaiting_review` is absent: it
  holds an MR, not a subprocess.
  """
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
  `nil` resolves to the configured basis; anything unrecognised to the default.
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

  `basis` defaults to the configured one; pass it explicitly from a pure
  caller (`Arbiter.Board.Snapshot.derive/1`) so the answer stays a function of
  its inputs.
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

  # ---- internals ------------------------------------------------------------

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
