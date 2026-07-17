defmodule Arbiter.Worker.WorkerEnvTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.WorkerEnv

  defp workspace_with_env(worker_env) do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "we-#{System.unique_integer([:positive])}", worker_env: worker_env})

    ws
  end

  defp task_in(ws) do
    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
    task
  end

  describe "pairs/1" do
    test "returns every worker env var (secret and plain) as decrypted pairs" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true},
          "LOG_LEVEL" => %{"value" => "debug", "secret" => false}
        })

      task = task_in(ws)

      assert Enum.sort(WorkerEnv.pairs(task.id)) ==
               [{"API_TOKEN", "tok_secret"}, {"LOG_LEVEL", "debug"}]
    end

    test "returns [] for a workspace with no worker env vars" do
      task = task_in(workspace_with_env(%{}))
      assert WorkerEnv.pairs(task.id) == []
    end

    test "returns [] for an unknown / nil task id" do
      assert WorkerEnv.pairs("does-not-exist") == []
      assert WorkerEnv.pairs(nil) == []
      assert WorkerEnv.pairs("") == []
    end
  end

  describe "secret_values/1" do
    test "returns only the values of keys flagged secret" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true},
          "LOG_LEVEL" => %{"value" => "debug", "secret" => false}
        })

      task = task_in(ws)
      assert WorkerEnv.secret_values(task.id) == ["tok_secret"]
    end

    test "returns [] when no keys are secret" do
      task = task_in(workspace_with_env(%{"LOG_LEVEL" => %{"value" => "debug"}}))
      assert WorkerEnv.secret_values(task.id) == []
    end

    test "returns [] for an unknown / nil task id" do
      assert WorkerEnv.secret_values("does-not-exist") == []
      assert WorkerEnv.secret_values(nil) == []
    end
  end
end
