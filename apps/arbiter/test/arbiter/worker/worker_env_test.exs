defmodule Arbiter.Worker.WorkerEnvTest do
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.WorkerEnv

  defp workspace_with_env(worker_env) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "we-#{System.unique_integer([:positive])}",
        worker_env: worker_env
      })

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

  describe "resolve/1 observability" do
    test "warns when the workspace resolves but its encrypted store is unreadable despite configured keys" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true}
        })

      task = task_in(ws)

      # Simulate the storage-half degrading independently of the public
      # worker_env_meta half (e.g. a corrupt/cleared ciphertext column) —
      # exactly the "both halves written, only one readable" shape this
      # ticket is about. Direct SQL bypasses Ash's write-only `worker_env`
      # argument, which has no update path for the raw encrypted column.
      Arbiter.Repo.update_all(
        from(w in "workspaces", where: w.id == ^ws.id),
        set: [encrypted_worker_env: nil]
      )

      log =
        capture_log(fn ->
          assert WorkerEnv.resolve(task.id) == {[], []}
        end)

      assert log =~ "WorkerEnv"
      assert log =~ task.id
      assert log =~ ws.id
    end

    test "does not warn for a genuinely unconfigured workspace" do
      task = task_in(workspace_with_env(%{}))

      log =
        capture_log(fn ->
          assert WorkerEnv.resolve(task.id) == {[], []}
        end)

      assert log == ""
    end

    test "does not warn when the store resolves normally" do
      ws =
        workspace_with_env(%{
          "API_TOKEN" => %{"value" => "tok_secret", "secret" => true}
        })

      task = task_in(ws)

      log =
        capture_log(fn ->
          assert WorkerEnv.resolve(task.id) == {[{"API_TOKEN", "tok_secret"}], ["tok_secret"]}
        end)

      assert log == ""
    end
  end
end
