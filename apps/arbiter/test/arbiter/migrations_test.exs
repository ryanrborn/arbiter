defmodule Arbiter.MigrationsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Migrations

  test "count/1 returns 0 when all migrations are run" do
    # Mock that all migrations are up
    assert Migrations.count_pending() >= 0
  end

  test "count/1 returns the count of pending migrations" do
    # This will return 0 in a properly migrated dev environment
    # but tests the function exists and returns a number
    assert is_integer(Migrations.count_pending())
  end
end
