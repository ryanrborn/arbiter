defmodule ArbiterCli.Scripts.CheckReleaseGlibcTest do
  @moduledoc """
  Coverage for `scripts/check-release-glibc.sh` — the release-time guard that
  refuses to ship an OTP release containing a shared object which needs a
  newer glibc than the build image provides (bd-drjpmr).

  Background: v0.1.64 could not boot on RHEL 8.10 (glibc 2.28) because
  `rustler_precompiled` *downloaded* the `mdex_native` NIF at compile time
  instead of building it, so the prebuilt artifact needed `GLIBC_2.34` even
  though the release was assembled inside `redhat/ubi8`. The guard makes that
  class of failure a red build instead of a failed deploy.

  The tests drive the script with synthetic fixtures: the guard reads the
  `GLIBC_x.y` symbol-version strings out of a file's bytes, so a plain file
  containing those strings exercises exactly the same code path a real ELF
  object does.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../scripts/check-release-glibc.sh", __DIR__)

  defp run(args) do
    System.cmd("bash", [@script | args], stderr_to_stdout: true)
  end

  # /tmp is shared across concurrently running workers on this host, so the
  # OS pid goes in the path too — `unique_integer` alone collides across VMs.
  defp tmp_dir!(tag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "glibc-guard-#{tag}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A stand-in for a shipped shared object: some binary noise plus the
  # `GLIBC_*` version strings the dynamic linker would record.
  defp write_so!(path, glibc_versions) do
    File.mkdir_p!(Path.dirname(path))

    body =
      [<<0x7F, ?E, ?L, ?F, 2, 1, 1, 0>>, "libm.so.6\0"] ++
        Enum.map(glibc_versions, &"GLIBC_#{&1}\0")

    File.write!(path, IO.iodata_to_binary(body))
    path
  end

  defp release_tree!(dir) do
    write_so!(Path.join(dir, "lib/exqlite-0.0.0/priv/sqlite3_nif.so"), ["2.14", "2.28"])
    write_so!(Path.join(dir, "erts-16.0/lib/crypto.so"), ["2.2.5", "2.14"])
    dir
  end

  describe "script contract" do
    test "exists and is executable" do
      assert File.exists?(@script)
      %File.Stat{mode: mode} = File.stat!(@script)
      assert Bitwise.band(mode, 0o100) != 0
    end

    test "--help prints usage and exits 0" do
      {out, code} = run(["--help"])
      assert code == 0
      assert out =~ "Usage: scripts/check-release-glibc.sh"
    end

    test "no arguments prints usage and exits 1" do
      {out, code} = run([])
      assert code == 1
      assert out =~ "Usage: scripts/check-release-glibc.sh"
    end

    test "a nonexistent path is an error, not a pass" do
      {out, code} = run(["/no/such/release/tree"])
      assert code == 1
      assert out =~ "/no/such/release/tree"
    end
  end

  describe "scanning a release directory" do
    test "passes when every shared object stays at or below the baseline" do
      dir = tmp_dir!("ok") |> release_tree!()

      {out, code} = run([dir])
      assert code == 0, out
      assert out =~ "2.28"
      assert out =~ "sqlite3_nif.so"
    end

    test "fails and names the offending file when a NIF needs a newer glibc" do
      dir = tmp_dir!("bad") |> release_tree!()

      write_so!(
        Path.join(dir, "lib/mdex_native-0.2.8/priv/native/libmdex_native_nif-v0.2.8.so"),
        ["2.17", "2.29", "2.34"]
      )

      {out, code} = run([dir])
      assert code == 1
      assert out =~ ~r/^ERROR: .*libmdex_native_nif-v0\.2\.8\.so.*GLIBC_2\.34/m
      # The files that are within baseline must not be reported as offenders.
      refute out =~ ~r/^ERROR: .*sqlite3_nif/m
    end

    test "compares versions numerically, not lexically" do
      # Lexical comparison would read "2.9" as greater than the 2.28 baseline.
      dir = tmp_dir!("numeric")
      write_so!(Path.join(dir, "lib/foo/priv/old.so"), ["2.2.5", "2.9"])

      {out, code} = run([dir])
      assert code == 0, out
    end

    test "catches versioned shared objects, not just bare .so names" do
      dir = tmp_dir!("soname") |> release_tree!()
      write_so!(Path.join(dir, "lib/foo/priv/libbar.so.1.2"), ["2.30"])

      {out, code} = run([dir])
      assert code == 1
      assert out =~ "libbar.so.1.2"
      assert out =~ "2.30"
    end

    test "--baseline raises the allowed ceiling" do
      dir = tmp_dir!("baseline") |> release_tree!()
      write_so!(Path.join(dir, "lib/foo/priv/new.so"), ["2.34"])

      assert {_, 1} = run([dir])
      assert {out, 0} = run(["--baseline", "2.34", dir])
      assert out =~ "2.34"
    end

    test "an empty scan fails instead of passing vacuously" do
      dir = tmp_dir!("empty")
      File.mkdir_p!(Path.join(dir, "lib"))

      {out, code} = run([dir])
      assert code == 1
      assert out =~ "no shared objects"
    end
  end

  describe "scanning a release tarball" do
    test "unpacks a .tar.gz and applies the same check" do
      dir = tmp_dir!("tar") |> release_tree!()

      write_so!(
        Path.join(dir, "lib/mdex_native-0.2.8/priv/native/libmdex_native_nif-v0.2.8.so"),
        ["2.34"]
      )

      tarball = Path.join(tmp_dir!("tarout"), "arbiter-v0.0.0-linux.tar.gz")
      {_, 0} = System.cmd("tar", ["-czf", tarball, "-C", dir, "."])

      {out, code} = run([tarball])
      assert code == 1
      assert out =~ "libmdex_native_nif-v0.2.8.so"
      assert out =~ "2.34"
    end

    test "passes a clean tarball" do
      dir = tmp_dir!("tarok") |> release_tree!()
      tarball = Path.join(tmp_dir!("tarokout"), "arbiter-v0.0.0-linux.tar.gz")
      {_, 0} = System.cmd("tar", ["-czf", tarball, "-C", dir, "."])

      {out, code} = run([tarball])
      assert code == 0, out
    end
  end

  describe "release workflow wiring" do
    @workflow Path.expand("../../../../.github/workflows/release.yml", __DIR__)

    setup do
      {:ok, yaml: File.read!(@workflow)}
    end

    test "forces a source build of the rustler_precompiled NIFs", %{yaml: yaml} do
      assert yaml =~ "RUSTLER_PRECOMPILED_FORCE_BUILD_ALL",
             "release.yml must force a source build so the NIF links against the ubi8 glibc"
    end

    test "provisions a Rust toolchain in the release container", %{yaml: yaml} do
      assert yaml =~ ~r/cargo|rustup/,
             "forcing a source build requires a Rust toolchain in the release job"
    end

    test "runs the glibc guard against the packaged tarball", %{yaml: yaml} do
      assert yaml =~ "scripts/check-release-glibc.sh",
             "release.yml must run the glibc guard before publishing"
    end
  end

  describe "local release build wiring" do
    @local_script Path.expand("../../../../scripts/build-local-release.sh", __DIR__)

    test "the local release build runs the same guard" do
      body = File.read!(@local_script)

      assert body =~ "check-release-glibc.sh",
             "scripts/build-local-release.sh must run the glibc guard too — " <>
               "`arb server deploy --local` ships the same NIFs"
    end
  end
end
