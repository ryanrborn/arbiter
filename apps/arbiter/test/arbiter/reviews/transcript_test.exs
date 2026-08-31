defmodule Arbiter.Reviews.TranscriptTest do
  # async: false — we swap the :output_log_root application env per test.
  use ExUnit.Case, async: false

  alias Arbiter.Reviews.Transcript
  alias Arbiter.Worker.OutputLog

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)

    root =
      Path.join(System.tmp_dir!(), "review-transcript-test-#{System.unique_integer([:positive])}")

    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev do
        Application.put_env(:arbiter, :output_log_root, prev)
      else
        Application.delete_env(:arbiter, :output_log_root)
      end
    end)

    %{root: root, record_id: "rec-#{System.unique_integer([:positive])}"}
  end

  defp stream_json do
    Enum.join(
      [
        ~s({"type":"system","subtype":"init","model":"claude-opus-5","session_id":"sess-1"}),
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"Reading the diff."}]}}),
        ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"Read","input":{"file_path":"lib/a.ex"}}]}}),
        ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"defmodule A do"}]}}),
        ~s({"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Grep","input":{"pattern":"secret"}}]}}),
        ~s({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"no matches"}]}]}}),
        ~s({"type":"result","subtype":"success","result":"{\\"findings\\": []}","total_cost_usd":0.12})
      ],
      "\n"
    )
  end

  describe "path scheme" do
    test "keys the transcript by review record id under the shared log root", %{
      root: root,
      record_id: id
    } do
      assert Transcript.path_for(id) == Path.join(root, id <> ".log")
      # Beside the prompt file the review dispatch path already writes.
      assert Transcript.prompt_path_for(id) == Path.join(root, id <> ".prompt")
      # Same scheme the regular worker-run transcript pipeline uses.
      assert Transcript.path_for(id) == OutputLog.path_for(id)
    end

    test "rejects a blank record id" do
      assert {:error, :invalid_record_id} = Transcript.write("", "x")
      assert {:error, :invalid_record_id} = Transcript.read_lines(nil)
    end
  end

  describe "write/3 and read_lines/1" do
    test "persists the raw output verbatim, creating the root dir", %{root: root, record_id: id} do
      refute File.dir?(root)

      assert :ok = Transcript.write(id, stream_json())

      assert File.regular?(Transcript.path_for(id))
      assert {:ok, lines} = Transcript.read_lines(id)
      assert length(lines) == 7
      assert hd(lines) =~ ~s("subtype":"init")
    end

    test "redacts the supplied secret values before they hit disk", %{record_id: id} do
      assert :ok =
               Transcript.write(id, ~s({"type":"assistant","text":"token hunter2"}), ["hunter2"])

      {:ok, [line]} = Transcript.read_lines(id)
      refute line =~ "hunter2"
      assert line =~ "REDACTED"
    end

    test "truncates rather than appending, so a retried review has one transcript", %{
      record_id: id
    } do
      assert :ok = Transcript.write(id, "first\nattempt")
      assert :ok = Transcript.write(id, "second")

      assert {:ok, ["second"]} = Transcript.read_lines(id)
    end

    test "read_lines/1 reports :enoent when nothing was captured", %{record_id: id} do
      assert {:error, :enoent} = Transcript.read_lines(id)
    end
  end

  describe "prompt/1" do
    test "reads the prompt persisted by the review dispatch path", %{record_id: id} do
      :ok = Arbiter.Worker.PromptLog.write(id, "You are a code reviewer.")
      assert {:ok, "You are a code reviewer."} = Transcript.prompt(id)
    end

    test "is :enoent when no prompt was persisted", %{record_id: id} do
      assert {:error, :enoent} = Transcript.prompt(id)
    end
  end

  describe "events/1" do
    test "normalizes the stream-json corpus into ordered, renderable events", %{record_id: id} do
      :ok = Transcript.write(id, stream_json())

      events = Transcript.events(id)

      assert Enum.map(events, & &1.kind) == [
               :system,
               :assistant_text,
               :tool_use,
               :tool_result,
               :tool_use,
               :tool_result,
               :result
             ]

      assert %{kind: :system, model: "claude-opus-5", session_id: "sess-1"} = Enum.at(events, 0)
      assert %{kind: :assistant_text, text: "Reading the diff."} = Enum.at(events, 1)

      assert %{kind: :tool_use, name: "Read", tool_use_id: "toolu_1", input: input} =
               Enum.at(events, 2)

      assert input["file_path"] == "lib/a.ex"

      assert %{kind: :tool_result, tool_use_id: "toolu_1", text: "defmodule A do"} =
               Enum.at(events, 3)

      # tool_result content also arrives as a list of content blocks.
      assert %{kind: :tool_result, text: "no matches"} = Enum.at(events, 5)
      assert %{kind: :result, text: ~s({"findings": []})} = Enum.at(events, 6)
    end

    test "keeps a non-JSON line as a raw event rather than dropping it", %{record_id: id} do
      :ok = Transcript.write(id, "some stderr noise\n" <> ~s({"type":"result","result":"ok"}))

      assert [%{kind: :raw, text: "some stderr noise"}, %{kind: :result}] = Transcript.events(id)
    end

    test "is an empty list when no transcript exists", %{record_id: id} do
      assert Transcript.events(id) == []
    end
  end

  describe "tool_uses/1 and summary/1" do
    test "tool_uses/1 pairs each call with the result it got back", %{record_id: id} do
      :ok = Transcript.write(id, stream_json())

      assert [read, grep] = Transcript.tool_uses(id)
      assert read.name == "Read"
      assert read.input["file_path"] == "lib/a.ex"
      assert read.result == "defmodule A do"
      assert grep.name == "Grep"
      assert grep.result == "no matches"
    end

    test "summary/1 reports capture state, size and the tool histogram", %{record_id: id} do
      :ok = Arbiter.Worker.PromptLog.write(id, "prompt bytes")
      :ok = Transcript.write(id, stream_json())

      assert %{
               exists: true,
               prompt_exists: true,
               line_count: 7,
               tool_use_count: 2,
               tools_used: [%{name: "Grep", count: 1}, %{name: "Read", count: 1}]
             } = Transcript.summary(id)

      assert Transcript.summary(id).path == Transcript.path_for(id)
    end

    test "summary/1 of an uncaptured review reports absence, not a crash", %{record_id: id} do
      assert %{
               exists: false,
               prompt_exists: false,
               line_count: 0,
               tool_use_count: 0,
               tools_used: []
             } = Transcript.summary(id)
    end
  end
end
