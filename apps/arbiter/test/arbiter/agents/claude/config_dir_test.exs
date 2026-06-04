defmodule Arbiter.Agents.Claude.ConfigDirTest do
  # async: false — toggles Application/System env (isolation switch, config dir,
  # CLAUDE_CONFIG_DIR source) that other tests read.
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Claude.ConfigDir

  setup do
    # A fake operator config dir (the "source") with the seed files, and a
    # separate target the isolated acolyte dir is built in. Both under tmp.
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "arbiter-configdir-test-#{uniq}")
    source = Path.join(base, "source")
    target = Path.join(base, "acolyte")
    File.mkdir_p!(source)

    File.write!(Path.join(source, ".credentials.json"), ~s({"token":"fake"}))
    File.write!(Path.join(source, "settings.json"), ~s({"permissions":{"defaultMode":"auto"}}))
    # The persona file we must NOT carry over.
    File.write!(Path.join(source, "CLAUDE.md"), "# Darth Persona\nAlways roleplay.\n")

    prev_isolate = Application.get_env(:arbiter, :acolyte_isolate_config)
    prev_dir = Application.get_env(:arbiter, :acolyte_config_dir)
    prev_src = System.get_env("CLAUDE_CONFIG_DIR")

    Application.put_env(:arbiter, :acolyte_isolate_config, true)
    Application.put_env(:arbiter, :acolyte_config_dir, target)
    System.put_env("CLAUDE_CONFIG_DIR", source)

    on_exit(fn ->
      restore_env(:acolyte_isolate_config, prev_isolate)
      restore_env(:acolyte_config_dir, prev_dir)

      case prev_src do
        nil -> System.delete_env("CLAUDE_CONFIG_DIR")
        v -> System.put_env("CLAUDE_CONFIG_DIR", v)
      end

      File.rm_rf!(base)
    end)

    {:ok, source: source, target: target}
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_env(key, val), do: Application.put_env(:arbiter, key, val)

  describe "ensure/0 when enabled" do
    test "creates the dir and writes a clean, persona-free CLAUDE.md", %{target: target} do
      assert {:ok, ^target} = ConfigDir.ensure()
      assert File.dir?(target)

      memory = File.read!(Path.join(target, "CLAUDE.md"))
      assert memory =~ "Arbiter Acolyte"
      # The operator's persona content must NOT be carried over.
      refute memory =~ "Darth"
      refute memory =~ "Always roleplay"
    end

    test "symlinks auth + settings from the source, but never CLAUDE.md", %{
      source: source,
      target: target
    } do
      assert {:ok, ^target} = ConfigDir.ensure()

      assert {:ok, src_cred} = File.read_link(Path.join(target, ".credentials.json"))
      assert src_cred == Path.join(source, ".credentials.json")

      assert {:ok, src_settings} = File.read_link(Path.join(target, "settings.json"))
      assert src_settings == Path.join(source, "settings.json")

      # CLAUDE.md is ours (a real file), not a link to the operator's persona.
      assert {:error, :einval} = File.read_link(Path.join(target, "CLAUDE.md"))
    end

    test "is idempotent — a second call leaves the same links in place", %{target: target} do
      assert {:ok, ^target} = ConfigDir.ensure()
      assert {:ok, ^target} = ConfigDir.ensure()

      assert {:ok, _} = File.read_link(Path.join(target, ".credentials.json"))
      assert File.read!(Path.join(target, "CLAUDE.md")) =~ "Arbiter Acolyte"
    end

    test "env/0 returns the CLAUDE_CONFIG_DIR pair pointing at the isolated dir", %{
      target: target
    } do
      assert ConfigDir.env() == [{"CLAUDE_CONFIG_DIR", target}]
    end

    test "tolerates a source dir missing the seed files (auth falls back to env)", %{
      source: source,
      target: target
    } do
      File.rm!(Path.join(source, ".credentials.json"))
      File.rm!(Path.join(source, "settings.json"))

      assert {:ok, ^target} = ConfigDir.ensure()
      # No link created for an absent source file; the dir + memory still exist.
      assert {:error, _} = File.read_link(Path.join(target, ".credentials.json"))
      assert File.read!(Path.join(target, "CLAUDE.md")) =~ "Arbiter Acolyte"
    end
  end

  describe "ensure/0 when disabled" do
    test "returns :disabled and env/0 is empty", %{target: target} do
      Application.put_env(:arbiter, :acolyte_isolate_config, false)

      assert ConfigDir.ensure() == :disabled
      assert ConfigDir.env() == []
      refute File.exists?(target)
    end
  end
end
