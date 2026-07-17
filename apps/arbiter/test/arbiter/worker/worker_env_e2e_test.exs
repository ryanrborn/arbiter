defmodule Arbiter.Worker.WorkerEnvE2ETest do
  @moduledoc """
  End-to-end integration for user-defined worker env vars (bd-62d3jh): a real
  `Worker` + real `Port` + a persisted `Workspace`, exercising the whole pipeline
  at once — `WorkerEnv.pairs/1` injection through `ClaudeSession.env_pairs/2`,
  and `Redaction` of secret-flagged values at the `emit_line` choke-point.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  test "worker child sees injected env vars; secret value is redacted from captured output" do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "we-e2e-#{System.unique_integer([:positive])}",
        worker_env: %{
          "MY_PLAIN" => %{"value" => "plain-visible", "secret" => false},
          "MY_SECRET" => %{"value" => "tok-supersecret", "secret" => true}
        }
      })

    {:ok, task} = Ash.create(Issue, %{title: "e2e", workspace_id: ws.id})

    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    cwd = System.tmp_dir!()

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        command: ["sh", "-c", "echo PLAIN=$MY_PLAIN; echo SECRET=$MY_SECRET"]
      )

    wait_for_exit(pid)

    lines = Worker.state(pid).meta.output_lines
    plain = Enum.find(lines, &String.starts_with?(&1, "PLAIN="))
    secret = Enum.find(lines, &String.starts_with?(&1, "SECRET="))

    # Injection: both vars reached the child environment.
    assert plain == "PLAIN=plain-visible"
    # Redaction: the secret value never appears; the placeholder does.
    assert secret == "SECRET=[REDACTED]"
    refute Enum.any?(lines, &(&1 =~ "tok-supersecret"))
  end

  defp wait_for_exit(pid, tries \\ 100)
  defp wait_for_exit(_pid, 0), do: flunk("worker did not exit")

  defp wait_for_exit(pid, tries) do
    case Worker.state(pid).meta do
      %{exit_status: s} when not is_nil(s) -> :ok
      _ -> Process.sleep(50) && wait_for_exit(pid, tries - 1)
    end
  end
end
