defmodule ArbiterWeb.Plugs.CheckRepoStatusExceptMachineRoutesTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ArbiterWeb.Plugs.CheckRepoStatusExceptMachineRoutes, as: Plug_

  # Forces Phoenix.Ecto.CheckRepoStatus to see a pending migration without
  # touching the real database (see phoenix_ecto's :mock_migrations_fn hook).
  defp pending_migration_opts do
    [
      otp_app: :arbiter_web,
      mock_migrations_fn: fn _repo, _dirs, _opts ->
        [{:down, 20_260_101_000_000, "some_migration"}]
      end
    ]
  end

  for prefix <- ["proxy", "api", "events", "mcp"] do
    test "passes through unchanged for machine-facing path /#{prefix}/... even with a pending migration" do
      conn = conn(:get, "/#{unquote(prefix)}/whatever")
      opts = Plug_.init(pending_migration_opts())

      result = Plug_.call(conn, opts)

      assert result == conn
    end
  end

  for path <- ["/", "/tasks", "/dev/dashboard"] do
    test "still raises PendingMigrationError for browser path #{path} with a pending migration" do
      conn = conn(:get, unquote(path))
      opts = Plug_.init(pending_migration_opts())

      assert_raise Plug.Conn.WrapperError,
                   ~r/Phoenix\.Ecto\.PendingMigrationError/,
                   fn ->
                     Plug_.call(conn, opts)
                   end
    end
  end
end
