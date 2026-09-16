defmodule Arbiter.Sessions.TranscriptTest do
  @moduledoc """
  Persistent raw PTY capture (§11, phase 9 of
  `docs/browser-hosted-coordinator-sessions.md`): redaction on write and the
  per-file size cap. `Arbiter.Sessions.StreamTest` covers the wiring that
  feeds `append/3` from the live pipe.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Sessions.Transcript

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:arbiter, :sessions_root)
    Application.put_env(:arbiter, :sessions_root, tmp_dir)

    on_exit(fn ->
      if previous, do: Application.put_env(:arbiter, :sessions_root, previous)
    end)

    %{id: Ash.UUID.generate()}
  end

  describe "append/3" do
    test "creates the file at the documented path", %{id: id} do
      :ok = Transcript.append(id, "hello")

      assert Transcript.path_for(id) =~ "transcript/#{id}.raw"
      assert File.read!(Transcript.path_for(id)) == "hello"
    end

    test "appends across multiple calls", %{id: id} do
      :ok = Transcript.append(id, "hello ")
      :ok = Transcript.append(id, "world")

      assert File.read!(Transcript.path_for(id)) == "hello world"
    end

    test "redacts a known secret value before writing", %{id: id} do
      :ok = Transcript.append(id, "token=super-secret-value here", ["super-secret-value"])

      assert File.read!(Transcript.path_for(id)) == "token=[REDACTED] here"
    end

    test "redacts a credential-shaped token even when not a registered secret", %{id: id} do
      :ok = Transcript.append(id, "ANTHROPIC_API_KEY=sk-ant-abcdefghijklmnopqrstuvwxyz")

      assert File.read!(Transcript.path_for(id)) == "ANTHROPIC_API_KEY=[REDACTED]"
    end

    test "writes the file and its parent directory operator-only", %{id: id} do
      :ok = Transcript.append(id, "hello")

      path = Transcript.path_for(id)
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
    end

    test "drops bytes once the file is at or past max_bytes", %{id: id} do
      path = Transcript.path_for(id)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :binary.copy("x", Transcript.max_bytes()))

      :ok = Transcript.append(id, "overflow")

      assert File.read!(path) == :binary.copy("x", Transcript.max_bytes())
    end
  end

  describe "exists?/1" do
    test "false before any bytes captured", %{id: id} do
      refute Transcript.exists?(id)
    end

    test "true once a byte has been captured", %{id: id} do
      :ok = Transcript.append(id, "x")
      assert Transcript.exists?(id)
    end
  end
end
