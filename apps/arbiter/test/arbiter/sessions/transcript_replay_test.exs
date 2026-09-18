defmodule Arbiter.Sessions.TranscriptReplayTest do
  @moduledoc """
  Reading a *finished* session's persisted raw transcript back (bd-3tf4oo):
  the bounded tail, the "showing last N" arithmetic, and the three ways a
  transcript can be missing. `Arbiter.Sessions.Transcript` owns the writing
  side; this owns the reading side, and nothing else reads that file.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Sessions.Transcript
  alias Arbiter.Sessions.TranscriptReplay

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:arbiter, :sessions_root)
    Application.put_env(:arbiter, :sessions_root, tmp_dir)

    on_exit(fn ->
      if previous, do: Application.put_env(:arbiter, :sessions_root, previous)
    end)

    %{id: Ash.UUID.generate()}
  end

  defp ended(id, opts \\ []) do
    %{
      id: id,
      status: :ended,
      ended_at: Keyword.get(opts, :ended_at, DateTime.utc_now()),
      end_reason: Keyword.get(opts, :end_reason, "killed")
    }
  end

  describe "describe/1" do
    test "reports a captured transcript as available with its size", %{id: id} do
      :ok = Transcript.append(id, "hello world")

      assert %{available?: true, reason: nil, total_bytes: 11, truncated?: false} =
               TranscriptReplay.describe(ended(id))
    end

    test "a session that ended inside the retention window and has no file was never captured",
         %{id: id} do
      assert %{available?: false, reason: :never_captured} = TranscriptReplay.describe(ended(id))
    end

    test "a session that ended past the retention window had its transcript swept", %{id: id} do
      old = DateTime.add(DateTime.utc_now(), -(Transcript.retention_days() + 1), :day)

      assert %{available?: false, reason: :retention_deleted} =
               TranscriptReplay.describe(ended(id, ended_at: old))
    end

    test "an empty capture file is not presented as a transcript", %{id: id} do
      File.mkdir_p!(Path.dirname(Transcript.path_for(id)))
      File.write!(Transcript.path_for(id), "")

      assert %{available?: false, reason: :empty} = TranscriptReplay.describe(ended(id))
    end

    test "flags a transcript over the replay cap as truncated", %{id: id} do
      :ok = Transcript.append(id, String.duplicate("x", 200))

      assert %{available?: true, truncated?: true, replay_bytes: 50, total_bytes: 200} =
               TranscriptReplay.describe(ended(id), max_bytes: 50)
    end
  end

  describe "read_tail/2" do
    test "returns the whole file when it fits under the cap", %{id: id} do
      :ok = Transcript.append(id, "abcdef")

      assert {:ok, %{data: "abcdef", start_offset: 0, end_offset: 6, truncated?: false}} =
               TranscriptReplay.read_tail(id)
    end

    test "returns only the last max_bytes of a larger file", %{id: id} do
      :ok = Transcript.append(id, "0123456789")

      assert {:ok, tail} = TranscriptReplay.read_tail(id, max_bytes: 4)
      assert tail.data == "6789"
      assert tail.start_offset == 6
      assert tail.end_offset == 10
      assert tail.total_bytes == 10
      assert tail.truncated?
    end

    test "is an error when the file is missing", %{id: id} do
      assert {:error, :enoent} = TranscriptReplay.read_tail(id)
    end
  end
end
