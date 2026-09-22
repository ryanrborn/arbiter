defmodule Arbiter.Agents.Gemini.ConfigDirTest do
  # async: false — toggles Application env (the isolation switch and the home
  # root) that other tests read.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Agents.Gemini.ConfigDir
  alias Arbiter.Agents.SecurityPolicy

  setup do
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "arbiter-agy-home-test-#{uniq}")
    source = Path.join(base, "operator-home")
    root = Path.join(base, "worker-agy")

    # A fake operator HOME carrying exactly the things a worker must NOT see,
    # plus the passthrough entries it must keep.
    File.mkdir_p!(Path.join(source, ".gemini/config/skills/persona-skill"))
    File.mkdir_p!(Path.join(source, ".gemini/config/plugins/persona-plugin"))
    File.mkdir_p!(Path.join(source, ".gemini/antigravity-cli"))
    File.mkdir_p!(Path.join(source, ".agents/skills/persona-skill"))
    File.mkdir_p!(Path.join(source, ".antigravity"))
    File.mkdir_p!(Path.join(source, ".ssh"))
    File.mkdir_p!(Path.join(source, ".cache/mix"))
    File.write!(Path.join(source, ".gemini/GEMINI.md"), "# Darth Persona\nAlways roleplay.\n")

    File.write!(
      Path.join(source, ".gemini/antigravity-cli/settings.json"),
      ~s({"toolPermission":"always-proceed","allowNonWorkspaceAccess":true})
    )

    File.write!(Path.join(source, ".gitconfig"), "[user]\n  name = Operator\n")
    File.write!(Path.join(source, ".ssh/id_ed25519"), "PRIVATE")

    prev_enabled = Application.get_env(:arbiter, :worker_isolate_config)
    prev_root = Application.get_env(:arbiter, :worker_agy_home_root)
    prev_source = Application.get_env(:arbiter, :worker_agy_source_home)

    Application.put_env(:arbiter, :worker_isolate_config, true)
    Application.put_env(:arbiter, :worker_agy_home_root, root)
    Application.put_env(:arbiter, :worker_agy_source_home, source)

    on_exit(fn ->
      restore = fn key, val ->
        if is_nil(val),
          do: Application.delete_env(:arbiter, key),
          else: Application.put_env(:arbiter, key, val)
      end

      restore.(:worker_isolate_config, prev_enabled)
      restore.(:worker_agy_home_root, prev_root)
      restore.(:worker_agy_source_home, prev_source)
      File.rm_rf!(base)
    end)

    {:ok, base: base, source: source, root: root, worktree: Path.join(base, "wt")}
  end

  describe "path/1" do
    test "is keyed on the worktree so concurrent workers never share a HOME", %{
      root: root,
      worktree: wt
    } do
      a = ConfigDir.path(worktree: wt)
      b = ConfigDir.path(worktree: wt <> "-other")

      assert String.starts_with?(a, root)
      assert a != b
      # Stable across calls — the MCP writer and the spawn must agree.
      assert a == ConfigDir.path(worktree: wt)
    end

    test "falls back to a shared default when no worktree is in hand", %{root: root} do
      assert ConfigDir.path([]) == Path.join(root, "default")
    end
  end

  describe "ensure/1" do
    test "generates an Arbiter-owned agy settings.json, never the operator's", %{worktree: wt} do
      assert {:ok, home} = ConfigDir.ensure(worktree: wt, security: strict())

      settings =
        Jason.decode!(File.read!(Path.join(home, ".gemini/antigravity-cli/settings.json")))

      assert settings["toolPermission"] == "proceed-in-sandbox"
      assert settings["allowNonWorkspaceAccess"] == false
      assert settings["permissions"]["deny"] != []
    end

    test "writes an Arbiter worker GEMINI.md and never the operator's persona", %{
      worktree: wt,
      source: source
    } do
      assert {:ok, home} = ConfigDir.ensure(worktree: wt)

      memory = File.read!(Path.join(home, ".gemini/GEMINI.md"))
      refute memory =~ "Darth Persona"
      assert memory =~ "Arbiter worker"

      # And the operator's real file is untouched.
      assert File.read!(Path.join(source, ".gemini/GEMINI.md")) =~ "Darth Persona"
    end

    test "the operator's ~/.gemini skills and plugins are not reachable (AC2)", %{worktree: wt} do
      assert {:ok, home} = ConfigDir.ensure(worktree: wt)

      refute File.exists?(Path.join(home, ".gemini/config/skills/persona-skill"))
      refute File.exists?(Path.join(home, ".gemini/config/plugins/persona-plugin"))
      refute File.exists?(Path.join(home, ".agents/skills/persona-skill"))
      refute File.exists?(Path.join(home, ".antigravity"))
    end

    test "passes the rest of the operator's HOME through by symlink", %{
      worktree: wt,
      source: source
    } do
      assert {:ok, home} = ConfigDir.ensure(worktree: wt)

      assert File.read!(Path.join(home, ".gitconfig")) =~ "Operator"
      assert {:ok, %{type: :symlink}} = File.lstat(Path.join(home, ".ssh"))
      assert {:ok, target} = File.read_link(Path.join(home, ".ssh"))
      assert target == Path.join(source, ".ssh")
      assert File.exists?(Path.join(home, ".cache/mix"))
    end

    test "never links the HOME root's own ancestor back into the worker HOME", %{
      base: base,
      source: source,
      worktree: wt
    } do
      # Reproduce the production layout: the home root lives *under* the
      # operator's HOME (`~/.cache/arbiter/worker-agy`). A flat passthrough
      # would link `<home>/.cache -> <source>/.cache`, so
      # `<home>/.cache/arbiter/worker-agy/<key>` would resolve back to `<home>`:
      # an unbounded symlink cycle.
      File.mkdir_p!(Path.join(source, ".cache/arbiter/worker-claude"))

      Application.put_env(
        :arbiter,
        :worker_agy_home_root,
        Path.join(source, ".cache/arbiter/worker-agy")
      )

      on_exit(fn ->
        Application.put_env(:arbiter, :worker_agy_home_root, Path.join(base, "worker-agy"))
      end)

      assert {:ok, home} = ConfigDir.ensure(worktree: wt)

      # `.cache` is mirrored as a real directory, not a link back to the source.
      assert {:ok, %{type: :directory}} = File.lstat(Path.join(home, ".cache"))
      assert {:ok, %{type: :directory}} = File.lstat(Path.join(home, ".cache/arbiter"))
      # The root itself is never linked — that is the cycle.
      assert {:error, :enoent} = File.lstat(Path.join(home, ".cache/arbiter/worker-agy"))
      # ...but the rest of the operator's cache still passes through.
      assert {:ok, %{type: :symlink}} = File.lstat(Path.join(home, ".cache/mix"))

      assert {:ok, %{type: :symlink}} =
               File.lstat(Path.join(home, ".cache/arbiter/worker-claude"))

      # No path under the worker HOME resolves back to the worker HOME.
      refute File.exists?(Path.join(home, ".cache/arbiter/worker-agy/#{Path.basename(home)}"))
    end

    test "is idempotent — a second call does not fail or duplicate", %{worktree: wt} do
      assert {:ok, home} = ConfigDir.ensure(worktree: wt)
      assert {:ok, ^home} = ConfigDir.ensure(worktree: wt)
      assert File.exists?(Path.join(home, ".gemini/antigravity-cli/settings.json"))
    end

    test "re-generates settings.json on every spawn so a stale posture cannot linger", %{
      worktree: wt
    } do
      assert {:ok, home} = ConfigDir.ensure(worktree: wt, security: bypass())
      path = Path.join(home, ".gemini/antigravity-cli/settings.json")
      assert Jason.decode!(File.read!(path))["toolPermission"] == "always-proceed"

      assert {:ok, ^home} = ConfigDir.ensure(worktree: wt, security: strict())
      assert Jason.decode!(File.read!(path))["toolPermission"] == "proceed-in-sandbox"
    end

    test "returns :disabled when worker config isolation is switched off", %{worktree: wt} do
      Application.put_env(:arbiter, :worker_isolate_config, false)
      assert ConfigDir.ensure(worktree: wt) == :disabled
    end
  end

  describe "env/1" do
    test "injects HOME so agy reads our config dir and not the operator's", %{worktree: wt} do
      assert [{"HOME", home}] = ConfigDir.env(worktree: wt)
      assert home == ConfigDir.path(worktree: wt)
      assert File.dir?(home)
    end

    test "injects nothing when isolation is disabled (inherit the host HOME)", %{worktree: wt} do
      Application.put_env(:arbiter, :worker_isolate_config, false)
      assert ConfigDir.env(worktree: wt) == []
    end
  end

  describe "write_mcp_config/2" do
    test "lands at <home>/.gemini/config/mcp_config.json in agy's own schema", %{worktree: wt} do
      config = %{"mcpServers" => %{"arbiter" => %{"serverUrl" => "http://x/mcp"}}}

      assert {:ok, path} = ConfigDir.write_mcp_config(config, worktree: wt)
      assert path == Path.join(ConfigDir.path(worktree: wt), ".gemini/config/mcp_config.json")
      assert Jason.decode!(File.read!(path)) == config
    end

    test "refuses when isolation is off — there is no Arbiter-owned HOME to write into", %{
      worktree: wt
    } do
      Application.put_env(:arbiter, :worker_isolate_config, false)
      assert {:error, :disabled} = ConfigDir.write_mcp_config(%{}, worktree: wt)
    end
  end

  describe "credential seeding" do
    test "does not copy the operator's OAuth files when a keyring is available", %{
      worktree: wt,
      source: source
    } do
      File.write!(Path.join(source, ".gemini/oauth_creds.json"), "{}")
      assert {:ok, home} = ConfigDir.ensure(worktree: wt, keyring: true)
      refute File.exists?(Path.join(home, ".gemini/oauth_creds.json"))
    end

    test "copies (never symlinks) the OAuth files when no keyring is available", %{
      worktree: wt,
      source: source
    } do
      File.write!(Path.join(source, ".gemini/oauth_creds.json"), ~s({"token":"x"}))
      File.write!(Path.join(source, ".gemini/google_accounts.json"), "{}")

      assert {:ok, home} = ConfigDir.ensure(worktree: wt, keyring: false)

      copied = Path.join(home, ".gemini/oauth_creds.json")
      assert {:ok, %{type: :regular}} = File.lstat(copied)
      assert File.read!(copied) == ~s({"token":"x"})
      assert File.exists?(Path.join(home, ".gemini/google_accounts.json"))
    end
  end

  defp strict, do: SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :strict}})
  defp bypass, do: SecurityPolicy.merge(SecurityPolicy.base(), %{permissions: %{mode: :bypass}})
end
