System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Arbiter.Repo, :manual)
