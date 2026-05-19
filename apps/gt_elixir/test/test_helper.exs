ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(GtElixir.Repo, :manual)

# Ensure Req's transitive apps are started for tests using Req.Test stubs.
{:ok, _} = Application.ensure_all_started(:req)
