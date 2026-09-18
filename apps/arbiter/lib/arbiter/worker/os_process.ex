defmodule Arbiter.Worker.OsProcess do
  @moduledoc """
  Killing an OS process tree that Erlang will not kill for us.

  Erlang does **not** terminate a `:spawn_executable` port's OS process on
  `Port.close/1` — the port goes away, the child keeps running. Two call sites
  depend on actually reaping it:

    * `Arbiter.Worker` teardown (bd-bmmj4w) — the process holding the worktree
      open is usually not the agent itself but what it spawned (`mix test`,
      `git`, …), and once the parent dies those are reparented to init where
      `pgrep -P` can no longer reach them. So descendants are enumerated
      **before** the parent is signalled.
    * `Arbiter.Agents.Preflight` (bd-svczq4) — a timed-out auth probe outlived
      its watchdog by 72 seconds, still calling the provider API and spending
      quota, because closing the port was the only teardown.

  Everything here is best-effort: a kill hiccup must never crash teardown, and
  a host without `pgrep` degrades to killing the root process alone.

  The BEAM shares its process group with the port's children, so a group kill
  is not an option — the descendants have to be enumerated and signalled
  individually.

  Reading a port's own OS pid deliberately stays with each caller: routing
  `Port.info(port, :os_pid)` through here instead costs `Arbiter.Worker` a
  `pattern_match` dialyzer warning (the cross-module call narrows what dialyzer
  can still prove about the port downstream), and it is two lines. What is worth
  sharing is the tree walk below.
  """

  @max_descendant_depth 5

  @doc """
  Every OS process descended from `root_os_pid`, breadth-first, depth-bounded.
  """
  @spec descendants(integer()) :: [integer()]
  def descendants(root_os_pid) when is_integer(root_os_pid) do
    collect([root_os_pid], MapSet.new(), @max_descendant_depth)
  end

  @doc """
  SIGKILL `root_os_pid` and everything descended from it, then wait for them to
  disappear. Returns the pids still alive afterwards (`[]` on success).
  """
  @spec kill_tree(integer()) :: [integer()]
  def kill_tree(root_os_pid) when is_integer(root_os_pid) do
    pids = [root_os_pid | descendants(root_os_pid)]

    Enum.each(pids, fn pid ->
      _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end)

    Enum.reject(pids, &gone?/1)
  rescue
    _ -> []
  end

  @doc """
  Poll `kill -0` until the OS process is gone (SIGKILL is prompt, so this
  usually returns on the first probe). Bounded so a wedged/zombie pid can't
  block teardown indefinitely.
  """
  @spec gone?(integer(), pos_integer()) :: boolean()
  def gone?(os_pid, attempts \\ 25) do
    Enum.reduce_while(1..attempts, false, fn _i, _acc ->
      case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
        {_, 0} ->
          Process.sleep(20)
          {:cont, false}

        _ ->
          {:halt, true}
      end
    end)
  rescue
    _ -> true
  end

  # ---- internals -----------------------------------------------------------

  defp collect([], acc, _depth), do: MapSet.to_list(acc)
  defp collect(_frontier, acc, 0), do: MapSet.to_list(acc)

  defp collect(frontier, acc, depth) do
    next =
      frontier
      |> Enum.flat_map(&children/1)
      |> Enum.reject(&MapSet.member?(acc, &1))
      |> Enum.uniq()

    collect(next, Enum.into(next, acc), depth - 1)
  end

  # `pgrep -P` is present on both Linux and macOS; when it is missing or the
  # probe blows up we return [] and fall back to killing the root alone.
  defp children(os_pid) do
    case System.cmd("pgrep", ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split(~r/\s+/, trim: true)
        |> Enum.flat_map(fn token ->
          case Integer.parse(token) do
            {pid, ""} -> [pid]
            _ -> []
          end
        end)

      # exit 1 == "no matching processes", i.e. a leaf.
      _ ->
        []
    end
  rescue
    _ -> []
  end
end
