defmodule Arbiter.Worker.DevServerEnvTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.DevServerEnv

  describe "pairs/1" do
    test "returns a DATABASE_PATH override scoped to the given task id" do
      assert [{"DATABASE_PATH", path}] = DevServerEnv.pairs("gte-013-42")

      assert is_binary(path)
      assert path =~ "gte-013-42"
      assert String.ends_with?(path, ".sqlite3")
    end

    test "two different task ids get two different paths" do
      [{"DATABASE_PATH", path_a}] = DevServerEnv.pairs("task-a")
      [{"DATABASE_PATH", path_b}] = DevServerEnv.pairs("task-b")

      refute path_a == path_b
    end

    test "returns [] when task_id is nil or blank" do
      assert DevServerEnv.pairs(nil) == []
      assert DevServerEnv.pairs("") == []
    end
  end
end
