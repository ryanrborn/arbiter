defmodule Arbiter.Board.Scheduler do
  @moduledoc """
  Decides which Ready card gets dispatched next, and why every other one
  doesn't.

  The board's Ready column is a real queue, not a parking lot: nothing waits
  for a human to drag it into Running. `plan/1` is the whole decision, and it
  is a pure function — feed it a snapshot of the board (see
  `Arbiter.Board.Snapshot`) and it returns at most one task id to promote plus
  a one-line reason for every card in the queue. The caller performs the
  dispatch; this module never touches the world.

  Purity is the point. Dispatch is expensive and irreversible-ish (a worker
  spawns, a worktree lands on disk, tokens burn), so the rule that decides it
  should be testable without a repo, a supervisor, or a quota snapshot.

  ## Why at most one promotion per plan

  Even with three slots free, a plan promotes one card. Dispatch is
  asynchronous: the promoted worker does not appear in `running` until it
  registers, so a plan that promoted three at once would be reasoning about
  file overlap and slot count against stale state for the second and third.
  The board re-plans on every worker and task lifecycle event, so the next
  promotion follows within milliseconds of the first landing — one-at-a-time
  costs nothing and keeps each decision made against a picture that is true.

  ## Reason precedence

  A card's own blocks are reported ahead of anything board-wide, because they
  survive the board-wide condition clearing: telling an operator "no free
  worker slot" when the card is also waiting on an unmerged dependency would
  send them to free a slot for nothing.

    1. an open dependency — `blocked — waiting on bd-9`
    2. file overlap with in-flight work — `blocked — lib/a.ex in flight on bd-7`
    3. scheduler paused — `scheduler paused`
    4. quota — `blocked — quota exhausted`
    5. no free worker slot — `blocked — no free worker slot`

  Quota outranks the slot count deliberately: a free slot you may not use is
  not the fact worth showing.

  Only the *head* of the queue carries a board-wide hold — with one exception.
  Cards behind the head show their queue position (`2 ahead in queue`) — they
  aren't blocked, they're waiting, and the distinction is what makes a stalled
  board readable. A card held by a card-specific block is *skipped over* rather
  than counted, so the card behind it reads `next up` rather than `1 ahead` of
  work that isn't going anywhere.

  The exception is **paused**: a queue position implies a queue that is
  moving, so while the scheduler is paused *every* otherwise-unblocked card
  reads `scheduler paused`, not just the head. Card-specific blocks still win
  over it — a paused board should not hide the fact that a card is also
  waiting on a dependency.
  """

  alias Arbiter.Board.FileScope

  @typedoc """
  One Ready card. `scope` is its declared file scope (`FileScope.declared_paths/1`)
  and `blocked_by` the ids of its still-open gating dependencies.
  """
  @type card :: %{
          required(:id) => String.t(),
          optional(:scope) => FileScope.scope(),
          optional(:blocked_by) => [String.t()],
          optional(any()) => any()
        }

  @typedoc "One piece of work already in flight, with the files it has claimed."
  @type in_flight :: %{
          required(:task_id) => String.t(),
          optional(:scope) => FileScope.scope(),
          optional(any()) => any()
        }

  @typedoc "`:ok`, or a hold carrying the phrase to show the operator."
  @type quota :: :ok | nil | {:hold, String.t()}

  @type input :: %{
          optional(:ready) => [card()],
          optional(:running) => [in_flight()],
          optional(:slots_free) => integer(),
          optional(:quota) => quota(),
          optional(:paused) => boolean()
        }

  @typedoc """
  A card's queue standing. `:next` is the one card being dispatched this
  cycle, `:queued` is waiting its turn, `:blocked` cannot go yet.
  """
  @type state :: :next | :queued | :blocked

  @type entry :: %{
          id: String.t(),
          state: state(),
          reason: String.t(),
          card: card()
        }

  @type t :: %{promote: String.t() | nil, entries: [entry()]}

  @next_reason "next up — dispatching..."
  @paused_reason "scheduler paused"
  @no_slot_reason "blocked — no free worker slot"

  @doc """
  Plan one dispatch cycle.

  Returns `%{promote: task_id | nil, entries: [...]}` with one entry per Ready
  card, in queue order. `promote` is the single card the caller should
  dispatch, or `nil` when nothing is eligible.
  """
  @spec plan(input()) :: t()
  def plan(input) when is_map(input) do
    ready = Map.get(input, :ready) || []
    running = Map.get(input, :running) || []
    paused? = Map.get(input, :paused) == true

    hold = board_hold(paused?, Map.get(input, :quota), Map.get(input, :slots_free, 0))
    in_flight = Enum.map(running, &{&1.task_id, scope_of(&1)})
    seed = %{promote: nil, held?: false, ahead: 0, in_flight: in_flight, claimed: nil}

    {entries, acc} =
      Enum.map_reduce(ready, seed, fn card, acc -> step(card, hold, paused?, acc) end)

    %{promote: acc.promote, entries: entries}
  end

  def plan(_), do: %{promote: nil, entries: []}

  # One card's standing. `acc.held?` records that the board-wide hold has
  # already been shown on the card it actually applies to; `acc.ahead` counts
  # the cards genuinely queued in front of this one.
  defp step(card, hold, paused?, acc) do
    case card_block(card, claims(acc)) do
      # A card's own block never advances the queue position: the card behind
      # it is still next in line.
      {:blocked, reason} ->
        {entry(card, :blocked, reason), acc}

      nil when paused? ->
        {entry(card, :blocked, @paused_reason), bump(acc)}

      nil ->
        decide(card, hold, acc)
    end
  end

  defp decide(card, _hold, %{held?: true} = acc), do: queued(card, acc)
  defp decide(card, _hold, %{promote: p} = acc) when p != nil, do: queued(card, acc)

  # The head of the queue: it either goes, or it carries the hold that stopped it.
  defp decide(card, nil, acc) do
    acc = %{acc | promote: card.id, claimed: {card.id, scope_of(card)}}
    {entry(card, :next, @next_reason), bump(acc)}
  end

  defp decide(card, reason, acc) when is_binary(reason) do
    {entry(card, :blocked, reason), bump(%{acc | held?: true})}
  end

  # Already-running work first, then the card promoted this cycle — so a
  # collision is attributed to the worker that has actually been holding the
  # file, not to a sibling that only just won the slot.
  defp claims(%{in_flight: in_flight, claimed: nil}), do: in_flight
  defp claims(%{in_flight: in_flight, claimed: claim}), do: in_flight ++ [claim]

  defp queued(card, acc), do: {entry(card, :queued, ahead_reason(acc.ahead)), bump(acc)}

  defp bump(acc), do: %{acc | ahead: acc.ahead + 1}

  defp ahead_reason(n), do: "#{n} ahead in queue"

  defp entry(card, state, reason),
    do: %{id: card.id, state: state, reason: reason, card: card}

  # nil when the board as a whole is free to dispatch, otherwise the phrase to
  # show on the card the hold lands on.
  defp board_hold(true, _quota, _slots), do: @paused_reason
  defp board_hold(_paused, {:hold, reason}, _slots), do: "blocked — #{reason}"
  defp board_hold(_paused, _quota, slots) when is_integer(slots) and slots > 0, do: nil
  defp board_hold(_paused, _quota, _slots), do: @no_slot_reason

  defp card_block(card, claimed) do
    with nil <- dependency_block(card) do
      overlap_block(card, claimed)
    end
  end

  defp dependency_block(card) do
    case card |> Map.get(:blocked_by) |> List.wrap() |> Enum.uniq() |> Enum.sort() do
      [] -> nil
      ids -> {:blocked, "blocked — waiting on #{Enum.join(ids, ", ")}"}
    end
  end

  defp overlap_block(card, claimed) do
    scope = scope_of(card)

    Enum.find_value(claimed, fn {task_id, other} ->
      case FileScope.overlap(scope, other) do
        [] -> nil
        files -> {:blocked, "blocked — #{name_files(files)} in flight on #{task_id}"}
      end
    end)
  end

  defp name_files([file]), do: file
  defp name_files([file | rest]), do: "#{file} +#{length(rest)} more"

  defp scope_of(%{scope: %MapSet{} = scope}), do: scope
  defp scope_of(%{scope: paths}) when is_list(paths), do: MapSet.new(paths)
  defp scope_of(_), do: MapSet.new()
end
