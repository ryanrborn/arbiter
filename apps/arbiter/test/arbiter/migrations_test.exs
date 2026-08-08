defmodule Arbiter.MigrationsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Migrations

  describe "extract_pending_count/1 (the with_repo 3-tuple shape)" do
    test "counts :down migrations out of a mixed up/down list" do
      raw =
        {:ok,
         {:ok,
          [
            {20_240_101_000_000, "AddUsers", :up},
            {20_240_102_000_000, "AddPosts", :down},
            {20_240_103_000_000, "AddComments", :down}
          ]}, []}

      assert Migrations.extract_pending_count(raw) == 2
    end

    test "returns 0 when every migration is :up" do
      raw = {:ok, {:ok, [{20_240_101_000_000, "AddUsers", :up}]}, []}

      assert Migrations.extract_pending_count(raw) == 0
    end

    test "returns 0 for an empty migrations list" do
      assert Migrations.extract_pending_count({:ok, {:ok, []}, []}) == 0
    end

    test "returns 0 on an {:error, _} shape (database unreachable)" do
      assert Migrations.extract_pending_count({:error, :unreachable}) == 0
    end

    # Regression guard for the round-1 bug: a naive `with {:ok, migrations} <-`
    # pattern expects a 2-tuple, but `Ecto.Migrator.with_repo/2` actually
    # returns a 3-tuple. Feeding that exact wrong shape in must fall through to
    # the catch-all clause (0), not raise.
    test "falls through to 0 on the wrong (2-tuple) shape rather than raising" do
      assert Migrations.extract_pending_count({:ok, [{1, "x", :down}]}) == 0
    end
  end

  describe "count_pending/0" do
    test "returns a non-negative integer" do
      count = Migrations.count_pending()
      assert is_integer(count)
      assert count >= 0
    end
  end
end
