defmodule Arbiter.Worker.Registry do
  @moduledoc """
  Thin wrapper exposing the `:via` tuple used to register `Arbiter.Worker`
  GenServers by their task_id.

  The underlying registry is started by `Arbiter.Application` under the name
  `#{__MODULE__}`. Callers should prefer `via_tuple/1` over hand-rolling
  `{:via, Registry, ...}` tuples.
  """

  @doc """
  Return the `:via` tuple a `Arbiter.Worker` GenServer registers under for
  the given `task_id`.
  """
  @spec via_tuple(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via_tuple(task_id) when is_binary(task_id) do
    {:via, Registry, {__MODULE__, task_id}}
  end

  @doc """
  Look up the pid of the worker registered for `task_id`, or `nil` if none.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(task_id) when is_binary(task_id) do
    case Registry.lookup(__MODULE__, task_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Return every `{registry_key, pid}` pair currently registered, regardless
  of key shape. Used by teardown paths that need to sweep synthetic
  sub-worker keys (`<task_id>:fixpass`, `<task_id>#review`, ...) rather than
  looking up a single exact key.
  """
  @spec all() :: [{String.t(), pid()}]
  def all do
    Registry.select(__MODULE__, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Return every `{registry_key, pid}` pair owned by `task_id`: the exact key
  itself plus synthetic sub-worker keys (`<task_id>:fixpass`,
  `<task_id>:conflict`, `<task_id>#review`, `<task_id>#r<N>`, ...).

  Ownership requires the separator (`:` or `#`) immediately after the prefix —
  rather than a bare `String.starts_with?/2` on `task_id` alone — so an
  unrelated task whose id happens to be a string-prefix of another
  (e.g. "bd-1" vs "bd-12:fixpass") never matches.

  This is the single definition of "which workers belong to this task" shared
  by the `:close` teardown hooks (`StopWorker`, `CleanupWorktree`); keeping
  them on one predicate is what lets CleanupWorktree's liveness re-check
  (bd-bmmj4w) trust that anything StopWorker was responsible for stopping is
  also something it will refuse to delete a worktree under.
  """
  @spec all_for(String.t()) :: [{String.t(), pid()}]
  def all_for(task_id) when is_binary(task_id) do
    Enum.filter(all(), fn {registry_key, _pid} -> owned_by?(registry_key, task_id) end)
  end

  @doc """
  Like `all_for/1`, but drops entries whose process is already dead.

  Registry's monitor-based cleanup is asynchronous, so a worker that died
  without its `terminate/2` running (a crash, a kill) can leave a corpse row
  behind for a short window. A corpse owns nothing and must not block
  teardown, so every "is anyone still using this task's worktree?" check
  (`CleanupWorktree`'s drain, the Driver's post-workflow reap) filters on
  `Process.alive?/1` through here rather than reading `all_for/1` raw.
  """
  @spec live_for(String.t()) :: [{String.t(), pid()}]
  def live_for(task_id) when is_binary(task_id) do
    task_id
    |> all_for()
    |> Enum.filter(fn {_registry_key, pid} -> Process.alive?(pid) end)
  end

  @doc """
  Like `live_for/1`, but only the **exclusive** family: the task's own key plus
  the merge-queue subordinate keys that use the `:` separator
  (`<task_id>:fixpass`, `<task_id>:conflict`).

  The `#` family (`<task_id>#review`, `<task_id>#impl<N>`, ...) is deliberately
  excluded. Those are `Arbiter.Worker.ReviewGate` sessions: they run in their
  own throwaway checkout, are serialised by the gate itself, and are *supposed*
  to run while the author's worker is parked — so they are not candidates for
  the single-active-worker rule enforced in `Arbiter.Worker.start/1` (bd-8tjcms).
  """
  @spec live_exclusive_for(String.t()) :: [{String.t(), pid()}]
  def live_exclusive_for(task_id) when is_binary(task_id) do
    task_id
    |> live_for()
    |> Enum.filter(fn {registry_key, _pid} -> exclusive_key?(registry_key, task_id) end)
  end

  @doc """
  True when `registry_key` belongs to `task_id`'s exclusive family — see
  `live_exclusive_for/1`.
  """
  @spec exclusive_key?(String.t(), String.t()) :: boolean()
  def exclusive_key?(registry_key, task_id) when is_binary(registry_key) and is_binary(task_id) do
    registry_key == task_id or String.starts_with?(registry_key, task_id <> ":")
  end

  def exclusive_key?(_registry_key, _task_id), do: false

  defp owned_by?(registry_key, task_id) do
    registry_key == task_id or
      String.starts_with?(registry_key, task_id <> ":") or
      String.starts_with?(registry_key, task_id <> "#")
  end

  @doc """
  Explicitly remove this process's registration. Called from the worker's
  `terminate/2` callback so callers observe `whereis/1 == nil` synchronously
  after `GenServer.stop/1` returns, rather than waiting on Registry's async
  monitor cleanup.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(task_id) when is_binary(task_id) do
    Registry.unregister(__MODULE__, task_id)
    :ok
  end
end
