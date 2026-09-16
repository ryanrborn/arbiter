System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")
System.delete_env("ARBITER_MEMORY_ROOT")

ExUnit.start()

# Make sure :req's transitive apps (finch, mint, etc.) are started for tests
# that hit the Req.Test plug adapter.
{:ok, _} = Application.ensure_all_started(:req)
