defmodule Arbiter.Agents.Claude.ConfigDirTest do
  # async: false — toggles Application/System env (isolation switch, config dir,
  # CLAUDE_CONFIG_DIR source) that other tests read.
  use ExUnit.Case, async: false

  alias Arbiter.Agents.Claude.ConfigDir

  setup do
    # A fake operator config dir (the "source") with the seed files, and a
    # separate target the isolated worker dir is built in. Both under tmp.
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "arbiter-configdir-test-#{uniq}")
    source = Path.join(base, "source")
    target = Path.join(base, "worker")
    File.mkdir_p!(source)

    File.write!(Path.join(source, ".credentials.json"), ~s({"token":"fake"}))
    File.write!(Path.join(source, "settings.json"), ~s({"permissions":{"defaultMode":"auto"}}))
    # The persona file we must NOT carry over.
    File.write!(Path.join(source, "CLAUDE.md"), "# Darth Persona\nAlways roleplay.\n")

    prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
    prev_dir = Application.get_env(:arbiter, :worker_config_dir)
    prev_src = System.get_env("CLAUDE_CONFIG_DIR")

    Application.put_env(:arbiter, :worker_isolate_config, true)
    Application.put_env(:arbiter, :worker_config_dir, target)
    System.put_env("CLAUDE_CONFIG_DIR", source)

    on_exit(fn ->
      restore_env(:worker_isolate_config, prev_isolate)
      restore_env(:worker_config_dir, prev_dir)

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

  # A bare Workspace struct carrying an encrypted worker_env — the exact column
  # `Workspace.worker_env_map/1` reads. No DB round-trip needed, and the value
  # is never serialised anywhere.
  defp workspace_with_worker_env(env) do
    enc =
      env
      |> :erlang.term_to_binary()
      |> Arbiter.Vault.encrypt!()
      |> Base.encode64()

    %Arbiter.Tasks.Workspace{
      id: "ws-#{System.unique_integer([:positive])}",
      name: "cfgdir",
      encrypted_worker_env: enc
    }
  end

  describe "ensure/0 when enabled" do
    test "creates the dir and writes a clean, persona-free CLAUDE.md", %{target: target} do
      assert {:ok, ^target} = ConfigDir.ensure()
      assert File.dir?(target)

      memory = File.read!(Path.join(target, "CLAUDE.md"))
      assert memory =~ "Arbiter Worker"
      # The operator's persona content must NOT be carried over.
      refute memory =~ "Darth"
      refute memory =~ "Always roleplay"
    end

    test "copies auth from the source, but never CLAUDE.md or settings.json", %{
      source: source,
      target: target
    } do
      assert {:ok, ^target} = ConfigDir.ensure()

      # .credentials.json is a real copy (never a symlink — a token refresh
      # would otherwise write through the link and corrupt the operator's file).
      cred_path = Path.join(target, ".credentials.json")
      assert {:error, :einval} = File.read_link(cred_path)
      assert File.read!(cred_path) == File.read!(Path.join(source, ".credentials.json"))

      # CLAUDE.md is ours (a real file), not a link to the operator's persona.
      assert {:error, :einval} = File.read_link(Path.join(target, "CLAUDE.md"))

      # settings.json is now *generated* (a real file), never symlinked from the
      # operator's ~/.claude — so the worker doesn't inherit the host posture
      # (bd-9u10op). The operator's source settings had an empty deny; ours
      # must carry a non-empty hardened deny list.
      settings_path = Path.join(target, "settings.json")
      assert {:error, :einval} = File.read_link(settings_path)

      settings = settings_path |> File.read!() |> Jason.decode!()
      deny = get_in(settings, ["permissions", "deny"])
      assert is_list(deny) and deny != []
      assert Enum.any?(deny, &(&1 =~ "rm -rf"))
      refute settings == %{"permissions" => %{"defaultMode" => "auto"}}
    end

    test "replaces a stale settings.json symlink instead of writing through it", %{
      source: source,
      target: target
    } do
      # Simulate an earlier build that symlinked settings.json at the operator's
      # real file. ensure/0 must NOT follow the link and clobber the source.
      File.mkdir_p!(target)
      src_settings = Path.join(source, "settings.json")
      original = File.read!(src_settings)
      File.ln_s!(src_settings, Path.join(target, "settings.json"))

      assert {:ok, ^target} = ConfigDir.ensure()

      # The operator's real file is untouched...
      assert File.read!(src_settings) == original
      # ...and the target is now a real generated file (link replaced).
      target_settings = Path.join(target, "settings.json")
      assert {:error, :einval} = File.read_link(target_settings)
      assert File.read!(target_settings) =~ "deny"
    end

    test "is idempotent — a second call leaves the same files in place", %{target: target} do
      assert {:ok, ^target} = ConfigDir.ensure()
      assert {:ok, ^target} = ConfigDir.ensure()

      assert {:error, :einval} = File.read_link(Path.join(target, ".credentials.json"))
      assert File.exists?(Path.join(target, ".credentials.json"))
      assert File.read!(Path.join(target, "CLAUDE.md")) =~ "Arbiter Worker"
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
      assert File.read!(Path.join(target, "CLAUDE.md")) =~ "Arbiter Worker"
    end
  end

  describe "ensure/0 + env/0 with CLAUDE_CODE_OAUTH_TOKEN set (bd-6umoh9)" do
    setup do
      prev_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        case prev_token do
          nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
          v -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", v)
        end
      end)

      :ok
    end

    test "does not seed .credentials.json when a worker OAuth token is configured", %{
      target: target
    } do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token")

      assert {:ok, ^target} = ConfigDir.ensure()

      # No operator credential should exist for the worker to refresh.
      refute File.exists?(Path.join(target, ".credentials.json"))
      # Everything else still seeds/generates normally.
      assert File.read!(Path.join(target, "CLAUDE.md")) =~ "Arbiter Worker"
      assert File.exists?(Path.join(target, "settings.json"))
    end

    test "removes a stale seeded .credentials.json once a worker OAuth token appears", %{
      target: target
    } do
      # Simulate a pre-existing install that seeded before the token was adopted.
      assert {:ok, ^target} = ConfigDir.ensure()
      assert File.exists?(Path.join(target, ".credentials.json"))

      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token")
      assert {:ok, ^target} = ConfigDir.ensure()

      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "env/0 includes CLAUDE_CODE_OAUTH_TOKEN alongside CLAUDE_CONFIG_DIR", %{
      target: target
    } do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token")

      assert ConfigDir.env() == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "oauth-session-token"}
             ]
    end

    test "seeding still happens when the OS env var is unset (no regression)", %{
      source: source,
      target: target
    } do
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      assert {:ok, ^target} = ConfigDir.ensure()

      assert File.read!(Path.join(target, ".credentials.json")) ==
               File.read!(Path.join(source, ".credentials.json"))
    end
  end

  # bd-bw3466: this install configures the worker token the supported
  # per-workspace way (`worker_env`, encrypted at rest), not as a server env
  # var — so the bd-6umoh9 gate above never fired and the operator's
  # credentials were seeded (and rotated) exactly as before.
  describe "workspace-scoped worker OAuth token (bd-bw3466)" do
    setup do
      prev_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        case prev_token do
          nil -> System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
          v -> System.put_env("CLAUDE_CODE_OAUTH_TOKEN", v)
        end
      end)

      :ok
    end

    test "oauth_token_configured?/1 sees a token defined only in worker_env" do
      ws = workspace_with_worker_env(%{"CLAUDE_CODE_OAUTH_TOKEN" => "ws-token"})

      # The zero-arity form (server process env) is blind to it — the defect.
      refute ConfigDir.oauth_token_configured?()
      assert ConfigDir.oauth_token_configured?(ws)
    end

    test "ensure/1 does not seed .credentials.json when the workspace defines the token",
         %{target: target} do
      ws = workspace_with_worker_env(%{"CLAUDE_CODE_OAUTH_TOKEN" => "ws-token"})

      assert {:ok, ^target} = ConfigDir.ensure(ws)

      refute File.exists?(Path.join(target, ".credentials.json"))
      # Everything else still seeds/generates normally.
      assert File.read!(Path.join(target, "CLAUDE.md")) =~ "Arbiter Worker"
      assert File.exists?(Path.join(target, "settings.json"))
    end

    test "ensure/1 removes a stale copy seeded before the workspace token existed",
         %{target: target} do
      assert {:ok, ^target} = ConfigDir.ensure()
      assert File.exists?(Path.join(target, ".credentials.json"))

      ws = workspace_with_worker_env(%{"CLAUDE_CODE_OAUTH_TOKEN" => "ws-token"})
      assert {:ok, ^target} = ConfigDir.ensure(ws)

      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "env/1 injects the workspace's token alongside CLAUDE_CONFIG_DIR",
         %{target: target} do
      ws = workspace_with_worker_env(%{"CLAUDE_CODE_OAUTH_TOKEN" => "ws-token"})

      assert ConfigDir.env(ws) == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-token"}
             ]
    end

    test "the workspace token wins over a server env var of the same name",
         %{target: target} do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "server-token")
      ws = workspace_with_worker_env(%{"CLAUDE_CODE_OAUTH_TOKEN" => "ws-token"})

      assert ConfigDir.env(ws) == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-token"}
             ]
    end

    test "falls back to the server env var when the workspace defines no token",
         %{target: target} do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "server-token")
      ws = workspace_with_worker_env(%{"SOME_OTHER" => "x"})

      assert ConfigDir.env(ws) == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "server-token"}
             ]

      assert {:ok, ^target} = ConfigDir.ensure(ws)
      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    # The other direction: a gate that never seeds would pass the tests above
    # while silently breaking every install that has no worker token at all.
    test "still seeds when neither the workspace nor the server env defines a token",
         %{source: source, target: target} do
      ws = workspace_with_worker_env(%{"SOME_OTHER" => "x"})

      assert {:ok, ^target} = ConfigDir.ensure(ws)

      assert File.read!(Path.join(target, ".credentials.json")) ==
               File.read!(Path.join(source, ".credentials.json"))
    end

    test "an empty-string worker_env value is not treated as configured",
         %{source: source, target: target} do
      ws = workspace_with_worker_env(%{"CLAUDE_CODE_OAUTH_TOKEN" => ""})

      refute ConfigDir.oauth_token_configured?(ws)
      assert {:ok, ^target} = ConfigDir.ensure(ws)

      assert File.read!(Path.join(target, ".credentials.json")) ==
               File.read!(Path.join(source, ".credentials.json"))
    end

    test "a nil workspace behaves exactly like the zero-arity form",
         %{source: source, target: target} do
      assert ConfigDir.env(nil) == ConfigDir.env()
      assert {:ok, ^target} = ConfigDir.ensure(nil)

      assert File.read!(Path.join(target, ".credentials.json")) ==
               File.read!(Path.join(source, ".credentials.json"))
    end

    test "an undecryptable worker_env store degrades to the server env var",
         %{target: target} do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "server-token")

      ws = %Arbiter.Tasks.Workspace{
        id: "ws-corrupt",
        name: "cfgdir",
        encrypted_worker_env: "not-base64-ciphertext!!"
      }

      assert ConfigDir.env(ws) == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "server-token"}
             ]
    end
  end

  describe "ensure/0 when disabled" do
    test "returns :disabled and env/0 is empty", %{target: target} do
      Application.put_env(:arbiter, :worker_isolate_config, false)

      assert ConfigDir.ensure() == :disabled
      assert ConfigDir.env() == []
      refute File.exists?(target)
    end
  end

  describe "ensure/0 legacy dir migration (bd-5szsrw)" do
    # These exercise the *default* path (no :worker_config_dir override), since
    # migration only applies there — an operator override opts out.
    setup %{source: source} do
      uniq = System.unique_integer([:positive])
      cache_home = Path.join(System.tmp_dir!(), "arbiter-configdir-migrate-#{uniq}")
      legacy = Path.join([cache_home, "arbiter", "acolyte-claude"])
      fresh = Path.join([cache_home, "arbiter", "worker-claude"])

      prev_dir = Application.get_env(:arbiter, :worker_config_dir)
      prev_xdg = System.get_env("XDG_CACHE_HOME")

      Application.delete_env(:arbiter, :worker_config_dir)
      System.put_env("XDG_CACHE_HOME", cache_home)
      System.put_env("CLAUDE_CONFIG_DIR", source)

      on_exit(fn ->
        restore_env(:worker_config_dir, prev_dir)

        case prev_xdg do
          nil -> System.delete_env("XDG_CACHE_HOME")
          v -> System.put_env("XDG_CACHE_HOME", v)
        end

        File.rm_rf!(cache_home)
      end)

      {:ok, legacy: legacy, fresh: fresh}
    end

    test "renames an existing legacy acolyte-claude dir to worker-claude", %{
      legacy: legacy,
      fresh: fresh
    } do
      File.mkdir_p!(legacy)
      File.write!(Path.join(legacy, "CLAUDE.md"), "stale worker memory")
      File.mkdir_p!(Path.join(legacy, "projects"))
      File.write!(Path.join([legacy, "projects", "session.jsonl"]), "{}")

      assert {:ok, ^fresh} = ConfigDir.ensure()

      refute File.exists?(legacy)
      assert File.dir?(fresh)
      # Accumulated session history survives the rename...
      assert File.exists?(Path.join([fresh, "projects", "session.jsonl"]))
      # ...and ensure/0 still refreshes the memory file on top of it.
      assert File.read!(Path.join(fresh, "CLAUDE.md")) =~ "Arbiter Worker"
    end

    test "does nothing when there is no legacy dir", %{fresh: fresh} do
      assert {:ok, ^fresh} = ConfigDir.ensure()
      assert File.dir?(fresh)
    end

    test "does not touch the legacy dir once the fresh dir already exists", %{
      legacy: legacy,
      fresh: fresh
    } do
      File.mkdir_p!(legacy)
      File.write!(Path.join(legacy, "marker"), "legacy")
      File.mkdir_p!(fresh)

      assert {:ok, ^fresh} = ConfigDir.ensure()

      assert File.exists?(legacy)
      refute File.exists?(Path.join(fresh, "marker"))
    end
  end
end
