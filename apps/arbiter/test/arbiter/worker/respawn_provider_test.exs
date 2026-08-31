defmodule Arbiter.Worker.RespawnProviderTest do
  @moduledoc """
  bd-2aslx6 (#1428): the gate-nudge and auto-resume respawns resolved their
  provider as `meta[:routing_config][:provider] || "claude"`. Only
  `Arbiter.Worker.Dispatch` ever reports `:routing_config` — a worker spawned by
  the ReviewGate, the MergeQueue fix-pass dispatcher or the conflict resolver
  has none — so every respawn on those paths fell back to Claude regardless of
  which CLI the run was actually driving. That picked the wrong adapter to
  rewrite the argv with and stamped the wrong `provider` on the respawned
  session's ledger row.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  require Ash.Query

  defp wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  defp events_for(task_id) do
    Event
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "respawn-provider-ws-#{System.unique_integer([:positive])}",
        prefix: "rp"
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "respawn provider", workspace_id: ws.id, issue_type: :task})

    {:ok, task} = Ash.update(task, %{status: :in_progress})

    # No `:routing_config` — this is the ReviewGate / fix-pass shape.
    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "unknown",
        workspace_id: ws.id,
        meta: %{issue_type: :task, review_spawn: false}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)

    %{ws: ws, task: task, pid: pid}
  end

  # A session that exits 0 without ever printing `arb done`, which is what routes
  # a task-type worker into the notes gate (and, with blank notes, into a nudge
  # respawn of the stashed argv).
  defp start_session!(pid, provider) do
    {:ok, port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: System.tmp_dir!(),
        provider: provider,
        command: ["sh", "-c", "echo wrapping up; exit 0"]
      )

    port
  end

  test "a nudge respawn keeps the run's own provider instead of falling back to claude",
       %{task: task, pid: pid} do
    start_session!(pid, "codex")

    # First session exits -> notes gate (blank notes) -> nudge respawn of the
    # same stashed argv, which exits the same way -> cap exhausted -> park.
    wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

    providers = task.id |> events_for() |> Enum.map(& &1.provider)

    # Two sessions ran (original + nudge respawn) and BOTH are codex.
    assert length(providers) == 2
    assert Enum.all?(providers, &(&1 == "codex")), "got providers: #{inspect(providers)}"
  end

  test "a provider whose argv we cannot rewrite parks instead of silently re-running the task",
       %{task: task, pid: pid} do
    start_session!(pid, "gemini")

    wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

    snap = Worker.state(pid)

    # `Arbiter.Agents.Gemini` exports no `splice_prompt/2`, so the nudge cannot
    # be delivered. Relaunching the untouched argv would re-run the WHOLE
    # original prompt at full price while pretending it was a nudge — park and
    # escalate with a concrete cause instead.
    assert snap.meta[:notes_gate_detail] == {:respawn_failed, :unsupported_provider}

    events = events_for(task.id)
    assert length(events) == 1
    assert hd(events).provider == "gemini"
  end
end
