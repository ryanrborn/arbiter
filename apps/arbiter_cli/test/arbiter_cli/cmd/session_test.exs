defmodule ArbiterCli.Cmd.SessionTest do
  @moduledoc """
  RFC §4.7 fallback path (bd-3qkbch, phase 10) — `arb session list` /
  `arb session attach`, both reading systemd/tmux directly. This is exactly
  the surface that must work with the Arbiter server down, so these tests
  never touch `Client`/HTTP at all; they fake `systemctl` on `PATH` instead.

  `attach`'s real terminal handoff (`Port.open(..., [:nouse_stdio, ...])`) is
  not exercised here — there is no meaningful way to assert full-screen
  terminal takeover headlessly. That path is a documented manual check
  (see the moduledoc of `ArbiterCli.Cmd.Session`); what *is* tested is every
  branch reachable without a live tmux server: id-not-found, no-tmux-on-PATH.
  """
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Session

  setup do
    prior_path = System.get_env("PATH")
    prior_runtime_dir = System.get_env("XDG_RUNTIME_DIR")

    on_exit(fn ->
      if prior_path, do: System.put_env("PATH", prior_path)
      if prior_runtime_dir, do: System.put_env("XDG_RUNTIME_DIR", prior_runtime_dir)
    end)

    base = Path.join(System.tmp_dir!(), "arb-cli-session-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(base, "bin")
    runtime_dir = Path.join(base, "runtime")
    File.mkdir_p!(fake_bin)
    File.mkdir_p!(Path.join(runtime_dir, "arbiter"))
    System.put_env("XDG_RUNTIME_DIR", runtime_dir)

    on_exit(fn -> File.rm_rf(base) end)

    {:ok, base: base, fake_bin: fake_bin, runtime_dir: runtime_dir}
  end

  defp write_fake_systemctl!(fake_bin, output, exit_code) do
    path = Path.join(fake_bin, "systemctl")

    File.write!(path, """
    #!/bin/sh
    cat <<'EOF'
    #{output}
    EOF
    exit #{exit_code}
    """)

    File.chmod!(path, 0o755)
  end

  defp prepend_path(fake_bin) do
    System.put_env("PATH", fake_bin <> ":" <> System.get_env("PATH", ""))
  end

  describe "arb session list" do
    test "prints every live arb-session-* scope, parsed from systemctl", %{fake_bin: fake_bin} do
      write_fake_systemctl!(
        fake_bin,
        "arb-session-aaa.scope loaded active running tmux …\n" <>
          "arb-session-bbb.scope loaded active running tmux …\n" <>
          "some-other.service    loaded active running unrelated\n",
        0
      )

      prepend_path(fake_bin)

      {out, _err, code} = capture(fn -> Session.run(["list"]) end)

      assert code == 0
      assert out =~ "aaa"
      assert out =~ "bbb"
      refute out =~ "some-other"
    end

    test "prints a friendly message when nothing is live", %{fake_bin: fake_bin} do
      write_fake_systemctl!(fake_bin, "", 0)
      prepend_path(fake_bin)

      {out, _err, code} = capture(fn -> Session.run(["list"]) end)

      assert code == 0
      assert out =~ "No live"
    end

    test "--json emits a data array", %{fake_bin: fake_bin} do
      write_fake_systemctl!(fake_bin, "arb-session-ccc.scope loaded active running tmux …\n", 0)
      prepend_path(fake_bin)

      {out, _err, code} = capture(fn -> Session.run(["list", "--json"]) end)

      assert code == 0
      assert %{"data" => [%{"id" => "ccc"}]} = Jason.decode!(out)
    end

    test "a systemctl failure dies with a hint, not a crash", %{fake_bin: fake_bin} do
      write_fake_systemctl!(fake_bin, "Failed to connect to bus: No such file or directory", 1)
      prepend_path(fake_bin)

      {_out, err, code} = capture(fn -> Session.run(["list"]) end)

      assert code == 1
      assert err =~ "systemctl exited"
      assert err =~ "systemd --user manager"
    end
  end

  describe "arb session attach" do
    test "dies with no id given" do
      {_out, err, code} = capture(fn -> Session.run(["attach"]) end)

      assert code == 1
      assert err =~ "needs a session id"
    end

    test "dies when there is no tmux socket for the given id", %{runtime_dir: runtime_dir} do
      {_out, err, code} = capture(fn -> Session.run(["attach", "nonexistent-id"]) end)

      assert code == 1
      assert err =~ "no tmux socket"
      assert err =~ Path.join([runtime_dir, "arbiter", "session-nonexistent-id.sock"])
    end

    test "--read-only is accepted alongside the id", %{runtime_dir: runtime_dir} do
      # Same missing-socket failure, just proving the flag doesn't get read
      # as the session id.
      {_out, err, code} = capture(fn -> Session.run(["attach", "abc", "--read-only"]) end)

      assert code == 1
      assert err =~ Path.join([runtime_dir, "arbiter", "session-abc.sock"])
    end

    test "dies with a hint when tmux is not on PATH", %{
      runtime_dir: runtime_dir,
      fake_bin: fake_bin
    } do
      socket = Path.join([runtime_dir, "arbiter", "session-abc.sock"])
      File.write!(socket, "")

      # Point PATH at a directory that has no `tmux`, so the socket-exists
      # check passes but `System.find_executable("tmux")` must fail.
      System.put_env("PATH", fake_bin)

      {_out, err, code} = capture(fn -> Session.run(["attach", "abc"]) end)

      assert code == 1
      assert err =~ "tmux not found on PATH"
    end
  end

  describe "arb session --help" do
    test "prints usage" do
      {out, _err, code} = capture(fn -> Session.run(["--help"]) end)

      assert code == 0
      assert out =~ "arb session list"
      assert out =~ "arb session attach"
    end
  end
end
