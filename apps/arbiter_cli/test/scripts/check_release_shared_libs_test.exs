defmodule ArbiterCli.Scripts.CheckReleaseSharedLibsTest do
  @moduledoc """
  Coverage for `scripts/check-release-shared-libs.sh` — the release-time guard
  that refuses to ship an OTP release containing a binary that dynamically
  links a shared library outside a small allowlist of libraries every
  supported Linux host has (bd-c6h5dr / #1977).

  Background: v0.1.69 was built in `redhat/ubi8` against the rabbitmq OTP
  RPM, whose `crypto` NIF needs `libcrypto.so.1.1`. Fedora 44 only has
  OpenSSL 3, so `kernel` died in `on_load` at boot. The glibc guard could not
  see that — the NIF's glibc symbol versions were fine; the library it asked
  for simply was not there.

  The fixtures are real (minimal) ELF64 shared objects with exactly the
  `DT_NEEDED` entries a test asks for, so the script's `readelf -d` parsing
  runs against the same structure it meets in a real release.
  """
  use ExUnit.Case, async: true

  import Bitwise

  @script Path.expand("../../../../scripts/check-release-shared-libs.sh", __DIR__)

  defp run(args) do
    System.cmd("bash", [@script | args], stderr_to_stdout: true)
  end

  # /tmp is shared across concurrently running workers on this host, so the
  # OS pid goes in the path too — `unique_integer` alone collides across VMs.
  defp tmp_dir!(tag) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "shlib-guard-#{tag}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A minimal x86-64 ELF64 ET_DYN object: one PT_LOAD mapping the whole file
  # at vaddr 0, a PT_DYNAMIC holding one DT_NEEDED per name plus
  # DT_STRTAB/DT_STRSZ, and matching .dynstr/.dynamic/.shstrtab section
  # headers — enough for `readelf -d` to list the NEEDED entries.
  defp elf_with_needed(needed) do
    ehsize = 64
    phentsize = 56
    shentsize = 64
    phnum = 2
    shnum = 4

    dynstr = IO.iodata_to_binary(["\0" | Enum.map(needed, &[&1, "\0"])])

    {name_offsets, _} =
      Enum.map_reduce(needed, 1, fn name, off -> {off, off + byte_size(name) + 1} end)

    dynstr_off = ehsize + phnum * phentsize
    dyn_off = align8(dynstr_off + byte_size(dynstr))

    dynamic =
      IO.iodata_to_binary(
        Enum.map(name_offsets, &dyn_entry(1, &1)) ++
          [dyn_entry(5, dynstr_off), dyn_entry(10, byte_size(dynstr)), dyn_entry(0, 0)]
      )

    shstrtab = "\0.dynstr\0.dynamic\0.shstrtab\0"
    shstrtab_off = dyn_off + byte_size(dynamic)
    shoff = align8(shstrtab_off + byte_size(shstrtab))
    total = shoff + shnum * shentsize

    header =
      <<0x7F, "ELF", 2, 1, 1, 0, 0::64, 3::little-16, 62::little-16, 1::little-32,
        0::little-64, ehsize::little-64, shoff::little-64, 0::little-32, ehsize::little-16,
        phentsize::little-16, phnum::little-16, shentsize::little-16, shnum::little-16,
        3::little-16>>

    phdrs =
      phdr(1, 4, 0, total, 0x1000) <> phdr(2, 6, dyn_off, byte_size(dynamic), 8)

    shdrs =
      IO.iodata_to_binary([
        <<0::size(shentsize * 8)>>,
        shdr(1, 3, 2, dynstr_off, byte_size(dynstr), 0, 1, 0),
        shdr(9, 6, 3, dyn_off, byte_size(dynamic), 1, 8, 16),
        shdr(18, 3, 0, shstrtab_off, byte_size(shstrtab), 0, 1, 0)
      ])

    IO.iodata_to_binary([
      header,
      phdrs,
      pad_to(dynstr, dyn_off - dynstr_off),
      dynamic,
      pad_to(shstrtab, shoff - shstrtab_off),
      shdrs
    ])
  end

  defp align8(n), do: n + rem(8 - rem(n, 8), 8)
  defp pad_to(bin, size), do: bin <> :binary.copy(<<0>>, size - byte_size(bin))
  defp dyn_entry(tag, val), do: <<tag::little-signed-64, val::little-64>>

  defp phdr(type, flags, off, size, align) do
    <<type::little-32, flags::little-32, off::little-64, off::little-64, off::little-64,
      size::little-64, size::little-64, align::little-64>>
  end

  defp shdr(name, type, flags, off, size, link, align, entsize) do
    <<name::little-32, type::little-32, flags::little-64, off::little-64, off::little-64,
      size::little-64, link::little-32, 0::little-32, align::little-64, entsize::little-64>>
  end

  defp write_elf!(path, needed) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, elf_with_needed(needed))
    path
  end

  # The shape of a healthy release: every NEEDED entry is on the allowlist.
  defp release_tree!(dir) do
    write_elf!(Path.join(dir, "erts-16.4.0.2/bin/beam.smp"), [
      "libdl.so.2",
      "libtinfo.so.6",
      "libpthread.so.0",
      "librt.so.1",
      "libstdc++.so.6",
      "libm.so.6",
      "libgcc_s.so.1",
      "libc.so.6"
    ])

    write_elf!(Path.join(dir, "erts-16.4.0.2/bin/run_erl"), ["libutil.so.1", "libc.so.6"])
    write_elf!(Path.join(dir, "lib/crypto-5.8.3/priv/lib/crypto.so"), ["libc.so.6"])
    write_elf!(Path.join(dir, "lib/exqlite-0.39.0/priv/sqlite3_nif.so"), ["libc.so.6"])

    write_elf!(Path.join(dir, "lib/mdex_native-0.2.8/priv/native/mdex_native_nif.so"), [
      "libgcc_s.so.1",
      "libc.so.6",
      "ld-linux-x86-64.so.2"
    ])

    dir
  end

  describe "fixture sanity" do
    test "readelf sees the DT_NEEDED entries the fixture builder writes" do
      path = write_elf!(Path.join(tmp_dir!("fixture"), "x.so"), ["libfoo.so.1", "libc.so.6"])

      {out, 0} = System.cmd("readelf", ["-d", path], stderr_to_stdout: true)
      assert out =~ "Shared library: [libfoo.so.1]"
      assert out =~ "Shared library: [libc.so.6]"
    end
  end

  describe "script contract" do
    test "exists and is executable" do
      assert File.exists?(@script)
      %File.Stat{mode: mode} = File.stat!(@script)
      assert band(mode, 0o100) != 0
    end

    test "--help prints usage and exits 0" do
      {out, code} = run(["--help"])
      assert code == 0
      assert out =~ "Usage: scripts/check-release-shared-libs.sh"
    end

    test "no arguments prints usage and exits 1" do
      {out, code} = run([])
      assert code == 1
      assert out =~ "Usage: scripts/check-release-shared-libs.sh"
    end

    test "a nonexistent path is an error, not a pass" do
      {out, code} = run(["/no/such/release/tree"])
      assert code == 1
      assert out =~ "/no/such/release/tree"
    end
  end

  describe "scanning a release directory" do
    test "passes when every NEEDED library is on the allowlist" do
      dir = tmp_dir!("ok") |> release_tree!()

      {out, code} = run([dir])
      assert code == 0, out
      assert out =~ "sqlite3_nif.so"
      assert out =~ "beam.smp"
    end

    test "fails on the v0.1.69 crypto NIF's libcrypto.so.1.1 dependency, naming the file" do
      dir = tmp_dir!("crypto") |> release_tree!()

      write_elf!(Path.join(dir, "lib/crypto-5.8.3/priv/lib/crypto.so"), [
        "libcrypto.so.1.1",
        "libc.so.6"
      ])

      {out, code} = run([dir])
      assert code == 1

      assert out =~
               ~r/^ERROR: lib\/crypto-5\.8\.3\/priv\/lib\/crypto\.so needs libcrypto\.so\.1\.1/m

      # Allowed dependencies of the same file, and clean files, are not offenders.
      refute out =~ ~r/^ERROR: .*libc\.so\.6/m
      refute out =~ ~r/^ERROR: .*sqlite3_nif/m
    end

    test "an OpenSSL 3 libcrypto is not allowed either — the NIF must not link one at all" do
      dir = tmp_dir!("crypto3") |> release_tree!()
      write_elf!(Path.join(dir, "lib/crypto-5.8.3/priv/lib/crypto.so"), ["libcrypto.so.3"])

      {out, 1} = run([dir])
      assert out =~ ~r/^ERROR: .*crypto\.so needs libcrypto\.so\.3/m
    end

    test "reports every disallowed dependency, not just the first" do
      dir = tmp_dir!("many") |> release_tree!()

      write_elf!(Path.join(dir, "erts-16.4.0.2/bin/beam.smp"), [
        "libz.so.1",
        "libm.so.6",
        "libc.so.6"
      ])

      write_elf!(Path.join(dir, "erts-16.4.0.2/bin/epmd"), ["libsystemd.so.0", "libc.so.6"])

      {out, 1} = run([dir])
      assert out =~ ~r/^ERROR: erts-16\.4\.0\.2\/bin\/beam\.smp needs libz\.so\.1/m
      assert out =~ ~r/^ERROR: erts-16\.4\.0\.2\/bin\/epmd needs libsystemd\.so\.0/m
      assert out =~ "2 disallowed"
    end

    test "finds ELF binaries by content, not only by a .so name" do
      dir = tmp_dir!("exe") |> release_tree!()
      write_elf!(Path.join(dir, "erts-16.4.0.2/bin/inet_gethost"), ["libfoo.so.9"])

      {out, 1} = run([dir])
      assert out =~ ~r/^ERROR: erts-16\.4\.0\.2\/bin\/inet_gethost needs libfoo\.so\.9/m
    end

    test "a statically linked ELF (no NEEDED entries) passes" do
      dir = tmp_dir!("static") |> release_tree!()
      write_elf!(Path.join(dir, "lib/foo/priv/static_helper"), [])

      {out, 0} = run([dir])
      assert out =~ "static_helper"
    end

    test "--allow extends the allowlist" do
      dir = tmp_dir!("allow") |> release_tree!()
      write_elf!(Path.join(dir, "lib/foo/priv/foo.so"), ["libfoo.so.1", "libc.so.6"])

      assert {_, 1} = run([dir])
      assert {out, 0} = run(["--allow", "libfoo.so.1", dir])
      assert out =~ "foo.so"
    end

    # `scripts/build-local-release.sh` builds with the host's own OTP (whose
    # crypto NIF links the host's libcrypto) for a release that only ever runs
    # on that host; --host accepts what this machine's loader can resolve.
    test "--host also accepts libraries this host's dynamic loader resolves" do
      dir = tmp_dir!("host") |> release_tree!()
      # zlib is in the loader cache of every CI runner and dev host, but is
      # deliberately not on the portable allowlist.
      write_elf!(Path.join(dir, "lib/foo/priv/foo.so"), ["libz.so.1", "libc.so.6"])

      assert {_, 1} = run([dir])
      assert {out, 0} = run(["--host", dir])
      assert out =~ "foo.so"
    end

    test "--host still rejects a library this host does not have" do
      dir = tmp_dir!("hostmiss") |> release_tree!()
      write_elf!(Path.join(dir, "lib/foo/priv/foo.so"), ["libarbiter-no-such-lib.so.42"])

      {out, 1} = run(["--host", dir])
      assert out =~ ~r/^ERROR: lib\/foo\/priv\/foo\.so needs libarbiter-no-such-lib\.so\.42/m
    end

    test "an ELF file readelf cannot parse fails the check instead of being skipped" do
      dir = tmp_dir!("corrupt") |> release_tree!()
      path = Path.join(dir, "lib/foo/priv/broken.so")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, <<0x7F, "ELF", 2, 1, 1, 0>> <> :binary.copy(<<0xFF>>, 32))

      {out, 1} = run([dir])
      assert out =~ ~r/^ERROR: lib\/foo\/priv\/broken\.so/m
    end

    test "non-ELF files are ignored, even when named like a shared object" do
      dir = tmp_dir!("nonelf") |> release_tree!()
      File.write!(Path.join(dir, "lib/crypto-5.8.3/priv/lib/notes.so.txt"), "text")
      File.write!(Path.join(dir, "lib/crypto-5.8.3/priv/lib/linker-script.so"), "INPUT(x)")

      assert {_, 0} = run([dir])
    end

    test "an empty scan fails instead of passing vacuously" do
      dir = tmp_dir!("empty")
      File.mkdir_p!(Path.join(dir, "lib"))

      {out, 1} = run([dir])
      assert out =~ "no ELF binaries"
    end
  end

  describe "scanning a release tarball" do
    test "unpacks a .tar.gz and applies the same check" do
      dir = tmp_dir!("tar") |> release_tree!()
      write_elf!(Path.join(dir, "lib/crypto-5.8.3/priv/lib/crypto.so"), ["libcrypto.so.1.1"])

      tarball = Path.join(tmp_dir!("tarout"), "arbiter-v0.0.0-linux.tar.gz")
      {_, 0} = System.cmd("tar", ["-czf", tarball, "-C", dir, "."])

      {out, 1} = run([tarball])
      assert out =~ ~r/^ERROR: lib\/crypto-5\.8\.3\/priv\/lib\/crypto\.so needs libcrypto\.so\.1\.1/m
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

    test "runs the shared-library guard against the packaged tarball", %{yaml: yaml} do
      assert yaml =~ ~r/scripts\/check-release-shared-libs\.sh .*\$\{TARBALL\}/,
             "release.yml must run the shared-library guard on the tarball before publishing"
    end

    test "bundles an OTP built with static OpenSSL, not the rabbitmq RPM", %{yaml: yaml} do
      assert yaml =~ "scripts/build-release-otp.sh",
             "release.yml must build its OTP with scripts/build-release-otp.sh"

      refute yaml =~ "erlang-rpm",
             "the rabbitmq erlang RPM links crypto against the image's libcrypto.so.1.1"
    end
  end

  describe "OTP build script" do
    @build_script Path.expand("../../../../scripts/build-release-otp.sh", __DIR__)

    test "links OpenSSL statically into the crypto NIF" do
      body = File.read!(@build_script)
      assert body =~ "--disable-dynamic-ssl-lib"
      assert body =~ "no-shared"
    end

    test "--print-versions prints the cache key without building anything" do
      {out, 0} = System.cmd("bash", [@build_script, "--print-versions"])
      assert out =~ ~r/^OTP_VERSION=\S+ OPENSSL_VERSION=3\.\S+$/m
    end
  end

  describe "local release build wiring" do
    @local_script Path.expand("../../../../scripts/build-local-release.sh", __DIR__)

    test "the local release build runs the same guard" do
      body = File.read!(@local_script)

      assert body =~ "check-release-shared-libs.sh",
             "scripts/build-local-release.sh must run the shared-library guard too"

      assert body =~ ~r/SHLIB_GUARD"? --host/,
             "the local build ships the host's own OTP, so it checks in --host mode"
    end
  end
end
