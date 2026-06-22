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
    System.delete_env("ARB_ACOLYTE_BEAD_ID")
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
  defp release_tarball(tag) do
    path =
      Path.join(System.tmp_dir!(), "rel-#{tag}-#{System.unique_integer([:positive])}.tar.gz")

    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])
    :ok = :erl_tar.add(tar, "#!/bin/sh\necho arbiter #{tag}\n", ~c"arbiter/bin/arbiter", [])
    :ok = :erl_tar.add(tar, "release marker", ~c"arbiter/releases/RELEASE", [])
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

    api_path =
      if latest?,
        do: "/repos/#{@repo}/releases/latest",
        else: "/repos/#{@repo}/releases/tags/#{tag}"

    stub_routes([
      {{"get", api_path}, {release_json(tag), 200}},
      {{"get", tarball_path(tag)}, fn conn -> raw_response(conn, 200, tarball) end},
      {{"get", sha_path(tag)}, fn conn -> raw_response(conn, 200, sha_text) end},
      {{"get", "/api/workspaces"}, {workspaces, 200}},
      {{"get", "/api/workers"}, {@no_workers, 200}}
    ])
  end

  # Cmd runner covering the migrate eval + the reused restart lifecycle.
  defp stub_cmds do
    test_pid = self()

    Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})

      case {cmd, args} do
        {_bin, ["eval", "Arbiter.Release.migrate"]} ->
          {"", 0}

        # systemd unit present → restart delegates to systemctl.
        {"systemctl", ["--user", "cat", "arbiter.service"]} ->
          {"", 0}

        {"systemctl", ["--user", "restart", "arbiter.service"]} ->
          {"", 0}

        _ ->
          {"", 0}
      end
    end)
  end

  defp seed_release(home, tag) do
    dir = Path.join([home, "releases", tag])
    File.mkdir_p!(Path.join(dir, "bin"))
    File.write!(Path.join(dir, "bin/arbiter"), "old")
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
    test "downloads, verifies, unpacks, migrates, swaps symlink, restarts", %{home: home} do
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

      # Migrations ran from the unpacked release, then a systemd restart.
      assert_received {:cmd, _bin, ["eval", "Arbiter.Release.migrate"]}
      assert_received {:cmd, "systemctl", ["--user", "restart", "arbiter.service"]}
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
      prior_tag = "v2026.6.0"
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
