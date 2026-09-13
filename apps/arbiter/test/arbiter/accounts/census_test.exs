defmodule Arbiter.Accounts.CensusTest do
  @moduledoc """
  Unit coverage for the pure half of the P0 census (`docs/provider-account-design.md`
  §7.1–§7.3): allowlist partitioning, `(provider, sha256)` grouping, the plan
  document, and the human report.

  The DB-backed / no-writes / no-plaintext guarantees live in
  `Mix.Tasks.Arbiter.Accounts.CensusTest`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.Census

  # Distinctive, high-entropy fixtures: every no-leak assertion greps for these.
  @token_a "sk-ant-oat01-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @token_b "sk-ant-oat01-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

  defp ws(name, env), do: %{id: "ws_" <> name, name: name, env: env}

  defp jsonify(term), do: term |> Jason.encode!() |> Jason.decode!()

  describe "fingerprint/1" do
    test "is the hex sha256 of the secret, and never contains the secret" do
      fp = Census.fingerprint(@token_a)

      assert fp == Base.encode16(:crypto.hash(:sha256, @token_a), case: :lower)
      assert String.length(fp) == 64
      refute fp =~ "sk-ant-oat01"
    end

    test "equal secrets fingerprint equal; different secrets differ" do
      assert Census.fingerprint(@token_a) == Census.fingerprint(@token_a)
      refute Census.fingerprint(@token_a) == Census.fingerprint(@token_b)
    end
  end

  describe "credential allowlist (§7.3)" do
    test "covers the documented provider keys and maps them to Quota provider codes" do
      allow = Census.credential_keys()

      assert %{provider: "claude", kind: :oauth_token} = allow["CLAUDE_CODE_OAUTH_TOKEN"]
      assert %{provider: "claude", kind: :api_key} = allow["ANTHROPIC_API_KEY"]
      assert %{provider: "codex", kind: :api_key} = allow["OPENAI_API_KEY"]
      assert %{provider: "gemini", kind: :api_key} = allow["GEMINI_API_KEY"]

      # Every allowlisted provider is a code `Arbiter.Quota.provider_code/1` speaks.
      for {_key, %{provider: provider}} <- allow do
        assert Arbiter.Quota.provider_code(provider),
               "unknown provider code #{inspect(provider)} in the census allowlist"
      end
    end

    test "a credential-looking key that is not on the allowlist is never a credential" do
      census = Census.build([ws("default", %{"GITHUB_TOKEN" => @token_a, "MY_SECRET" => "x"})])

      assert census.accounts == []
      assert [%{credentials: [], other_keys: keys}] = census.workspaces
      assert keys == ["GITHUB_TOKEN", "MY_SECRET"]
    end
  end

  describe "grouping (§7.2)" do
    test "two workspaces sharing one token collapse into one candidate account" do
      census =
        Census.build([
          ws("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a}),
          ws("emricare", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})
        ])

      assert [account] = census.accounts
      assert account.slug == "claude-1"
      assert account.provider == "claude"
      assert [credential] = account.credentials
      assert credential.fingerprint == Census.fingerprint(@token_a)
      assert credential.env_var == "CLAUDE_CODE_OAUTH_TOKEN"
      assert Enum.map(account.workspaces, & &1.name) == ["default", "emricare"]
      assert census.totals.accounts == 1
      assert census.totals.distinct_fingerprints == 1
    end

    test "two workspaces with different tokens stay two candidate accounts" do
      census =
        Census.build([
          ws("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a}),
          ws("vstim", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_b})
        ])

      assert [a, b] = census.accounts
      assert [a.slug, b.slug] == ["claude-1", "claude-2"]
      assert Enum.map(a.workspaces, & &1.name) == ["default"]
      assert Enum.map(b.workspaces, & &1.name) == ["vstim"]
      assert census.totals.accounts == 2
    end

    test "candidates are numbered per provider" do
      census =
        Census.build([
          ws("a", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a, "OPENAI_API_KEY" => @token_b}),
          ws("b", %{"OPENAI_API_KEY" => "sk-proj-CCCCCCCCCCCCCCCCCCCC"})
        ])

      assert Enum.map(census.accounts, & &1.slug) == ["claude-1", "codex-1", "codex-2"]
    end

    test "grouping is by (provider, fingerprint), so the same secret under two providers splits" do
      census =
        Census.build([ws("a", %{"ANTHROPIC_API_KEY" => @token_a, "OPENAI_API_KEY" => @token_a})])

      assert Enum.map(census.accounts, & &1.slug) == ["claude-1", "codex-1"]
    end

    test "the same workspace's credentials and non-credentials are partitioned, not mixed" do
      census =
        Census.build([
          ws("default", %{
            "CLAUDE_CODE_OAUTH_TOKEN" => @token_a,
            "LOG_LEVEL" => "debug",
            "ARB_FEATURE" => "on"
          })
        ])

      assert [workspace] = census.workspaces
      assert Enum.map(workspace.credentials, & &1.env_key) == ["CLAUDE_CODE_OAUTH_TOKEN"]
      assert workspace.other_keys == ["ARB_FEATURE", "LOG_LEVEL"]
      assert workspace.credential_count == 1
      assert workspace.other_count == 2
    end

    test "a workspace with no worker_env at all is still reported" do
      census = Census.build([ws("empty", %{})])

      assert [%{name: "empty", credentials: [], other_keys: []}] = census.workspaces
      assert census.accounts == []
    end
  end

  describe "notes the operator has to act on" do
    test "flags a workspace holding two distinct credentials for one provider (§3.3)" do
      census =
        Census.build([
          ws("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a, "ANTHROPIC_API_KEY" => @token_b})
        ])

      assert Enum.map(census.accounts, & &1.slug) == ["claude-1", "claude-2"]
      note = Enum.find(census.notes, &(&1 =~ "CONFLICT"))
      assert note =~ "default"
      assert note =~ "claude-1"
      assert note =~ "claude-2"
    end

    test "does not flag a workspace holding one credential per provider" do
      census =
        Census.build([
          ws("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a, "OPENAI_API_KEY" => @token_b})
        ])

      refute Enum.any?(census.notes, &(&1 =~ "CONFLICT"))
    end

    test "flags a numbered pool variant of an allowlisted key without promoting it" do
      census = Census.build([ws("default", %{"ANTHROPIC_API_KEY_2" => @token_a})])

      assert census.accounts == []
      assert [%{other_keys: ["ANTHROPIC_API_KEY_2"]}] = census.workspaces
      assert Enum.any?(census.notes, &(&1 =~ "ANTHROPIC_API_KEY_2"))
    end

    test "an ordinary non-credential key raises no pool-variant note" do
      census = Census.build([ws("default", %{"RETRY_AFTER_5" => "x"})])

      refute Enum.any?(census.notes, &(&1 =~ "pool variants"))
    end
  end

  describe "plan/1 (§7.2 — the document `--plan` migrate will consume)" do
    test "is a versioned, JSON-encodable document carrying fingerprints and key names only" do
      plan =
        [
          ws("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a, "LOG_LEVEL" => "debug"}),
          ws("emricare", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})
        ]
        |> Census.build()
        |> Census.plan()

      json = Jason.encode!(plan)
      decoded = Jason.decode!(json)

      assert decoded["kind"] == "arbiter.accounts.plan"
      assert decoded["version"] == 1
      assert decoded["applied"] == false
      assert decoded["fingerprint"]["algorithm"] == "sha256"

      assert [account] = decoded["accounts"]
      assert account["slug"] == "claude-1"
      assert account["provider"] == "claude"
      # Shaped for the §3.1 account row the migrate step will insert.
      assert Map.has_key?(account, "label")
      assert account["max_concurrent"] == nil
      assert account["quota_config"] == %{}

      assert [credential] = account["credentials"]
      assert credential["fingerprint"] == Census.fingerprint(@token_a)
      assert credential["env_var"] == "CLAUDE_CODE_OAUTH_TOKEN"
      assert credential["kind"] == "oauth_token"
      assert credential["suggested"] == false
      assert credential["source"]["type"] == "workspace_worker_env"
      assert credential["source"]["workspaces"] == ["default", "emricare"]
      # The secret itself is deliberately absent — migrate re-reads it from the
      # workspace by `env_var` and checks the fingerprint.
      refute Map.has_key?(credential, "value")
      refute Map.has_key?(credential, "secret")

      assert [%{"name" => "default", "share" => nil}, %{"name" => "emricare"}] =
               account["workspaces"]

      assert [%{"workspace" => "default", "keys" => ["LOG_LEVEL"]}] = decoded["unmoved_keys"]
      refute json =~ "debug"
      refute json =~ "sk-ant-oat01"
    end
  end

  describe "operator credential suggestion (§7.2)" do
    test "attaches as a clearly-labelled suggested credential on the sole claude account" do
      census =
        Census.build(
          [ws("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})],
          operator_credential: %{
            fingerprint: Census.fingerprint(@token_b),
            path: "~/.claude/.credentials.json"
          }
        )

      assert [account] = census.accounts
      assert [_workspace_credential, suggested] = account.credentials
      assert suggested.suggested? == true
      assert suggested.fingerprint == Census.fingerprint(@token_b)
      assert suggested.source.type == :operator_credentials_file
      assert suggested.env_var == "CLAUDE_CODE_OAUTH_TOKEN"

      # It survives into the plan, still flagged, still fingerprint-only.
      assert [%{"credentials" => [_, encoded]}] = jsonify(Census.plan(census))["accounts"]
      assert encoded["suggested"] == true
      assert encoded["source"]["type"] == "operator_credentials_file"
      assert encoded["source"]["path"] == "~/.claude/.credentials.json"
      assert encoded["fingerprint"] == Census.fingerprint(@token_b)
      refute Map.has_key?(encoded, "value")
    end

    test "is omitted entirely when not supplied" do
      census = Census.build([ws("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})])

      assert [account] = census.accounts
      assert Enum.map(account.credentials, & &1.suggested?) == [false]
      assert Enum.any?(census.notes, &(&1 =~ "--operator-credential"))
    end

    test "is reported as already-covered when it fingerprints identically to a workspace token" do
      census =
        Census.build(
          [ws("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})],
          operator_credential: %{
            fingerprint: Census.fingerprint(@token_a),
            path: "~/.claude/.credentials.json"
          }
        )

      assert [account] = census.accounts
      assert Enum.map(account.credentials, & &1.suggested?) == [false]
      assert Enum.any?(census.notes, &(&1 =~ "already"))
    end

    test "with no claude candidate to attach to, it is listed unattached rather than dropped" do
      census =
        Census.build([ws("default", %{"OPENAI_API_KEY" => @token_b})],
          operator_credential: %{
            fingerprint: Census.fingerprint(@token_a),
            path: "~/.claude/.credentials.json"
          }
        )

      assert [suggestion] = census.suggestions
      assert suggestion.fingerprint == Census.fingerprint(@token_a)
      assert suggestion.provider == "claude"
    end
  end

  describe "report/1" do
    test "names workspaces, key names and truncated fingerprints, and never a value" do
      text =
        [
          ws("default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a, "LOG_LEVEL" => "debug"}),
          ws("emricare", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})
        ]
        |> Census.build()
        |> Census.report()

      assert text =~ "default"
      assert text =~ "emricare"
      assert text =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert text =~ "LOG_LEVEL"
      assert text =~ String.slice(Census.fingerprint(@token_a), 0, 12)
      assert text =~ "claude-1"
      assert text =~ "2 workspaces"
      assert text =~ "1 candidate account"

      refute text =~ "sk-ant-oat01"
      refute text =~ "debug"
    end

    test "states plainly that nothing was written" do
      text = Census.report(Census.build([]))
      assert text =~ "read-only"
    end
  end
end
