defmodule Arbiter.Sessions.BridgeVerificationTest do
  @moduledoc """
  §8.3's design consequence 2: verify the bridge came up by polling the
  session JSONL for a `bridge-session` record, rather than trusting a clean
  launch exit code (phase 8, bd-2n0tb6).
  """
  use ExUnit.Case, async: true

  alias Arbiter.Sessions.BridgeVerification

  @fixture Path.expand("../../fixtures/claude_sessions/bridge_session_sample.jsonl", __DIR__)

  defp tmp_config_dir!(tag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "bd-2n0tb6-#{tag}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, "projects/proj"))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "finds a bridge-session record already on disk immediately" do
    config_dir = tmp_config_dir!("present")

    File.cp!(
      @fixture,
      Path.join(config_dir, "projects/proj/some-session.jsonl")
    )

    started_at = System.monotonic_time(:millisecond)

    assert :ok =
             BridgeVerification.verify(config_dir, timeout_ms: 5_000, poll_interval_ms: 500)

    # Found on the first read, not after waiting out most of the timeout.
    assert System.monotonic_time(:millisecond) - started_at < 500
  end

  test "times out with :bridge_unavailable when no bridge-session record ever appears" do
    config_dir = tmp_config_dir!("absent")

    File.write!(
      Path.join(config_dir, "projects/proj/some-session.jsonl"),
      ~s({"type":"assistant","sessionId":"x"}\n)
    )

    assert {:error, :bridge_unavailable} =
             BridgeVerification.verify(config_dir, timeout_ms: 80, poll_interval_ms: 20)
  end

  test "times out with :bridge_unavailable when the config dir has no JSONL at all" do
    config_dir = tmp_config_dir!("empty")

    assert {:error, :bridge_unavailable} =
             BridgeVerification.verify(config_dir, timeout_ms: 80, poll_interval_ms: 20)
  end

  test "a bridge-session record that appears mid-poll is picked up before the timeout" do
    config_dir = tmp_config_dir!("appears-later")
    path = Path.join(config_dir, "projects/proj/some-session.jsonl")
    File.write!(path, ~s({"type":"assistant","sessionId":"x"}\n))

    task =
      Task.async(fn ->
        BridgeVerification.verify(config_dir, timeout_ms: 5_000, poll_interval_ms: 50)
      end)

    Process.sleep(120)
    File.write!(path, File.read!(@fixture))

    assert :ok = Task.await(task, 5_000)
  end
end
