defmodule Mix.Tasks.Arbiter.Accounts.CensusTest do
  @moduledoc """
  End-to-end coverage for `mix arbiter.accounts.census` against real, seeded,
  encrypted workspaces.

  `run/1` itself calls `Mix.Task.run("app.start")`, which cannot run under the
  test sandbox, so these drive `execute/1` — everything `run/1` does after the
  boot. That is the whole census: read, decrypt, group, print, write the plan.

  The bar this task is graded on is "never emits a value" (§7.4), so the
  no-leak test greps stdout, stderr, the plan file *and* captured Logger output
  for every >= 8-character substring of each seeded secret.
  """
  use Arbiter.DataCase, async: false

  import Bitwise
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Arbiter.Accounts.Census
  alias Arbiter.Tasks.Workspace
  alias Mix.Tasks.Arbiter.Accounts.Census, as: Task

  # Seeded plaintext. Deliberately long and unusual so a >= 8-char substring
  # match is meaningful rather than a coincidence.
  @token_a "sk-ant-oat01-qZ7fLx2NvUwJh4Tk9RmDbYcE6sApGnX1"
  @token_b "sk-ant-oat01-PdK3wQ8jVtHs5ZrNbFyMxL0aCuGeI7To"
  @openai_key "sk-proj-9mXvQ2rTzKpLbN4wYhJdCgA6eSuF8oRi"

  setup do
    dir = Path.join(System.tmp_dir!(), "census-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, plan_path: Path.join(dir, "accounts.json"), dir: dir}
  end

  defp seed!(name, env) do
    worker_env =
      Map.new(env, fn {key, value} -> {key, %{"value" => value, "secret" => true}} end)

    Ash.create!(Workspace, %{name: name, worker_env: worker_env})
  end

  # Runs `execute/1`, returning everything the operator (or a log shipper)
  # could possibly see: stdout, stderr and Logger.
  defp census(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        log =
          capture_log(fn -> send(parent, {:stdout, capture_io(fn -> Task.execute(argv) end)}) end)

        send(parent, {:log, log})
      end)

    stdout = assert_received_value(:stdout)
    log = assert_received_value(:log)
    %{stdout: stdout, stderr: stderr, log: log}
  end

  defp assert_received_value(tag) do
    receive do
      {^tag, value} -> value
    after
      0 -> flunk("census/1 captured no #{tag}")
    end
  end

  describe "acceptance 1 — it runs and reports" do
    test "prints per-workspace key names, fingerprints and candidate grouping", ctx do
      seed!("census-default", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a, "LOG_LEVEL" => "debug"})
      seed!("census-emricare", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})

      %{stdout: out} = census(["--plan", ctx.plan_path])

      assert out =~ "census-default"
      assert out =~ "census-emricare"
      assert out =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert out =~ "LOG_LEVEL"
      assert out =~ String.slice(Census.fingerprint(@token_a), 0, 12)
      assert out =~ "claude-1"
      assert out =~ ctx.plan_path
    end
  end

  describe "acceptance 2 — zero database writes" do
    test "no row count and no workspace row changes across the run", ctx do
      seed!("census-writes", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a, "FOO" => "bar"})

      before_counts = table_counts()
      before_rows = workspace_rows()

      census(["--plan", ctx.plan_path])

      assert table_counts() == before_counts
      # Catches an `updated_at` bump or a re-encryption of the blob, which a
      # count comparison alone would miss.
      assert workspace_rows() == before_rows
    end
  end

  describe "acceptance 3 — no secret value, and no >= 8-char substring of one, is emitted" do
    test "not in stdout, stderr, the plan file, or Logger", ctx do
      seed!("census-leak-a", %{
        "CLAUDE_CODE_OAUTH_TOKEN" => @token_a,
        "OPENAI_API_KEY" => @openai_key,
        "NOT_A_CREDENTIAL" => @token_b
      })

      seed!("census-leak-b", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})

      %{stdout: out, stderr: err, log: log} = census(["--plan", ctx.plan_path])
      plan = File.read!(ctx.plan_path)

      haystacks = [{"stdout", out}, {"stderr", err}, {"logger", log}, {"plan file", plan}]

      for secret <- [@token_a, @token_b, @openai_key],
          fragment <- substrings(secret, 8),
          {label, haystack} <- haystacks do
        refute String.contains?(haystack, fragment),
               "#{label} leaked a #{String.length(fragment)}-char fragment of a seeded secret"
      end
    end

    test "the plan file is created 0600", ctx do
      seed!("census-mode", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})
      census(["--plan", ctx.plan_path])

      assert {:ok, %File.Stat{mode: mode}} = File.stat(ctx.plan_path)
      assert (mode &&& 0o777) == 0o600
    end
  end

  describe "acceptance 4 — non-credential keys are named, never valued or promoted" do
    test "a credential-shaped but non-allowlisted key stays in unmoved_keys", ctx do
      seed!("census-other", %{
        "CLAUDE_CODE_OAUTH_TOKEN" => @token_a,
        "GITHUB_TOKEN" => @token_b,
        "LOG_LEVEL" => "debug"
      })

      %{stdout: out} = census(["--plan", ctx.plan_path])
      plan = Jason.decode!(File.read!(ctx.plan_path))

      assert [%{"workspace" => "census-other", "keys" => keys}] = plan["unmoved_keys"]
      assert keys == ["GITHUB_TOKEN", "LOG_LEVEL"]

      # GITHUB_TOKEN must not have become a credential anywhere in the plan.
      env_vars =
        for account <- plan["accounts"], credential <- account["credentials"] do
          credential["env_var"]
        end

      assert env_vars == ["CLAUDE_CODE_OAUTH_TOKEN"]
      assert out =~ "GITHUB_TOKEN"
      refute out =~ "debug"
    end
  end

  describe "acceptance 5 — grouping over real encrypted workspaces" do
    test "two workspaces sharing one token yield one candidate account", ctx do
      seed!("census-share-a", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})
      seed!("census-share-b", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})

      census(["--plan", ctx.plan_path])
      plan = Jason.decode!(File.read!(ctx.plan_path))

      assert [account] = plan["accounts"]
      assert account["slug"] == "claude-1"
      assert [credential] = account["credentials"]
      assert credential["fingerprint"] == Census.fingerprint(@token_a)

      assert Enum.sort(Enum.map(account["workspaces"], & &1["name"])) ==
               ["census-share-a", "census-share-b"]
    end

    test "two workspaces with different tokens yield two candidate accounts", ctx do
      seed!("census-split-a", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})
      seed!("census-split-b", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_b})

      census(["--plan", ctx.plan_path])
      plan = Jason.decode!(File.read!(ctx.plan_path))

      assert length(plan["accounts"]) == 2
      assert Enum.map(plan["accounts"], & &1["slug"]) == ["claude-1", "claude-2"]

      assert Enum.sort(
               Enum.flat_map(
                 plan["accounts"],
                 &Enum.map(&1["credentials"], fn c -> c["fingerprint"] end)
               )
             ) ==
               Enum.sort([Census.fingerprint(@token_a), Census.fingerprint(@token_b)])
    end
  end

  describe "the operator credential suggestion (§7.2)" do
    test "reads only a fingerprint out of the credentials file", ctx do
      seed!("census-operator", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})

      path = Path.join(ctx.dir, "credentials.json")
      File.write!(path, Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => @token_b}}))

      %{stdout: out} = census(["--plan", ctx.plan_path, "--operator-credential", path])
      plan_text = File.read!(ctx.plan_path)
      plan = Jason.decode!(plan_text)

      assert [account] = plan["accounts"]
      assert [_from_workspace, suggested] = account["credentials"]
      assert suggested["suggested"] == true
      assert suggested["fingerprint"] == Census.fingerprint(@token_b)
      assert suggested["source"]["type"] == "operator_credentials_file"
      assert out =~ "suggested"

      for fragment <- substrings(@token_b, 8) do
        refute String.contains?(plan_text, fragment)
        refute String.contains?(out, fragment)
      end
    end

    test "an unreadable credentials file degrades to a note, not a crash", ctx do
      seed!("census-operator-missing", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})
      missing = Path.join(ctx.dir, "nope.json")

      %{stdout: out} = census(["--plan", ctx.plan_path, "--operator-credential", missing])

      assert out =~ "could not read"
      assert File.exists?(ctx.plan_path)
    end
  end

  describe "plan file safety" do
    test "refuses to clobber an existing plan without --force", ctx do
      seed!("census-clobber", %{"CLAUDE_CODE_OAUTH_TOKEN" => @token_a})
      File.write!(ctx.plan_path, "hand-edited by the operator")

      assert_raise Mix.Error, ~r/--force/, fn ->
        capture_io(fn -> Task.execute(["--plan", ctx.plan_path]) end)
      end

      assert File.read!(ctx.plan_path) == "hand-edited by the operator"

      census(["--plan", ctx.plan_path, "--force"])
      assert Jason.decode!(File.read!(ctx.plan_path))["kind"] == "arbiter.accounts.plan"
    end
  end

  # Every contiguous substring of `secret` of length >= `min`.
  defp substrings(secret, min) do
    graphemes = String.graphemes(secret)
    len = length(graphemes)

    for start <- 0..(len - min),
        length <- min..(len - start) do
      graphemes |> Enum.slice(start, length) |> Enum.join()
    end
  end

  defp table_counts do
    %{rows: rows} =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
      )

    Map.new(rows, fn [table] ->
      %{rows: [[count]]} = Repo.query!(~s|SELECT COUNT(*) FROM "#{table}"|)
      {table, count}
    end)
  end

  defp workspace_rows do
    %{rows: rows} = Repo.query!("SELECT * FROM workspaces ORDER BY id")
    rows
  end
end
