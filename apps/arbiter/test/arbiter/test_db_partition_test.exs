defmodule Arbiter.TestDbPartitionTest do
  use ExUnit.Case, async: true

  # config/test.exs requires config/support/test_db_partition.ex before this
  # suite starts, so Arbiter.TestDbPartition is already loaded.

  test "suffix is deterministic for the same cwd" do
    assert Arbiter.TestDbPartition.suffix("/tmp/worktree-a") ==
             Arbiter.TestDbPartition.suffix("/tmp/worktree-a")
  end

  test "suffix differs across different cwds" do
    refute Arbiter.TestDbPartition.suffix("/tmp/worktree-a") ==
             Arbiter.TestDbPartition.suffix("/tmp/worktree-b")
  end
end
