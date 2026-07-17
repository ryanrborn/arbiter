defmodule Arbiter.VersionTest do
  use ExUnit.Case, async: true

  describe "Arbiter.Version" do
    test "app_version/0 returns a string" do
      assert is_binary(Arbiter.Version.app_version())
    end

    test "git_sha/0 returns a string" do
      assert is_binary(Arbiter.Version.git_sha())
    end

    test "built_at/0 returns a string" do
      assert is_binary(Arbiter.Version.built_at())
    end

    test "git_sha reflects current HEAD, not stale compile-time value" do
      {expected_sha, 0} =
        System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true)

      assert Arbiter.Version.git_sha() == String.trim(expected_sha)
    end

    test "built_at is a valid ISO-8601 timestamp" do
      {:ok, _dt, _} = DateTime.from_iso8601(Arbiter.Version.built_at())
    end
  end
end
