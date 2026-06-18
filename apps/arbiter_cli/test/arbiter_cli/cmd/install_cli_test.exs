defmodule ArbiterCli.Cmd.InstallCliTest do
  # async: false — tests mutate the global ARB_HOME env var.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.{InstallCli, Start}

  setup do
    prior_arb_home = System.get_env("ARB_HOME")

    on_exit(fn ->
      if prior_arb_home,
        do: System.put_env("ARB_HOME", prior_arb_home),
        else: System.delete_env("ARB_HOME")
    end)

    :ok
  end

  describe "stale baked-path guard" do
    test "stale ARB_HOME (dir exists, no apps/arbiter_cli) errors with path and remediation" do
      stale = Path.join(System.tmp_dir!(), "arb-stale-#{:os.getpid()}")
      File.mkdir_p!(stale)
      on_exit(fn -> File.rm_rf(stale) end)

      System.put_env("ARB_HOME", stale)

      {_out, err, code} = capture(fn -> InstallCli.run([]) end)

      assert code == 1
      assert err =~ "install-cli failed"
      assert err =~ "CLI source directory not found"
      assert err =~ stale
      assert err =~ "ARB_HOME"
    end

    test "ARB_HOME pointing to a valid checkout builds (stubbed)" do
      # Point ARB_HOME at a dir that looks like an Arbiter checkout.
      fake_root = Path.join(System.tmp_dir!(), "arb-fake-checkout-#{:os.getpid()}")
      cli_dir = Path.join(fake_root, "apps/arbiter_cli")
      File.mkdir_p!(cli_dir)
      on_exit(fn -> File.rm_rf(fake_root) end)

      System.put_env("ARB_HOME", fake_root)

      install_path = Path.join(System.user_home!(), ".local/bin/arb")
      # Write a fake escript so the copy step has a source file.
      escript_path = Path.join(cli_dir, "arb")

      Process.put(:bd2_cmd_runner, fn _cmd, _args, _opts ->
        File.write!(escript_path, "fake escript")
        {"", 0}
      end)

      {out, _err, code} = capture(fn -> InstallCli.run([]) end)

      assert code == 0
      assert out =~ install_path
    after
      File.rm(Path.join(System.user_home!(), ".local/bin/arb"))
    end
  end

  describe "is_umbrella_root?/1" do
    test "returns true for a dir with mix.exs and apps/" do
      dir = Path.join(System.tmp_dir!(), "arb-umbrella-#{:os.getpid()}")
      File.mkdir_p!(Path.join(dir, "apps"))
      File.write!(Path.join(dir, "mix.exs"), "")
      on_exit(fn -> File.rm_rf(dir) end)

      assert Start.is_umbrella_root?(dir)
    end

    test "returns true for a dir with compose.yml" do
      dir = Path.join(System.tmp_dir!(), "arb-compose-#{:os.getpid()}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "compose.yml"), "")
      on_exit(fn -> File.rm_rf(dir) end)

      assert Start.is_umbrella_root?(dir)
    end

    test "returns false for a plain directory (stale CI temp path)" do
      dir = Path.join(System.tmp_dir!(), "arb-plain-#{:os.getpid()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      refute Start.is_umbrella_root?(dir)
    end

    test "returns false for mix.exs without apps/ (non-umbrella project)" do
      dir = Path.join(System.tmp_dir!(), "arb-nonapps-#{:os.getpid()}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "")
      on_exit(fn -> File.rm_rf(dir) end)

      refute Start.is_umbrella_root?(dir)
    end
  end

  describe "project_root/0 stale recorded_home" do
    test "skips a recorded home that is a plain dir (no umbrella markers)" do
      # Simulate what CI leaves behind: a path that exists as a plain dir
      # but is not an Arbiter checkout.
      stale = Path.join(System.tmp_dir!(), "arb-recorded-stale-#{:os.getpid()}")
      File.mkdir_p!(stale)
      on_exit(fn -> File.rm_rf(stale) end)

      # Write it as the recorded home.
      Start.record_home(stale)
      prior_home_content = File.read(Start.recorded_home_path())

      on_exit(fn ->
        case prior_home_content do
          {:ok, content} -> File.write!(Start.recorded_home_path(), content)
          _ -> File.rm(Start.recorded_home_path())
        end
      end)

      # With ARB_HOME cleared, project_root should NOT return the stale path.
      System.delete_env("ARB_HOME")

      result = Start.project_root()

      case result do
        {:ok, dir} ->
          # If we got a result, it must not be the stale path
          refute dir == stale, "project_root returned stale recorded home #{stale}"

        :error ->
          # Acceptable: no valid root found
          :ok
      end
    end
  end
end
