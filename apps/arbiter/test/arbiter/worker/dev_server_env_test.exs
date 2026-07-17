defmodule Arbiter.Worker.DevServerEnvTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.DevServerEnv

  describe "pairs/1" do
    test "returns a DATABASE_PATH override scoped to the given task id" do
      assert [{"DATABASE_PATH", path}, {"PORT", _port}] = DevServerEnv.pairs("gte-013-42")

      assert is_binary(path)
      assert path =~ "gte-013-42"
      assert String.ends_with?(path, ".sqlite3")
    end

    test "returns a PORT override scoped to the given task id, distinct from the coordinator's own 4848" do
      assert [{"DATABASE_PATH", _path}, {"PORT", port}] = DevServerEnv.pairs("gte-013-42")

      {port_int, ""} = Integer.parse(port)
      assert port_int != 4848
      assert port_int in 20_000..29_999
    end

    test "two different task ids get two different paths and ports" do
      [{"DATABASE_PATH", path_a}, {"PORT", port_a}] = DevServerEnv.pairs("task-a")
      [{"DATABASE_PATH", path_b}, {"PORT", port_b}] = DevServerEnv.pairs("task-b")

      refute path_a == path_b
      refute port_a == port_b
    end

    test "same task id always gets the same port (deterministic across resumes)" do
      assert DevServerEnv.pairs("gte-013-42") == DevServerEnv.pairs("gte-013-42")
    end

    test "returns [] when task_id is nil or blank" do
      assert DevServerEnv.pairs(nil) == []
      assert DevServerEnv.pairs("") == []
    end
  end
end
