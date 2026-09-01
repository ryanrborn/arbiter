defmodule ArbiterCli.Cmd.Queue do
  @moduledoc """
  Graph-queue subcommand router (C5 of #482):

      arb queue resume <task-id>                — resume a paused branch by
                                                   re-dispatching the failed
                                                   task that blocked it
      arb queue retry-auto-resolve <task-id>    — re-arm one more auto-resolve
                                                   attempt on a task's merge
                                                   Watchdog after it exhausted
                                                   its budget on a :ci_failed
                                                   block and parked (bd-bspakl)
      arb queue restart-watchdog <task-id>      — mint a fresh merge Watchdog
                                                   for a task whose Watchdog
                                                   died, attached to the MR its
                                                   worker already has open
                                                   (bd-8jixav)
      arb queue rerun-ci <task-id> [--mode M]  — re-run a parked task's CI,
                                                   choosing the granularity
                                                   (bd-5mzzww)
      arb queue mark-ci-external <task-id> <note>
                                               — record an "infra, not this
                                                   diff" verdict on a
                                                   :ci_failed park (bd-5mzzww)

  When a graph member's worker fails, the Conductor pauses all tasks downstream
  of the failure and posts an escalation to the coordinator inbox. `resume` clears
  the failed state, re-dispatches the task, and allows the branch to continue.

  `retry-auto-resolve` is the supported way to force a fresh fix-pass once the
  Watchdog's bounded auto-resolve retries are exhausted: without it, a task
  parked on a genuine `:ci_failed` block after exhaustion had no way to try
  again short of pushing a fix to the branch by hand, outside Arbiter's normal
  worker/review flow. `retry_auto_resolve` (underscored) is accepted as an
  undocumented alias for back-compat.

  `restart-watchdog` recovers the *other* failure: a Watchdog is a `:temporary`
  process, so when it crashes it is gone for good and nothing announces it. The
  worker stays parked at `:awaiting_review` and its MR stays open, unpolled,
  forever — and `retry-auto-resolve` cannot help, because there is no Watchdog
  left to re-arm. `restart-watchdog` starts a replacement on the same MR,
  replaying the lane (auto-merge, review-gate) the original ran on, without a
  full re-dispatch through the review gate. It refuses when a Watchdog is
  already running: two on one MR would race the merge and double-dispatch fix
  passes. `restart_watchdog` (underscored) is accepted as an alias.

  `rerun-ci` is the operator's CI-retry verb, and it exists because the forge's
  own affordance is a trap. "Re-run failed jobs" — the button a human reaches
  for first — REUSES every job in the run that already succeeded. When the
  failing check tests an artifact an earlier job in that run produced (a
  per-branch review app, a built image), re-running only the failed job
  re-tests the identical stale artifact and fails identically, every time. So
  this verb makes the granularity explicit:

      --mode auto         (default) escalate past failed_jobs automatically
                          whenever completed upstream jobs would be reused, or
                          the run is already on attempt 2+
      --mode failed_jobs  re-run only the failed jobs (reuses upstream output)
      --mode all_jobs     re-run the whole run, REBUILDING upstream jobs
      --mode workflow     fresh workflow_dispatch; the only mode that can
                          carry --input k=v pairs (e.g. force_deploy=true)

  `mark-ci-external` is where an "infrastructure is broken repo-wide, this is
  not my diff" verdict goes. It reclassifies a `:ci_failed` park as
  `:ci_failed_external` and carries the note into the coordinator escalation,
  so the page reads as broken CI rather than as broken code. The note is
  mandatory: an unevidenced "it's not me" is not something an operator can act
  on.
  """

  alias ArbiterCli.{Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      rest = Output.drop_json(argv)
      mode = Output.mode(argv)

      case rest do
        ["resume", task_id | _] ->
          resume(task_id, mode)

        ["resume" | _] ->
          Output.die("queue resume requires: <task-id>")

        [cmd, task_id | _] when cmd in ["retry-auto-resolve", "retry_auto_resolve"] ->
          retry_auto_resolve(task_id, mode)

        [cmd | _] when cmd in ["retry-auto-resolve", "retry_auto_resolve"] ->
          Output.die("queue retry-auto-resolve requires: <task-id>")

        [cmd, task_id | _] when cmd in ["restart-watchdog", "restart_watchdog"] ->
          restart_watchdog(task_id, mode)

        [cmd | _] when cmd in ["restart-watchdog", "restart_watchdog"] ->
          Output.die("queue restart-watchdog requires: <task-id>")

        [cmd, task_id | rest_args] when cmd in ["rerun-ci", "rerun_ci"] ->
          rerun_ci(task_id, rest_args, mode)

        [cmd | _] when cmd in ["rerun-ci", "rerun_ci"] ->
          Output.die("queue rerun-ci requires: <task-id>")

        [cmd, task_id | note_parts]
        when cmd in ["mark-ci-external", "mark_ci_external"] and note_parts != [] ->
          mark_ci_external(task_id, Enum.join(note_parts, " "), mode)

        [cmd | _] when cmd in ["mark-ci-external", "mark_ci_external"] ->
          Output.die("queue mark-ci-external requires: <task-id> <note>")

        _ ->
          IO.puts(:stderr, "arb: unknown queue subcommand")
          IO.puts(:stderr, "Run `arb queue --help` for usage.")
          Output.halt(2)
      end
    end
  end

  defp resume(task_id, mode) do
    case Client.post("/api/queue/#{task_id}/resume", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts(
            "Resumed: #{task_id} re-dispatched. The downstream branch will continue once it completes."
          )
        end

      {:error, %Client.Error{kind: :http, status: 404}} ->
        Output.die(
          "task #{task_id} is not in any running conductor's failed set.\n" <>
            "Either it has not failed, no graph is currently running, or it was already resumed."
        )

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end

  defp retry_auto_resolve(task_id, mode) do
    case Client.post("/api/queue/#{task_id}/retry_auto_resolve", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts(
            "Re-armed: #{task_id} auto-resolve budget bumped by one; the next watchdog " <>
              "poll (within the poll interval) will dispatch a fresh fix-pass."
          )
        end

      {:error, %Client.Error{kind: :http, status: 404}} ->
        Output.die(
          "no merge watchdog is currently running for task #{task_id}.\n" <>
            "Either the task never opened an MR, or its watchdog has already stopped.\n" <>
            "If the MR is still open, its watchdog died — start a replacement with:\n" <>
            "  arb queue restart-watchdog #{task_id}"
        )

      {:error, %Client.Error{kind: :http, status: 400}} ->
        Output.die(
          "task #{task_id} is not currently parked on an exhausted :ci_failed block " <>
            "— there is nothing to re-arm."
        )

      {:error, %Client.Error{kind: :http, status: 503}} ->
        Output.die(
          "task #{task_id}'s watchdog is busy polling — try again in a moment.\n" <>
            "This request may still be delivered once the current poll finishes, so wait " <>
            "and check the escalation clears before re-running this command — repeating it " <>
            "immediately risks bumping the budget more than once."
        )

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end

  defp restart_watchdog(task_id, mode) do
    case Client.post("/api/queue/#{task_id}/restart_watchdog", %{}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts(
            "Restarted: a fresh merge watchdog is now polling #{task_id}'s open MR. " <>
              "It picks up where the dead one left off — no re-dispatch, no new review gate."
          )
        end

      {:error, %Client.Error{kind: :http, status: 404}} ->
        Output.die(
          "no worker is running for task #{task_id}, so there is nothing to attach a " <>
            "watchdog to.\n" <>
            "The worker process is gone too — recover the task with `arb worker resume " <>
            "#{task_id}` instead."
        )

      {:error, %Client.Error{kind: :http, status: 409}} ->
        Output.die(
          "a merge watchdog is already running for task #{task_id}. Nothing to restart.\n" <>
            "Starting a second one would race the first to merge the same MR."
        )

      {:error, %Client.Error{kind: :http, status: 503}} ->
        Output.die("task #{task_id}'s worker did not answer in time — try again in a moment.")

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end

  @rerun_modes ~w(auto failed_jobs all_jobs workflow)

  defp rerun_ci(task_id, args, mode) do
    {opts, bad} = parse_rerun_args(args, %{}, [])
    bad != [] && Output.die("queue rerun-ci: unrecognised argument(s): #{Enum.join(bad, " ")}")

    case Client.post("/api/queue/#{task_id}/rerun_ci", opts) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts(rerun_summary(task_id, body))
        end

      {:error, %Client.Error{kind: :http, status: 404}} ->
        Output.die(
          "no merge watchdog is currently running for task #{task_id}, so there is nothing " <>
            "holding its PR to re-run CI for.\n" <>
            "If the PR is still open, its watchdog died — start a replacement with:\n" <>
            "  arb queue restart-watchdog #{task_id}"
        )

      {:error, %Client.Error{kind: :http, status: 503}} ->
        Output.die("task #{task_id}'s watchdog is busy polling — try again in a moment.")

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end

  defp rerun_summary(task_id, body) when is_map(body) do
    used = body["mode"] || "auto"
    run = body["run_id"]
    workflow = body["workflow"]
    rationale = body["rationale"]

    header =
      "Re-ran CI for #{task_id}: mode=#{used}" <>
        if(workflow, do: " workflow=#{workflow}", else: "") <>
        if(run, do: " run=#{run}", else: "")

    # Print the rationale: an operator who never sees WHY auto escalated past
    # failed_jobs will reach for the failed-jobs button again next time.
    [header, rationale && "  why: #{rationale}", body["url"] && "  #{body["url"]}"]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp rerun_summary(task_id, _body), do: "Re-ran CI for #{task_id}."

  defp parse_rerun_args([], opts, bad), do: {opts, Enum.reverse(bad)}

  defp parse_rerun_args(["--mode", value | rest], opts, bad) do
    if value in @rerun_modes do
      parse_rerun_args(rest, Map.put(opts, "mode", value), bad)
    else
      Output.die(
        "queue rerun-ci: unknown --mode #{inspect(value)} — expected one of: " <>
          Enum.join(@rerun_modes, ", ")
      )
    end
  end

  defp parse_rerun_args(["--workflow", value | rest], opts, bad),
    do: parse_rerun_args(rest, Map.put(opts, "workflow", value), bad)

  defp parse_rerun_args(["--input", kv | rest], opts, bad) do
    case String.split(kv, "=", parts: 2) do
      [k, v] ->
        inputs = Map.put(Map.get(opts, "inputs", %{}), k, v)
        parse_rerun_args(rest, Map.put(opts, "inputs", inputs), bad)

      _ ->
        Output.die("queue rerun-ci: --input expects key=value, got: #{inspect(kv)}")
    end
  end

  defp parse_rerun_args([arg | rest], opts, bad), do: parse_rerun_args(rest, opts, [arg | bad])

  defp mark_ci_external(task_id, note, mode) do
    case Client.post("/api/queue/#{task_id}/mark_ci_external", %{"note" => note}) do
      {:ok, body} ->
        if mode == :json do
          IO.puts(Jason.encode!(body))
        else
          IO.puts(
            "Marked: #{task_id} reclassified as ci_failed_external. The coordinator " <>
              "escalation now reads as broken CI, not broken code, and carries your note."
          )
        end

      {:error, %Client.Error{kind: :http, status: 404}} ->
        Output.die(
          "no merge watchdog is currently running for task #{task_id} — there is no park " <>
            "to reclassify."
        )

      {:error, %Client.Error{kind: :http, status: 503}} ->
        Output.die("task #{task_id}'s watchdog is busy polling — try again in a moment.")

      {:error, %Client.Error{kind: :http, body: body}} when is_map(body) ->
        msg = get_in(body, ["error", "message"]) || inspect(body)
        Output.die(msg)

      {:error, %Client.Error{message: msg}} ->
        Output.die(msg)
    end
  end
end
