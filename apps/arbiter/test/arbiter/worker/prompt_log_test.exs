defmodule Arbiter.Worker.PromptLogTest do
  # async: false — we swap the :output_log_root application env per test.
  use ExUnit.Case, async: false

  alias Arbiter.Worker.PromptLog

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)
    root = Path.join(System.tmp_dir!(), "prompt-log-test-#{System.unique_integer([:positive])}")
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

  test "path_for/1 lives beside the transcript, keyed by run id", %{root: root, run_id: run_id} do
    assert PromptLog.path_for(run_id) == Path.join(root, run_id <> ".prompt")
  end

  test "write/2 creates the parent dir and persists the prompt verbatim", %{
    root: root,
    run_id: run_id
  } do
    refute File.dir?(root)

    assert :ok = PromptLog.write(run_id, "you are a helpful worker\n\ndo the thing")
    assert File.dir?(root)
    assert {:ok, "you are a helpful worker\n\ndo the thing"} = PromptLog.read(run_id)
  end

  test "write/2 overwrites rather than appends on a re-open (one prompt per run)", %{
    run_id: run_id
  } do
    :ok = PromptLog.write(run_id, "first")
    :ok = PromptLog.write(run_id, "second")

    assert {:ok, "second"} = PromptLog.read(run_id)
  end

  test "read/1 returns {:error, :enoent} when no prompt file exists", %{run_id: run_id} do
    assert {:error, :enoent} = PromptLog.read(run_id)
  end

  test "write/2 rejects a blank/invalid run id" do
    assert {:error, :invalid_run_id} = PromptLog.write("", "prompt")
    assert {:error, :invalid_run_id} = PromptLog.write(nil, "prompt")
  end

  test "sha256/1 is a stable hex digest of the exact content" do
    digest = PromptLog.sha256("hello world")
    assert digest == PromptLog.sha256("hello world")
    assert digest != PromptLog.sha256("hello world!")
    assert String.length(digest) == 64
    assert digest =~ ~r/^[0-9a-f]{64}$/
  end

  test "append/2 adds a separated continuation to an existing prompt file", %{run_id: run_id} do
    :ok = PromptLog.write(run_id, "original prompt")
    :ok = PromptLog.append(run_id, "nudge: please commit")

    assert {:ok, content} = PromptLog.read(run_id)
    assert content =~ "original prompt"
    assert content =~ "nudge: please commit"
    assert content =~ ~r/original prompt.*nudge: please commit/s
  end
end
