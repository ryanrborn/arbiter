defmodule Arbiter.MigrationsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Migrations

  # Fixture tuples follow Ecto.Migrator.migrations/1,3's documented @spec:
  # `[{:up | :down, id :: integer(), name :: String.t()}]` — status is the
  # FIRST element, not the third. See deps/ecto_sql/lib/ecto/migrator.ex:479.
  describe "extract_pending_count/1 (the with_repo 3-tuple shape)" do
    test "returns {:ok, count} with :down migrations" do
      raw =
        {:ok,
         {:ok,
          [
            {:up, 20_240_101_000_000, "AddUsers"},
            {:down, 20_240_102_000_000, "AddPosts"},
            {:down, 20_240_103_000_000, "AddComments"}
          ]}, []}

      assert Migrations.extract_pending_count(raw) == {:ok, 2}
    end

    test "returns {:ok, 0} when every migration is :up" do
      raw = {:ok, {:ok, [{:up, 20_240_101_000_000, "AddUsers"}]}, []}

      assert Migrations.extract_pending_count(raw) == {:ok, 0}
    end

    test "returns {:ok, 0} for an empty migrations list" do
      assert Migrations.extract_pending_count({:ok, {:ok, []}, []}) == {:ok, 0}
    end

    test "returns {:error, :unreachable} when database is unreachable" do
      assert Migrations.extract_pending_count({:error, :unreachable}) == {:error, :unreachable}
    end

    test "returns {:error, reason} for any unmatched shape" do
      assert Migrations.extract_pending_count({:ok, [{:down, 1, "x"}]}) ==
               {:error, :invalid_shape}
    end
  end

  describe "count_pending/0" do
    test "returns {:ok, count} or {:error, reason}" do
      result = Migrations.count_pending()

      assert match?({:ok, count} when is_integer(count) and count >= 0, result) or
               match?({:error, _}, result)
    end

    test "distinguishes between success and error cases" do
      # Verify that the result is a tagged tuple, not a bare integer
      result = Migrations.count_pending()
      assert is_tuple(result)
      assert tuple_size(result) == 2
      {tag, value} = result
      assert tag in [:ok, :error]
      # If ok, value should be a non-negative integer
      # If error, value should be an atom (the reason)
      assert (is_integer(value) and value >= 0) or is_atom(value)
    end
  end
end
