defmodule ArbiterCli.Cmd.AccountTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Account

  test "account list renders provider:slug and id" do
    stub_get("/api/accounts", %{
      "data" => [
        %{
          "id" => "acct-1",
          "provider" => "claude",
          "slug" => "personal-max",
          "max_concurrent" => nil,
          "enabled" => true,
          "merged_into_id" => nil
        }
      ]
    })

    {out, _err, exit_code} = capture(fn -> Account.run(["list"]) end)
    assert exit_code == 0
    assert out =~ "claude:personal-max  (acct-1)"
  end

  test "account list with no accounts" do
    stub_get("/api/accounts", %{"data" => []})
    {out, _err, exit_code} = capture(fn -> Account.run(["list"]) end)
    assert exit_code == 0
    assert out =~ "(no accounts)"
  end

  test "account list --include-merged forwards include_merged=true and renders the merged suffix" do
    stub_routes([
      {{"get", "/api/accounts"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         assert conn.query_params["include_merged"] == "true"

         conn
         |> Plug.Conn.put_status(200)
         |> Req.Test.json(%{
           "data" => [
             %{
               "id" => "acct-1",
               "provider" => "claude",
               "slug" => "merged-away",
               "max_concurrent" => nil,
               "enabled" => false,
               "merged_into_id" => "acct-2"
             }
           ]
         })
       end}
    ])

    {out, _err, exit_code} = capture(fn -> Account.run(["list", "--include-merged"]) end)
    assert exit_code == 0
    assert out =~ "[merged -> acct-2]"
  end

  test "account show prints credentials and workspaces, never a secret" do
    stub_get("/api/accounts/personal-max", %{
      "id" => "acct-1",
      "provider" => "claude",
      "slug" => "personal-max",
      "label" => "Personal Max",
      "plan" => "max_20x",
      "enabled" => true,
      "max_concurrent" => nil,
      "merged_into_id" => nil,
      "credentials" => [
        %{
          "kind" => "oauth_token",
          "env_var" => "CLAUDE_CODE_OAUTH_TOKEN",
          "fingerprint" => "abc123def456",
          "active" => true,
          "retired_at" => nil
        }
      ],
      "workspaces" => [%{"workspace_id" => "ws-1", "share" => 2}]
    })

    {out, _err, exit_code} = capture(fn -> Account.run(["show", "personal-max"]) end)
    assert exit_code == 0
    assert out =~ "Slug:        personal-max"
    assert out =~ "oauth_token"
    assert out =~ "fingerprint=abc123def456"
    assert out =~ "workspace ws-1 share=2"
    refute out =~ "secret"
  end

  test "account create posts provider+slug and reports" do
    stub_post("/api/accounts", %{"id" => "acct-2", "provider" => "codex", "slug" => "team-plan"})

    {out, _err, exit_code} = capture(fn -> Account.run(["create", "codex", "team-plan"]) end)
    assert exit_code == 0
    assert out =~ "created account codex:team-plan (acct-2)"
  end

  test "account attach posts workspace/provider/share" do
    stub_post("/api/accounts/personal-max/attach", %{
      "workspace_id" => "ws-1",
      "provider" => "claude",
      "provider_account_id" => "acct-1",
      "share" => 2
    })

    {out, _err, exit_code} =
      capture(fn -> Account.run(["attach", "ws-1", "claude", "personal-max", "--share", "2"]) end)

    assert exit_code == 0
    assert out =~ "attached workspace ws-1 -> account acct-1 share=2"
  end

  test "account rotate never prints the secret it just wrote" do
    stub_post("/api/accounts/personal-max/rotate", %{
      "id" => "cred-2",
      "kind" => "oauth_token",
      "fingerprint" => "fedcba987654",
      "active" => true
    })

    {out, _err, exit_code} =
      capture(fn ->
        Account.run([
          "rotate",
          "personal-max",
          "--kind",
          "oauth_token",
          "--env-var",
          "CLAUDE_CODE_OAUTH_TOKEN",
          "--secret",
          "sk-super-secret-value"
        ])
      end)

    assert exit_code == 0
    assert out =~ "rotated oauth_token credential (fingerprint=fedcba987654)"
    refute out =~ "sk-super-secret-value"
    refute out =~ "secret"
  end

  test "account rotate requires a secret source" do
    {_out, err, exit_code} =
      capture(fn ->
        Account.run(["rotate", "personal-max", "--kind", "oauth_token", "--env-var", "X"])
      end)

    assert exit_code != 0
    assert err =~ "requires a secret"
  end

  test "account rotate reads the secret from stdin when \"-\" is passed as an explicit rotate argument" do
    parent = self()

    stub_routes([
      {{"post", "/api/accounts/personal-max/rotate"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted_body, Jason.decode!(body)})

         conn
         |> Plug.Conn.put_status(201)
         |> Req.Test.json(%{
           "id" => "cred-3",
           "kind" => "oauth_token",
           "fingerprint" => "aaaabbbbcccc",
           "active" => true
         })
       end}
    ])

    out =
      capture_io("sk-from-stdin\n", fn ->
        capture_io(:stderr, fn ->
          Account.run([
            "rotate",
            "personal-max",
            "--kind",
            "oauth_token",
            "--env-var",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "-"
          ])
        end)
      end)

    assert out =~ "rotated oauth_token credential (fingerprint=aaaabbbbcccc)"
    refute out =~ "sk-from-stdin"

    assert_received {:posted_body, %{"secret" => "sk-from-stdin"}}
  end

  test "account merge posts into and reports the survivor" do
    stub_post("/api/accounts/merge-from/merge", %{
      "id" => "acct-into",
      "provider" => "claude",
      "slug" => "merge-into"
    })

    {out, _err, exit_code} =
      capture(fn -> Account.run(["merge", "merge-from", "--into", "merge-into"]) end)

    assert exit_code == 0
    assert out =~ "merged into account claude:merge-into (acct-into)"
  end

  test "account merge requires --into" do
    {_out, err, exit_code} = capture(fn -> Account.run(["merge", "merge-from"]) end)
    assert exit_code != 0
    assert err =~ "--into"
  end

  test "unknown subcommand dies with a helpful message" do
    {_out, err, exit_code} = capture(fn -> Account.run(["bogus"]) end)
    assert exit_code != 0
    assert err =~ "unknown account subcommand"
  end

  test "--help prints the moduledoc" do
    {out, _err, exit_code} = capture(fn -> Account.run(["--help"]) end)
    assert exit_code == 0
    assert out =~ "arb account"
    assert out =~ "merge"
  end
end
