ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Arbiter.Repo, :manual)

# bd-5scl0c: fail loudly if anything is killed while holding the single shared
# sandbox connection, instead of letting it corrupt an unrelated test.
Arbiter.Test.SandboxMonitor.install()
