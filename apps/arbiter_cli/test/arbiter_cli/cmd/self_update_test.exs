defmodule ArbiterCli.Cmd.SelfUpdateTest do
  # async: false — mutates global env (ARB_INSTALL_BIN, ARB_RELEASE_REPO, GITHUB_TOKEN).
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.SelfUpdate

  @repo "acme/arbiter"
  @vsn "v0.2.0"

  setup do
    tmp = Path.join(System.tmp_dir!(), "arb-self-update-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    install_path = Path.join(tmp, "arb")

    System.put_env("ARB_INSTALL_BIN", install_path)
    System.put_env("ARB_RELEASE_REPO", @repo)
    System.delete_env("GITHUB_TOKEN")
    System.delete_env("ARB_GITHUB_API")

    on_exit(fn ->
      System.delete_env("ARB_INSTALL_BIN")
      System.delete_env("ARB_RELEASE_REPO")
      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp, install_path: install_path}
  end

  # ---- fixtures -----------------------------------------------------------

  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp release_json(tag) do
    %{
      "tag_name" => tag,
      "assets" => [
        %{"name" => "arb", "browser_download_url" => "https://dl.test/dl/#{tag}/arb"},
        %{
          "name" => "arb.sha256",
          "browser_download_url" => "https://dl.test/dl/#{tag}/arb.sha256"
        }
      ]
    }
  end

  defp stub_release(tag, arb_bytes, sha_text, opts \\ []) do
    latest? = Keyword.get(opts, :latest, true)

    api_path =
      if latest?,
        do: "/repos/#{@repo}/releases/latest",
        else: "/repos/#{@repo}/releases/tags/#{tag}"

    stub_routes([
      {{"get", api_path}, {release_json(tag), 200}},
      {{"get", "/dl/#{tag}/arb"},
       fn conn ->
         conn
         |> Plug.Conn.put_resp_content_type("application/octet-stream")
         |> Plug.Conn.send_resp(200, arb_bytes)
       end},
      {{"get", "/dl/#{tag}/arb.sha256"},
       fn conn ->
         conn
         |> Plug.Conn.put_resp_content_type("text/plain")
         |> Plug.Conn.send_resp(200, sha_text)
       end}
    ])
  end

  # ---- happy path ---------------------------------------------------------

  describe "self-update (happy path)" do
    test "downloads, verifies checksum, installs the escript", %{install_path: install_path} do
      arb_bytes = "#!/usr/bin/env escript\n% fake arb #{@vsn}\n"
      sha = "#{sha256_hex(arb_bytes)}  arb\n"
      stub_release(@vsn, arb_bytes, sha)

      # Install a fake old binary first so we can confirm backup.
      File.write!(install_path, "old arb binary")

      {out, _err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 0
      assert out =~ "Updated arb to #{@vsn}"
      assert out =~ install_path

      # The new binary was installed.
      assert File.read!(install_path) == arb_bytes

      # The old binary was backed up.
      assert File.read!(install_path <> ".bak") == "old arb binary"

      # The new binary is executable.
      %File.Stat{mode: mode} = File.stat!(install_path)
      assert Bitwise.band(mode, 0o111) != 0
    end

    test "--json emits a single object describing the update", %{install_path: install_path} do
      arb_bytes = "#!/usr/bin/env escript\n% fake arb #{@vsn}\n"
      sha = "#{sha256_hex(arb_bytes)}  arb\n"
      stub_release(@vsn, arb_bytes, sha)
      File.write!(install_path, "old")

      {out, _err, code} = capture(fn -> SelfUpdate.run(["--json"]) end)

      assert code == 0
      assert {:ok, payload} = Jason.decode(String.trim(out))
      assert payload["version"] == @vsn
      assert payload["updated"] == true
      assert payload["already_current"] == false
      assert payload["ok"] == true
    end

    test "--version targets a specific tag via the tags endpoint", %{install_path: install_path} do
      tag = "v0.1.5"
      arb_bytes = "#!/usr/bin/env escript\n% fake arb #{tag}\n"
      sha = "#{sha256_hex(arb_bytes)}  arb\n"
      stub_release(tag, arb_bytes, sha, latest: false)
      File.write!(install_path, "old")

      {out, _err, code} = capture(fn -> SelfUpdate.run(["--version", tag]) end)

      assert code == 0
      assert out =~ "Updated arb to #{tag}"
    end

    test "creates the install directory if absent" do
      new_dir = Path.join(System.tmp_dir!(), "arb-newdir-#{System.unique_integer([:positive])}")
      new_path = Path.join(new_dir, "arb")
      System.put_env("ARB_INSTALL_BIN", new_path)

      on_exit(fn ->
        System.delete_env("ARB_INSTALL_BIN")
        File.rm_rf(new_dir)
      end)

      arb_bytes = "fake arb"
      sha = "#{sha256_hex(arb_bytes)}  arb\n"
      stub_release(@vsn, arb_bytes, sha)

      {_out, _err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 0
      assert File.exists?(new_path)
    end
  end

  # ---- already-current no-op ----------------------------------------------

  describe "already-current no-op" do
    test "skips download when already on the target version" do
      # The running CLI's version is ArbiterCli.Version.app_version().
      # We need to make the release tag match that version.
      current = ArbiterCli.Version.app_version()
      tag = "v#{current}"

      arb_bytes = "fake arb"
      sha = "#{sha256_hex(arb_bytes)}  arb\n"
      stub_release(tag, arb_bytes, sha)

      {out, _err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 0
      assert out =~ "Already on #{tag}"
    end

    test "--force reinstalls even when already on the target version", %{
      install_path: install_path
    } do
      current = ArbiterCli.Version.app_version()
      tag = "v#{current}"
      arb_bytes = "new arb bytes"
      sha = "#{sha256_hex(arb_bytes)}  arb\n"
      stub_release(tag, arb_bytes, sha)
      File.write!(install_path, "old bytes")

      {out, _err, code} = capture(fn -> SelfUpdate.run(["--force"]) end)

      assert code == 0
      assert out =~ "Updated arb to #{tag}"
      assert File.read!(install_path) == arb_bytes
    end
  end

  # ---- checksum verification ----------------------------------------------

  describe "checksum verification" do
    test "aborts on sha256 mismatch before writing anything", %{install_path: install_path} do
      arb_bytes = "fake arb"
      bad_sha = "#{String.duplicate("0", 64)}  arb\n"
      stub_release(@vsn, arb_bytes, bad_sha)
      File.write!(install_path, "original")

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "checksum mismatch"

      # Original binary is untouched.
      assert File.read!(install_path) == "original"
    end
  end

  # ---- configuration errors -----------------------------------------------

  describe "configuration errors" do
    test "missing ARB_RELEASE_REPO aborts with a hint" do
      System.delete_env("ARB_RELEASE_REPO")

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "ARB_RELEASE_REPO"
    end

    test "no matching release (404) aborts" do
      stub_routes([
        {{"get", "/repos/#{@repo}/releases/latest"}, {%{"message" => "Not Found"}, 404}}
      ])

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "no latest release found"
    end

    test "release with no `arb` asset aborts" do
      no_arb_release = %{
        "tag_name" => @vsn,
        "assets" => [
          %{"name" => "arbiter-#{@vsn}-linux.tar.gz", "browser_download_url" => "https://x/x.tgz"}
        ]
      }

      stub_routes([
        {{"get", "/repos/#{@repo}/releases/latest"}, {no_arb_release, 200}}
      ])

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "no asset named `arb`"
    end

    test "release with no `arb.sha256` asset aborts" do
      no_sha_release = %{
        "tag_name" => @vsn,
        "assets" => [
          %{"name" => "arb", "browser_download_url" => "https://x/arb"}
        ]
      }

      stub_routes([
        {{"get", "/repos/#{@repo}/releases/latest"}, {no_sha_release, 200}}
      ])

      {_out, err, code} = capture(fn -> SelfUpdate.run([]) end)

      assert code == 1
      assert err =~ "arb.sha256"
    end
  end
end
