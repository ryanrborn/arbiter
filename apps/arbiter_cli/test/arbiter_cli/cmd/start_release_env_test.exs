defmodule ArbiterCli.Cmd.StartReleaseEnvTest do
  @moduledoc """
  bd-2oelme: `ArbiterCli.Cmd.Start.run_cmd/3` is the escript's single spawn
  point — `arb migrate`, `arb install-cli`, `arb update` and `arb start` all
  run `mix` (or `sh -c "… mix phx.server"`) through it. It must apply the same
  shared `Arbiter.Worker.ReleaseEnv` scrub the server does, or a `mix` child
  inheriting ROOTDIR/BINDIR/RELEASE_* dies with `cannot get bootfile`.
  """

  # async: false — these tests mutate the process-global OS environment.
  use ExUnit.Case, async: false

  alias ArbiterCli.Cmd.Start

  @release_vars ~w(RELEASE_ROOT RELEASE_NAME RELEASE_NODE ROOTDIR BINDIR ERTS_LIB_DIR)

  setup do
    tmp = Path.join(System.tmp_dir!(), "arb_cli_relenv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  # A stand-in executable that dumps its own environment and exits 0.
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

  defp with_env(pairs, fun) do
    names = Map.keys(pairs)
    previous = Map.new(names, &{&1, System.get_env(&1)})

    Enum.each(pairs, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  test "run_cmd/3 strips release vars from the child env", %{tmp: tmp} do
    release_root = Path.join(tmp, "release")
    File.mkdir_p!(Path.join(release_root, "erts-14.0/bin"))

    dump = Path.join(tmp, "cli.env")
    exe = env_dumper!(tmp, "fake_mix", dump)

    release_env = %{
      "RELEASE_ROOT" => release_root,
      "RELEASE_NAME" => "arbiter",
      "RELEASE_NODE" => "arbiter@127.0.0.1",
      "ROOTDIR" => release_root,
      "BINDIR" => Path.join(release_root, "erts-14.0/bin"),
      "ERTS_LIB_DIR" => Path.join(release_root, "lib")
    }

    with_env(release_env, fn ->
      assert {_out, 0} = Start.run_cmd(exe, ["compile"], stderr_to_stdout: true)
    end)

    assert File.exists?(dump), "the CLI spawn never ran"
    names = dumped_names(dump)

    for var <- @release_vars do
      refute MapSet.member?(names, var),
             "#{var} leaked into the env of a command spawned by arb"
    end
  end

  test "run_cmd/3 is a no-op when no release vars are set", %{tmp: tmp} do
    dump = Path.join(tmp, "cli_dev.env")
    exe = env_dumper!(tmp, "fake_mix_dev", dump)

    cleared = Map.new(@release_vars, &{&1, nil})

    with_env(cleared, fn ->
      assert {_out, 0} = Start.run_cmd(exe, [], env: [{"ARB_TEST_MARKER", "dev"}])
    end)

    names = dumped_names(dump)
    assert MapSet.member?(names, "PATH"), "PATH must still be inherited in dev mode"
    assert File.read!(dump) =~ "ARB_TEST_MARKER=dev"
  end

  test "run_cmd/3 still honours the :bd2_cmd_runner test seam" do
    Process.put(:bd2_cmd_runner, fn cmd, args, _opts -> {"stub:#{cmd}:#{inspect(args)}", 0} end)

    try do
      assert {"stub:mix:[\"compile\"]", 0} = Start.run_cmd("mix", ["compile"], [])
    after
      Process.delete(:bd2_cmd_runner)
    end
  end
end
