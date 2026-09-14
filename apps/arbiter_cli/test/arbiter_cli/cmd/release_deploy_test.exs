defmodule ArbiterCli.Cmd.ReleaseDeployTest do
  # async: false — these tests mutate global env (ARB_DATA_HOME, ARB_RELEASE_REPO,
  # ARB_HOST, GITHUB_TOKEN) and route through the shared process-dict seams.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.ReleaseDeploy

  @green %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}
  @empty %{"data" => []}
  @no_workers %{"data" => []}

  @repo "acme/arbiter"
  @vsn "v2026.7.0"

  setup do
    home = Path.join(System.tmp_dir!(), "arb-rel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    System.put_env("ARB_DATA_HOME", home)
    System.put_env("ARB_RELEASE_REPO", @repo)
    System.delete_env("ARB_HOST")
    System.delete_env("GITHUB_TOKEN")
    System.delete_env("ARB_WORKER_BEAD_ID")
    System.delete_env("ARB_GITHUB_API")

    on_exit(fn ->
      System.delete_env("ARB_DATA_HOME")
      System.delete_env("ARB_RELEASE_REPO")
      File.rm_rf(home)
    end)

    # Sleep + TCP-port-free seams so restart/wait loops run instantly in tests.
    Process.put(:bd2_sleep, fn _ms -> :ok end)
    Process.put(:bd2_port_check, fn _port -> true end)

    {:ok, home: home}
  end

  # ---- fixtures ----------------------------------------------------------

  # A real, compressed OTP-release-shaped tarball with the single top-level
  # `arbiter/` dir the release workflow produces. Returned as raw bytes.
  defp release_tarball(tag, migrations \\ []) do
    path =
      Path.join(System.tmp_dir!(), "rel-#{tag}-#{System.unique_integer([:positive])}.tar.gz")

    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])
    :ok = :erl_tar.add(tar, "#!/bin/sh\necho arbiter #{tag}\n", ~c"arbiter/bin/arbiter", [])
    :ok = :erl_tar.add(tar, "release marker", ~c"arbiter/releases/RELEASE", [])

    # Migrations land where a mix release actually packages them:
    # lib/<app>-<vsn>/priv/repo/migrations/*.exs.
    Enum.each(migrations, fn name ->
      path_in_tar =
        "arbiter/lib/arbiter-#{String.trim_leading(tag, "v")}/priv/repo/migrations/#{name}.exs"

      :ok = :erl_tar.add(tar, "defmodule M do end", String.to_charlist(path_in_tar), [])
    end)

    :ok = :erl_tar.close(tar)

    bytes = File.read!(path)
    File.rm(path)
    bytes
  end

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp tarball_path(tag), do: "/dl/arbiter-#{tag}-linux.tar.gz"
  defp sha_path(tag), do: tarball_path(tag) <> ".sha256"

  # The GitHub release JSON for `tag`, with assets pointing at our stub paths.
  defp release_json(tag) do
    name = "arbiter-#{tag}-linux.tar.gz"

    %{
      "tag_name" => tag,
      "assets" => [
        %{"name" => name, "browser_download_url" => "https://dl.test#{tarball_path(tag)}"},
        %{
          "name" => name <> ".sha256",
          "browser_download_url" => "https://dl.test#{sha_path(tag)}"
        }
      ]
    }
  end

  defp raw_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/octet-stream")
    |> Plug.Conn.send_resp(status, body)
  end

  # Wire the GitHub API + asset downloads + local API for a full deploy.
  # `workspaces` controls doctor greenness (use @empty to force a red stack).
  defp stub_release(tag, tarball, sha_text, opts \\ []) do
    workspaces = Keyword.get(opts, :workspaces, @green)
    latest? = Keyword.get(opts, :latest, true)
    version_resp = Keyword.get(opts, :version_resp)

    api_path =
      if latest?,
        do: "/repos/#{@repo}/releases/latest",
        else: "/repos/#{@repo}/releases/tags/#{tag}"

    version_route =
      if version_resp, do: [{{"get", "/api/version"}, {version_resp, 200}}], else: []

    stub_routes(
      [
        {{"get", api_path}, {release_json(tag), 200}},
        {{"get", tarball_path(tag)}, fn conn -> raw_response(conn, 200, tarball) end},
        {{"get", sha_path(tag)}, fn conn -> raw_response(conn, 200, sha_text) end},
        {{"get", "/api/workspaces"}, {workspaces, 200}},
        {{"get", "/api/repos"},
         {%{"data" => [%{"name" => "tonic", "source" => "leotech", "path" => "/srv/tonic"}]}, 200}},
        {{"get", "/api/workers"}, {@no_workers, 200}}
      ] ++ version_route
    )
  end

  # Cmd runner covering the reused restart lifecycle. `systemd: false` makes
  # `Restart.perform/2` take its SIGTERM-then-start fallback so the stop/start
  # ordering is directly observable.
  defp stub_cmds(opts \\ []) do
    test_pid = self()
    systemd? = Keyword.get(opts, :systemd, true)

    Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})

      case {cmd, args} do
        # systemd unit present → restart delegates to systemctl.
        {"systemctl", ["--user", "cat", "arbiter.service"]} ->
          if systemd?, do: {"", 0}, else: {"Unit arbiter.service could not be found.", 1}

        {"systemctl", ["--user", "restart", "arbiter.service"]} ->
          {"", 0}

        # Non-systemd path: one listener to SIGTERM before the fresh start.
        {"lsof", _} ->
          {"4242\n", 0}

        _ ->
          {"", 0}
      end
    end)
  end

  # Every `{cmd, args}` the deploy ran, in invocation order.
  defp drain_cmds(acc \\ []) do
    receive do
      {:cmd, cmd, args} -> drain_cmds([{cmd, args} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp seed_release(home, tag, migrations \\ []) do
    dir = Path.join([home, "releases", tag])
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join(dir, "bin/arbiter"), "old")

    if migrations != [] do
      migrations_dir =
        Path.join(dir, "lib/arbiter-#{String.trim_leading(tag, "v")}/priv/repo/migrations")

      File.mkdir_p!(migrations_dir)

      Enum.each(migrations, fn name ->
        File.write!(Path.join(migrations_dir, name <> ".exs"), "defmodule M do end")
      end)
    end

    dir
  end

  defp point_current(home, target_dir) do
    link = Path.join(home, "current")
    File.rm(link)
    File.ln_s!(target_dir, link)
    link
  end

  # ---- happy path --------------------------------------------------------

  describe "release deploy (happy path)" do
    test "downloads, verifies, unpacks, swaps symlink, restarts", %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0
      assert out =~ "Deployed release #{@vsn}"
      assert out =~ "Arbiter restarted"
      assert out =~ "[ ok ] phoenix reachable"

      # The release was unpacked with the leading `arbiter/` stripped.
      target = Path.join([home, "releases", @vsn])
      assert File.exists?(Path.join(target, "bin/arbiter"))

      # current symlink now resolves to the new release.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn

      # Migrations are the new release's boot-time job (Arbiter.Boot.Migrator),
      # never a pre-swap eval against the still-running old server.
      refute_received {:cmd, _bin, ["eval", "Arbiter.Release.migrate"]}
      assert_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
    end

    test "deploys cleanly (no rollback) when the only workspace isn't named \"default\"" do
      # Regression for bd-8ix2tw: Workspace.resolve/0 used to require a
      # workspace literally named "default", so an install whose sole
      # workspace was named anything else made the (then-fatal) "active
      # workspace resolves" doctor check permanently red — timing out the
      # green-wait and auto-rolling-back every deploy regardless of whether
      # the new release was healthy.
      only_workspace = %{
        "data" => [%{"id" => "ws-leo", "name" => "leotech", "prefix" => "vr"}]
      }

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: only_workspace)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0
      assert out =~ "Deployed release #{@vsn}"
      refute out =~ "Rolled back"
      assert out =~ "[ ok ] active workspace resolves"
    end

    test "--json emits a single object describing the deploy" do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["version"] == @vsn
      assert payload["deployed"] == true
      assert payload["rolled_back"] == false
      assert payload["ok"] == true
    end

    test "--version targets a specific tag via the tags endpoint" do
      tag = "v2026.6.5"
      tarball = release_tarball(tag)
      sha = "#{sha256_hex(tarball)}  arbiter-#{tag}-linux.tar.gz\n"
      stub_release(tag, tarball, sha, latest: false)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--version", tag]) end)

      assert code == 0
      assert out =~ "Deployed release #{tag}"
    end

    test "idempotent: already on the target release is a no-op", %{home: home} do
      target = seed_release(home, @vsn)
      point_current(home, target)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0
      assert out =~ "Already on release #{@vsn}"
      # Never touched migrate or restart.
      refute_received {:cmd, _bin, ["eval", "Arbiter.Release.migrate"]}
      refute_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
    end
  end

  # ---- checksum verification ---------------------------------------------

  describe "checksum verification" do
    test "aborts on sha256 mismatch before swapping the symlink", %{home: home} do
      tarball = release_tarball(@vsn)
      bad_sha = "#{String.duplicate("0", 64)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, bad_sha)
      stub_cmds()

      {_out, err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert err =~ "checksum mismatch"
      # Nothing was migrated, swapped, or restarted.
      refute File.exists?(Path.join(home, "current"))
      refute_received {:cmd, _bin, ["eval", "Arbiter.Release.migrate"]}
      refute_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
    end
  end

  # ---- auto-rollback -----------------------------------------------------

  describe "auto-rollback on failed health check" do
    test "re-points current to the prior release and restarts, exits 1", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag)
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      # Empty workspace list → doctor never goes green → health check times out.
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come back green"
      assert out =~ "Rolled back to #{prior_tag}"

      # current symlink restored to the prior release.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end

    test "no prior release: reports the stack is down, exits 1", %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "No prior release to roll back to"
      # The (failed) new release is still what current points at.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "rollback report flags a fatal check that was already red before the deploy started",
         %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag)
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      # Zero workspaces → "at least one workspace exists" (fatal) is already
      # red before this deploy touches anything, and stays red throughout —
      # the green-wait times out on that pre-existing condition, not on
      # anything caused by @vsn.
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "Rolled back to #{prior_tag}"
      assert out =~ "note:"
      assert out =~ "at least one workspace exists"
      assert out =~ "already failing before this deploy started"

      # The pre-flight warning itself routes through `log/1` → `Start.log_text/1`,
      # a no-op in tests (bd2_sleep is stubbed in setup/0) — assert its exact
      # content directly rather than relying on it reaching stdout/stderr.
      assert ReleaseDeploy.preflight_warning(["at least one workspace exists"], @vsn) =~
               "warning: 1 readiness-blocking health check(s) already failing before this " <>
                 "deploy started (at least one workspace exists). Run `arb doctor` to " <>
                 "investigate — if this deploy times out waiting for green, that " <>
                 "pre-existing condition, not release #{@vsn}, may be why."
    end

    test "restart reports success but /api/version still shows the prior release (failed swap): rolls back, exits 1",
         %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag)
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"

      # Doctor goes green (Phoenix reachable, workspaces exist) — Restart.perform
      # reports {:ok, ...} — but /api/version never moved off the prior release,
      # i.e. the symlink swap/restart silently didn't take.
      stale_version_resp = %{
        "version" => "0.0.2",
        "sha" => "unknown",
        "built_at" => "2023-01-01T00:00:00Z",
        "booted_at" => "2023-01-01T00:01:00Z"
      }

      stub_release(@vsn, tarball, sha, version_resp: stale_version_resp)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert out =~ "still reports 0.0.2"
      assert out =~ "Rolled back to #{prior_tag}"

      # current symlink restored to the prior release — the deploy must not be
      # reported as successful when the server never actually moved.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end
  end

  # ---- migration ordering (bd-bksulf) ------------------------------------

  describe "migration ordering" do
    @m_old "20260101000000_create_things"
    @m_new "20260202000000_add_flag_to_things"

    test "never evals Arbiter.Release.migrate — not even when the new release adds migrations",
         %{home: home} do
      prior = seed_release(home, "v0.0.2", [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_new])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0

      cmds = drain_cmds()
      # Acceptance 1: no migration runs while the previous server is serving.
      # The only lifecycle command is the stop-then-start systemd restart; the
      # new release migrates on its own boot, after the old one is gone.
      refute Enum.any?(cmds, fn {_cmd, args} ->
               match?(["eval", "Arbiter.Release.migrate"], args)
             end)

      assert {"systemctl", ["--user", "restart", "arbiter.service"]} in cmds
    end

    test "non-systemd path orders stop → start with no migrate in between", %{home: home} do
      prior = seed_release(home, "v0.0.2", [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_new])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds(systemd: false)

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0

      cmds = drain_cmds()

      refute Enum.any?(cmds, fn {_cmd, args} ->
               match?(["eval", "Arbiter.Release.migrate"], args)
             end)

      kill_at = Enum.find_index(cmds, fn {cmd, _args} -> cmd == "kill" end)

      start_at =
        Enum.find_index(cmds, fn {cmd, args} ->
          cmd == "sh" and match?(["-c", _], args) and hd(tl(args)) =~ "phx.server"
        end)

      assert is_integer(kill_at), "expected the old server to be SIGTERMed"
      assert is_integer(start_at), "expected a fresh server start"
      assert kill_at < start_at, "the old server must be stopped before the new one starts"
    end

    test "warns up-front that the deploy crosses migrations and rollback is off" do
      plan = %{prior_target: "/rel/v0.0.2", crossed: [@m_new], allow_crossed: false}

      notice = ReleaseDeploy.cross_migration_notice(plan, @vsn)

      assert notice =~ "release #{@vsn} adds 1 migration(s)"
      assert notice =~ @m_new
      assert notice =~ "They apply during the new release's boot."
      assert notice =~ "Automatic rollback is therefore disabled for this deploy."
    end

    test "warns up-front that a forced cross-migration rollback is armed" do
      plan = %{prior_target: "/rel/v0.0.2", crossed: [@m_new], allow_crossed: true}

      notice = ReleaseDeploy.cross_migration_notice(plan, @vsn)

      assert notice =~ "--allow-cross-migration-rollback was passed"
      assert notice =~ "onto the migrated schema"
      refute notice =~ "Automatic rollback is therefore disabled"
    end
  end

  # ---- cross-migration rollback (bd-bksulf) -------------------------------

  describe "cross-migration rollback guard" do
    @m_old "20260101000000_create_things"
    @m_a "20260202000000_add_flag_to_things"
    @m_b "20260303000000_drop_legacy"

    test "refuses to auto-roll back when the new release added migrations", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a, @m_b])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "did not come back green"
      assert out =~ "Refused to roll back"
      # The migrations are named, so the operator knows what is stranded.
      assert out =~ @m_a
      assert out =~ @m_b
      assert out =~ "--allow-cross-migration-rollback"
      refute out =~ "Rolled back to #{prior_tag}"

      # current stays on the new release — old code must not boot against the
      # migrated schema behind the operator's back.
      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "--allow-cross-migration-rollback rolls back anyway, loudly", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} =
        capture(fn ->
          ReleaseDeploy.run(["--timeout", "1", "--allow-cross-migration-rollback"])
        end)

      assert code == 1
      assert out =~ "Rolled back to #{prior_tag}"
      assert out =~ "this rollback crossed 1 migration(s)"
      assert out =~ "is now running against a newer schema"
      assert out =~ @m_a

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end

    test "identical migration sets: automatic rollback is unchanged", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old, @m_a])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1"]) end)

      assert code == 1
      assert out =~ "Rolled back to #{prior_tag}"
      refute out =~ "Refused to roll back"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == prior_tag
    end

    test "a failed swap (stale /api/version) also refuses a cross-migration rollback", %{
      home: home
    } do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"

      stale_version_resp = %{
        "version" => "0.0.2",
        "sha" => "unknown",
        "built_at" => "2023-01-01T00:00:00Z",
        "booted_at" => "2023-01-01T00:01:00Z"
      }

      stub_release(@vsn, tarball, sha, version_resp: stale_version_resp)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert out =~ "still reports 0.0.2"
      assert out =~ "Refused to roll back"
      assert out =~ @m_a
      refute out =~ "Rolled back to #{prior_tag}"

      assert {:ok, link_target} = File.read_link(Path.join(home, "current"))
      assert Path.basename(link_target) == @vsn
    end

    test "--json reports the refusal and names the crossed migrations", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old, @m_a])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1", "--json"]) end)

      assert code == 1
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["rolled_back"] == false
      assert payload["rollback_refused"] == true
      assert payload["crossed_migrations"] == [@m_a]
      assert payload["rolled_back_to"] == nil
    end

    test "--json on a same-schema rollback reports no refusal", %{home: home} do
      prior_tag = "v0.0.2"
      prior = seed_release(home, prior_tag, [@m_old])
      point_current(home, prior)

      tarball = release_tarball(@vsn, [@m_old])
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha, workspaces: @empty)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run(["--timeout", "1", "--json"]) end)

      assert code == 1
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["rolled_back"] == true
      assert payload["rollback_refused"] == false
      assert payload["crossed_migrations"] == []
      assert payload["rolled_back_to"] == prior_tag
    end
  end

  # ---- pruning -----------------------------------------------------------

  describe "pruning old releases" do
    test "retains current + 3 most-recent priors, deletes older", %{home: home} do
      # Six pre-existing releases with increasing mtimes; current points at the
      # newest of them.
      old_tags = ~w(v1 v2 v3 v4 v5 v6)

      Enum.each(Enum.with_index(old_tags), fn {tag, i} ->
        dir = seed_release(home, tag)
        # mtime increasing with index so :desc sort is v6 > v5 > … > v1.
        File.touch!(dir, {{2026, 1, 1 + i}, {0, 0, 0}})
      end)

      prior = Path.join([home, "releases", "v6"])
      point_current(home, prior)

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      {out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0
      assert out =~ "Pruned"

      remaining =
        Path.join(home, "releases")
        |> File.ls!()
        |> Enum.sort()

      # Kept: new (@vsn) + prior (v6) + 3 newest others (v5, v4, v3).
      # Pruned: v1, v2.
      assert @vsn in remaining
      assert "v6" in remaining
      assert "v5" in remaining
      assert "v4" in remaining
      assert "v3" in remaining
      refute "v2" in remaining
      refute "v1" in remaining
    end
  end

  # ---- config errors -----------------------------------------------------

  describe "configuration errors" do
    test "missing ARB_RELEASE_REPO aborts with a hint" do
      System.delete_env("ARB_RELEASE_REPO")

      {_out, err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert err =~ "ARB_RELEASE_REPO"
    end

    test "no matching release (404) aborts" do
      stub_routes([
        {{"get", "/repos/#{@repo}/releases/latest"}, {%{"message" => "Not Found"}, 404}},
        {{"get", "/api/workers"}, {@no_workers, 200}},
        {{"get", "/api/workspaces"}, {@green, 200}}
      ])

      stub_cmds()

      {_out, err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert err =~ "no latest release found"
    end
  end

  # ---- PATH refresh -------------------------------------------------------

  describe "PATH refresh in arbiter.env" do
    test "deploy writes the deploying shell's PATH into arbiter.env", %{home: home} do
      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      prior_path = System.get_env("PATH")
      System.put_env("PATH", "/deploy/shell/bin:/usr/bin")

      on_exit(fn ->
        if prior_path, do: System.put_env("PATH", prior_path), else: System.delete_env("PATH")
      end)

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0

      env_file = Path.join(home, "arbiter.env")
      assert File.exists?(env_file)
      contents = File.read!(env_file)
      assert contents =~ "PATH=/deploy/shell/bin:/usr/bin"
    end

    test "deploy overwrites a stale PATH in arbiter.env with the deploying shell's PATH", %{
      home: home
    } do
      # Pre-seed a corrupted arbiter.env (simulating test pollution or a
      # previous bad deploy).
      env_file = Path.join(home, "arbiter.env")
      File.write!(env_file, "GITHUB_TOKEN=tok\nPATH=/second/path:/usr/bin\n")

      tarball = release_tarball(@vsn)
      sha = "#{sha256_hex(tarball)}  arbiter-#{@vsn}-linux.tar.gz\n"
      stub_release(@vsn, tarball, sha)
      stub_cmds()

      prior_path = System.get_env("PATH")
      System.put_env("PATH", "/correct/bin:/usr/local/bin:/usr/bin")

      on_exit(fn ->
        if prior_path, do: System.put_env("PATH", prior_path), else: System.delete_env("PATH")
      end)

      {_out, _err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 0

      contents = File.read!(env_file)
      # The stale placeholder is gone; the correct PATH is in place.
      refute contents =~ "/second/path"
      assert contents =~ "PATH=/correct/bin:/usr/local/bin:/usr/bin"
      # Unrelated keys are preserved.
      assert contents =~ "GITHUB_TOKEN=tok"
    end
  end

  # ---- worker guard ------------------------------------------------------

  describe "active-work guard" do
    test "refuses deploy when workers are actively working (no --force)" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@green, 200}},
        {{"get", "/api/workers"},
         {%{"data" => [%{"task_id" => "bd-xyz", "status" => "running"}]}, 200}}
      ])

      stub_cmds()

      {_out, err, code} = capture(fn -> ReleaseDeploy.run([]) end)

      assert code == 1
      assert err =~ "worker"
      assert err =~ "bd-xyz"
    end
  end
end
