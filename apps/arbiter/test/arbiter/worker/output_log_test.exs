defmodule Arbiter.Worker.OutputLogTest do
  # async: false — we swap the :output_log_root application env per test.
  use ExUnit.Case, async: false

  alias Arbiter.Worker.OutputLog

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)
    root = Path.join(System.tmp_dir!(), "output-log-test-#{System.unique_integer([:positive])}")
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev do
        Application.put_env(:arbiter, :output_log_root, prev)
      else
        Application.delete_env(:arbiter, :output_log_root)
      end
    end)

    %{root: root, run_id: "run-#{System.unique_integer([:positive])}"}
  end

  test "path_for/1 lives under the configured root, keyed by run id", %{
    root: root,
    run_id: run_id
  } do
    assert OutputLog.path_for(run_id) == Path.join(root, run_id <> ".log")
  end

  test "open/1 creates the parent dir and a real, appendable file", %{
    root: root,
    run_id: run_id
  } do
    refute File.dir?(root)

    assert {:ok, handle} = OutputLog.open(run_id)
    assert File.dir?(root)
    assert File.exists?(handle.path)
    assert handle.run_id == run_id

    assert :ok = OutputLog.append(handle, "first")
    assert :ok = OutputLog.append(handle, "second")
    assert :ok = OutputLog.close(handle)

    assert {:ok, ["first", "second"]} = OutputLog.read_lines(run_id)
  end

  test "open/1 appends to (does not truncate) an existing transcript", %{run_id: run_id} do
    {:ok, h1} = OutputLog.open(run_id)
    OutputLog.append(h1, "before restart")
    OutputLog.close(h1)

    {:ok, h2} = OutputLog.open(run_id)
    OutputLog.append(h2, "after restart")
    OutputLog.close(h2)

    assert {:ok, ["before restart", "after restart"]} = OutputLog.read_lines(run_id)
  end

  test "read_lines/1 preserves blank lines mid-transcript", %{run_id: run_id} do
    {:ok, h} = OutputLog.open(run_id)
    Enum.each(["a", "", "b"], &OutputLog.append(h, &1))
    OutputLog.close(h)

    assert {:ok, ["a", "", "b"]} = OutputLog.read_lines(run_id)
  end

  test "read_lines/1 returns {:error, :enoent} when no transcript exists", %{run_id: run_id} do
    assert {:error, :enoent} = OutputLog.read_lines(run_id)
  end

  test "read_lines/1 returns [] for an empty transcript", %{run_id: run_id} do
    {:ok, h} = OutputLog.open(run_id)
    OutputLog.close(h)

    assert {:ok, []} = OutputLog.read_lines(run_id)
  end

  test "open/1 rejects a blank/invalid run id" do
    assert {:error, :invalid_run_id} = OutputLog.open("")
    assert {:error, :invalid_run_id} = OutputLog.open(nil)
  end

  test "root/0 without config uses an expandable default, not a hardcoded home dir" do
    prev = Application.get_env(:arbiter, :output_log_root)
    Application.delete_env(:arbiter, :output_log_root)

    on_exit(fn ->
      if prev do
        Application.put_env(:arbiter, :output_log_root, prev)
      else
        Application.delete_env(:arbiter, :output_log_root)
      end
    end)

    root = OutputLog.root()
    assert is_binary(root)
    refute String.contains?(root, "/home/rborn")
    assert String.contains?(root, "/arbiter-worker-logs")
  end

  test "root/0 default is resolved at runtime, not baked at compile time" do
    prev = Application.get_env(:arbiter, :output_log_root)
    Application.delete_env(:arbiter, :output_log_root)

    on_exit(fn ->
      if prev do
        Application.put_env(:arbiter, :output_log_root, prev)
      else
        Application.delete_env(:arbiter, :output_log_root)
      end
    end)

    root = OutputLog.root()
    current_home = System.user_home!()

    # The resolved default should start with the current user's home dir, not a baked-in value
    assert String.starts_with?(root, current_home)
    assert String.contains?(root, "/arbiter-worker-logs")
  end

  test "the durable store is uncapped — every line of a long run is retained", %{
    run_id: run_id
  } do
    {:ok, handle} = OutputLog.open(run_id)
    Enum.each(1..5_000, fn i -> OutputLog.append(handle, "line #{i}") end)
    OutputLog.close(handle)

    assert {:ok, lines} = OutputLog.read_lines(run_id)
    assert length(lines) == 5_000
    assert List.first(lines) == "line 1"
    assert List.last(lines) == "line 5000"
  end

  describe "tail_lines/2 — bounded terminal-signal read for loop analysis" do
    test "returns only the last n lines of a long transcript", %{run_id: run_id} do
      {:ok, handle} = OutputLog.open(run_id)
      Enum.each(1..5_000, fn i -> OutputLog.append(handle, "line #{i}") end)
      OutputLog.close(handle)

      assert {:ok, tail} = OutputLog.tail_lines(run_id, 40)
      assert length(tail) == 40
      assert List.first(tail) == "line 4961"
      assert List.last(tail) == "line 5000"
    end

    test "a transcript shorter than n returns all its lines", %{run_id: run_id} do
      {:ok, handle} = OutputLog.open(run_id)
      OutputLog.append(handle, "only line")
      OutputLog.close(handle)

      assert {:ok, ["only line"]} = OutputLog.tail_lines(run_id, 40)
    end

    test "a missing transcript is {:error, :enoent}, not a crash", %{run_id: run_id} do
      assert {:error, :enoent} = OutputLog.tail_lines(run_id, 40)
    end
  end

  describe "scan_for/2 — whole-transcript fingerprint scan" do
    test "finds a matching line far outside the tail window", %{run_id: run_id} do
      {:ok, handle} = OutputLog.open(run_id)
      OutputLog.append(handle, "** (Phoenix.Ecto.PendingMigrationError) migrations pending")
      Enum.each(1..200, fn i -> OutputLog.append(handle, "line #{i}") end)
      OutputLog.close(handle)

      # The fingerprint is at line 1 of a 201-line transcript — well outside
      # any bounded tail read (e.g. the last 40 lines).
      assert {:ok, tail} = OutputLog.tail_lines(run_id, 40)
      refute Enum.any?(tail, &String.contains?(&1, "PendingMigrationError"))

      assert {:ok, ["** (Phoenix.Ecto.PendingMigrationError) migrations pending"]} =
               OutputLog.scan_for(run_id, ["phoenix.ecto.pendingmigrationerror"])
    end

    test "matches case-insensitively", %{run_id: run_id} do
      {:ok, handle} = OutputLog.open(run_id)
      OutputLog.append(handle, "** (DBConnection.ConnectionError) connection failed")
      OutputLog.close(handle)

      assert {:ok, [_]} = OutputLog.scan_for(run_id, ["dbconnection.connectionerror"])
    end

    test "returns [] when no pattern matches", %{run_id: run_id} do
      {:ok, handle} = OutputLog.open(run_id)
      OutputLog.append(handle, "all good, arb done")
      OutputLog.close(handle)

      assert {:ok, []} = OutputLog.scan_for(run_id, ["phoenix.ecto.pendingmigrationerror"])
    end

    test "a missing transcript is {:error, :enoent}, not a crash", %{run_id: run_id} do
      assert {:error, :enoent} = OutputLog.scan_for(run_id, ["anything"])
    end
  end
end
