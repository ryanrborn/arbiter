defmodule Arbiter.Worker.ReleaseEnvSpawnTest do
  # async: false — every test here mutates the process-global OS environment to
  # simulate running inside a systemd OTP release (bd-2oelme).
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Agents.Preflight
  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.Worktree

  # The vars a running OTP release exports. A child `mix`/`elixir`/`erl` that
  # inherits them boots against the release's bundled ERTS and dies with
  # `cannot get bootfile` (bd-4hkzn3).
  @release_vars ~w(RELEASE_ROOT RELEASE_NAME RELEASE_NODE ROOTDIR BINDIR ERTS_LIB_DIR)

  setup do
    tmp = Path.join(System.tmp_dir!(), "arb_relenv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    release_root = Path.join(tmp, "release")
    File.mkdir_p!(Path.join(release_root, "erts-14.0/bin"))

    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, tmp: tmp, release_root: release_root}
  end

  # Set the release vars for the duration of one test, restoring whatever the
  # host had before (normally: nothing).
  defp with_release_env(release_root, fun) do
    previous = Map.new(@release_vars, &{&1, System.get_env(&1)})

    System.put_env(%{
      "RELEASE_ROOT" => release_root,
      "RELEASE_NAME" => "arbiter",
      "RELEASE_NODE" => "arbiter@127.0.0.1",
      "ROOTDIR" => release_root,
      "BINDIR" => Path.join(release_root, "erts-14.0/bin"),
      "ERTS_LIB_DIR" => Path.join(release_root, "lib")
    })

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  # Clear every release var for the duration of `fun`, restoring afterwards.
  defp without_release_env(fun) do
    previous = Map.new(@release_vars, &{&1, System.get_env(&1)})
    Enum.each(@release_vars, &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {_name, nil} -> :ok
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  # A stand-in executable that dumps its own environment to `dump_path` and
  # exits 0. Used to observe exactly what a spawned child inherits.
  defp env_dumper!(dir, name, dump_path) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\nenv > #{dump_path}\nexit 0\n")
    File.chmod!(path, 0o755)
    path
  end

  defp dumped_names(dump_path) do
    dump_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))
    |> MapSet.new()
  end

  describe "ReleaseEnv.cmd/3 (the shared helper)" do
    test "strips release vars from the child environment", %{
      tmp: tmp,
      release_root: release_root
    } do
      dump = Path.join(tmp, "helper.env")
      exe = env_dumper!(tmp, "dumper", dump)

      with_release_env(release_root, fn ->
        assert {_out, 0} = ReleaseEnv.cmd(exe, [])
      end)

      names = dumped_names(dump)

      for var <- @release_vars do
        refute MapSet.member?(names, var),
               "#{var} leaked into the child env spawned by ReleaseEnv.cmd/3"
      end
    end

    test "still passes caller-supplied env pairs through", %{tmp: tmp, release_root: release_root} do
      dump = Path.join(tmp, "helper_extra.env")
      exe = env_dumper!(tmp, "dumper_extra", dump)

      with_release_env(release_root, fn ->
        assert {_out, 0} = ReleaseEnv.cmd(exe, [], env: [{"ARB_TEST_MARKER", "kept"}])
      end)

      assert File.read!(dump) =~ "ARB_TEST_MARKER=kept"
    end

    test "is a no-op in dev mode: no release vars set, nothing unset", %{tmp: tmp} do
      dump = Path.join(tmp, "devmode.env")
      exe = env_dumper!(tmp, "dumper_dev", dump)

      # `mix` itself exports ROOTDIR/BINDIR, so the test VM is never a pristine
      # "no release vars" environment — clear them for the duration of this
      # test to model a plain dev server that was not started as a release.
      without_release_env(fn ->
        assert ReleaseEnv.clean_pairs() == []
        assert {_out, 0} = ReleaseEnv.cmd(exe, [], env: [{"ARB_TEST_MARKER", "dev"}])
      end)

      names = dumped_names(dump)
      assert MapSet.member?(names, "PATH"), "PATH must still be inherited in dev mode"
      assert File.read!(dump) =~ "ARB_TEST_MARKER=dev"
    end
  end

  describe "Arbiter.Agents.Preflight auth probe" do
    test "spawns the probe without release vars", %{tmp: tmp, release_root: release_root} do
      dump = Path.join(tmp, "preflight.env")
      exe = env_dumper!(tmp, "fake_claude", dump)

      with_release_env(release_root, fn ->
        Preflight.check(Arbiter.Agents.Claude, probe_command: [exe], probe_env: [])
      end)

      assert File.exists?(dump), "the preflight probe never ran"
      names = dumped_names(dump)

      for var <- @release_vars do
        refute MapSet.member?(names, var),
               "#{var} leaked into the preflight probe's env"
      end
    end
  end

  describe "Arbiter.Worker.Worktree deps seeding" do
    test "spawns `mix deps.get` without release vars", %{tmp: tmp, release_root: release_root} do
      worktree = Path.join(tmp, "worktree")
      File.mkdir_p!(worktree)
      File.write!(Path.join(worktree, "mix.exs"), "# fake project\n")

      bin = Path.join(tmp, "bin")
      File.mkdir_p!(bin)
      dump = Path.join(tmp, "deps_get.env")
      _fake_mix = env_dumper!(bin, "mix", dump)

      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", bin <> ":" <> original_path)

        with_release_env(release_root, fn ->
          assert :ok = Worktree.ensure_deps_fetched(worktree)
        end)
      after
        System.put_env("PATH", original_path)
      end

      assert File.exists?(dump), "`mix deps.get` never ran"
      names = dumped_names(dump)

      for var <- @release_vars do
        refute MapSet.member?(names, var),
               "#{var} leaked into the `mix deps.get` seeding spawn"
      end
    end
  end
end
