defmodule Arbiter.Polecat.OutputLogTest do
  # async: false — we swap the :output_log_root application env per test.
  use ExUnit.Case, async: false

  alias Arbiter.Polecat.OutputLog

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
end
