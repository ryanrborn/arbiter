defmodule Arbiter.Workers.SessionArchiveBackfillTest do
  # bd-db0p38. Claude Code prunes its session store at ~21 days, so the
  # surviving history has to be rescued before the next prune — once for the
  # corpus, then never again (the live path takes over at run completion).
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker.SessionArchive
  alias Arbiter.Workers.{Run, SessionArchiveBackfill}

  @line ~s({"type":"assistant","message":{"id":"m-1","content":[{"type":"thinking","thinking":"ground truth"}]}})

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)
    root = Path.join(System.tmp_dir!(), "archive-backfill-#{System.unique_integer([:positive])}")
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev,
        do: Application.put_env(:arbiter, :output_log_root, prev),
        else: Application.delete_env(:arbiter, :output_log_root)
    end)

    %{root: root}
  end

  defp session_file!(session_id, body) do
    config_dir = Path.join(System.tmp_dir!(), "cfg-#{System.unique_integer([:positive])}")
    dir = Path.join([config_dir, "projects", "-home-ryan-dev-arbiter"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, session_id <> ".jsonl"), body)
    on_exit(fn -> File.rm_rf(config_dir) end)
    config_dir
  end

  defp run!(attrs \\ %{}) do
    session_id = "sess-#{System.unique_integer([:positive])}"

    config_dir =
      Map.get_lazy(attrs, :config_dir, fn -> session_file!(session_id, @line <> "\n") end)

    {:ok, run} =
      Ash.create(
        Run,
        Map.merge(
          %{
            task_id: "bd-ab-#{System.unique_integer([:positive])}",
            repo: "arbiter",
            status: :completed,
            started_at: ~U[2026-08-25 20:49:00.000000Z],
            session_id: session_id,
            config_dir: config_dir
          },
          attrs
        )
      )

    run
  end

  test "dry run is the default: it reports what it would rescue and writes nothing" do
    run = run!()

    report = SessionArchiveBackfill.backfill()

    assert report.apply? == false
    assert report.scanned >= 1
    assert report.archived >= 1
    refute SessionArchive.archived?(run.id)
  end

  test "--apply rescues surviving session files into the durable log root" do
    run = run!()

    report = SessionArchiveBackfill.backfill(apply?: true)

    assert report.archived >= 1
    assert report.bytes_out > 0
    assert SessionArchive.archived?(run.id)
    assert {:ok, body} = SessionArchive.read(run.id)
    assert body =~ "ground truth"
  end

  test "a pruned session file is counted, not silently skipped" do
    cfg = Path.join(System.tmp_dir!(), "cfg-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([cfg, "projects", "-slug"]))
    on_exit(fn -> File.rm_rf(cfg) end)

    _run = run!(%{config_dir: cfg})

    report = SessionArchiveBackfill.backfill(apply?: true)
    assert report.no_session_file >= 1
  end

  test "a non-Claude run is reported as such, not as a lost Claude file" do
    _run = run!(%{config_dir: nil})

    report = SessionArchiveBackfill.backfill(apply?: true)
    assert report.no_config_dir >= 1
    assert report.no_session_file == 0
  end

  test "re-running skips runs already archived, so a second pass is cheap" do
    run = run!()

    first = SessionArchiveBackfill.backfill(apply?: true)
    assert first.archived >= 1

    second = SessionArchiveBackfill.backfill(apply?: true)
    assert second.archived == 0
    assert second.already_archived >= 1
    assert SessionArchive.archived?(run.id)
  end

  test "`:force` re-archives an already-archived run" do
    run = run!()
    assert %{archived: n} = SessionArchiveBackfill.backfill(apply?: true)
    assert n >= 1

    forced = SessionArchiveBackfill.backfill(apply?: true, force: true)
    assert forced.archived >= 1
    assert forced.already_archived == 0
    assert SessionArchive.archived?(run.id)
  end

  test "`:limit` bounds the pass so the corpus can be rescued in batches" do
    for _ <- 1..3, do: run!()

    report = SessionArchiveBackfill.backfill(apply?: true, limit: 2)
    assert report.scanned == 2
  end
end
