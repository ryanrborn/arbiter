defmodule GtElixir.Workflows.CodeReviewTest do
  # async: false — github-mode tests share the Req.Test stub registry
  # (`GtElixir.GitHub.HTTP`) which lives in a process-global table.
  use ExUnit.Case, async: false

  alias GtElixir.Workflows.CodeReview
  alias GtElixir.Workflows.CodeReview.{Checks, LocalMode}

  @token "test-token-abc123"

  # ---- fixture git repo for read_diff tests -----------------------------

  defp setup_repo do
    unique = "gte021-#{:erlang.unique_integer([:positive])}"
    tmp = Path.join(System.tmp_dir!(), unique)
    File.mkdir_p!(tmp)

    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

    # Create a feature branch with an additional commit so `main..HEAD`
    # produces a non-empty diff.
    {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "feature/x"])
    File.write!(Path.join(repo, "added.txt"), "line one\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "added.txt"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "add file"])

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{repo: repo, tmp: tmp}
  end

  defp stub(fun), do: Req.Test.stub(GtElixir.GitHub.HTTP, fun)

  defp put_status(conn, status) do
    %{conn | status: status}
    |> Plug.Conn.put_resp_header("content-type", "application/json")
  end

  # =======================================================================
  # Workflow declaration
  # =======================================================================

  describe "workflow declaration" do
    test "steps/0 returns the five step atoms in declared order" do
      assert CodeReview.steps() == [:load_pr, :read_diff, :run_checks, :file_findings, :verdict]
    end

    test "vars/0 includes the core inputs" do
      vars = CodeReview.vars()
      for v <- [:repo, :pr_number, :worktree_path, :mode], do: assert(v in vars)
    end

    test "step_definition(:load_pr) has expected shape" do
      defn = CodeReview.step_definition(:load_pr)
      assert defn.needs == []
      assert :worktree_path in defn.vars
      assert :mode in defn.vars
      assert is_binary(defn.description)
    end

    test "step_definition(:verdict) depends on :file_findings" do
      assert CodeReview.step_definition(:verdict).needs == [:file_findings]
    end

    test "module does not call GitHub.pr_merge or Polecat.Worktree.push (forbidden actions)" do
      # Static guarantee: the compiled BEAM does not reference these symbols.
      # We inspect the BEAM's xref via Module.attribute lookups; simpler is
      # to inspect the source, ignoring the moduledoc block where the
      # forbidden function names are referenced as documentation.
      source =
        File.read!(Path.expand("../../../lib/gt_elixir/workflows/code_review.ex", __DIR__))

      # Strip the leading @moduledoc """ ... """ block before scanning so
      # the documented forbidden-actions list doesn't trigger a false match.
      stripped =
        Regex.replace(~r/@moduledoc\s+"""(.|\n)*?"""/m, source, "", global: false)

      refute stripped =~ "pr_merge"
      refute stripped =~ "Worktree.push"
      refute stripped =~ ~r/GitHub\.pr_merge/
    end
  end

  # =======================================================================
  # :load_pr
  # =======================================================================

  describe "run_step(:load_pr, ...)" do
    test "local mode records the current branch from the worktree" do
      %{repo: repo} = setup_repo()

      state = %{mode: :local, worktree_path: repo}
      assert {:ok, new_state} = CodeReview.run_step(:load_pr, state)
      assert new_state.branch == "feature/x"
      assert new_state.pr == nil
    end

    test "github mode calls GitHub.pr_get and records branch from head.ref" do
      stub(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/repos/octo/widget/pulls/42"

        conn
        |> put_status(200)
        |> Req.Test.json(%{"number" => 42, "head" => %{"ref" => "feature/y", "sha" => "abc"}})
      end)

      state = %{
        mode: :github,
        repo: "octo/widget",
        pr_number: 42,
        worktree_path: "/tmp/unused",
        github_opts: [token: @token]
      }

      assert {:ok, new_state} = CodeReview.run_step(:load_pr, state)
      assert new_state.branch == "feature/y"
      assert is_map(new_state.pr)
    end

    test "missing required keys returns {:error, {:bad_state, _}}" do
      assert {:error, {:bad_state, _}} = CodeReview.run_step(:load_pr, %{mode: :local})
    end
  end

  # =======================================================================
  # :read_diff
  # =======================================================================

  describe "run_step(:read_diff, ...)" do
    test "shells out to git diff against the configured base" do
      %{repo: repo} = setup_repo()

      state = %{mode: :local, worktree_path: repo, base: "main"}

      assert {:ok, %{diff: diff}} = CodeReview.run_step(:read_diff, state)
      assert is_binary(diff)
      assert diff =~ "added.txt"
      assert diff =~ "+line one"
    end

    test "missing worktree_path returns {:error, _}" do
      assert {:error, _} = CodeReview.run_step(:read_diff, %{mode: :local})
    end
  end

  # =======================================================================
  # :run_checks
  # =======================================================================

  describe "run_step(:run_checks, ...)" do
    test "default runner returns findings: []" do
      state = %{mode: :local, diff: "some diff"}
      assert {:ok, %{findings: []}} = CodeReview.run_step(:run_checks, state)
    end

    test "custom :check_runner is invoked with (diff, state)" do
      runner = fn diff, state ->
        send(self(), {:ran, diff, state[:mode]})
        {:ok, [%{severity: :warning, file: "a.ex", line: 1, message: "x"}]}
      end

      state = %{mode: :local, diff: "DIFF", check_runner: runner}
      assert {:ok, %{findings: [%{severity: :warning}]}} = CodeReview.run_step(:run_checks, state)
      assert_received {:ran, "DIFF", :local}
    end

    test "check_runner errors propagate" do
      runner = fn _diff, _state -> {:error, :boom} end
      state = %{mode: :local, diff: "", check_runner: runner}
      assert {:error, :boom} = CodeReview.run_step(:run_checks, state)
    end
  end

  # =======================================================================
  # :file_findings
  # =======================================================================

  describe "run_step(:file_findings, ...)" do
    test "local mode writes reviews/<branch>.md with structured contents" do
      %{repo: repo} = setup_repo()

      findings = [
        %{severity: :error, file: "lib/foo.ex", line: 10, message: "boom"},
        %{severity: :info, file: "lib/bar.ex", line: 3, message: "fyi"}
      ]

      state = %{
        mode: :local,
        worktree_path: repo,
        branch: "feature/x",
        bead: %{id: "gte-021", title: "code review"},
        findings: findings
      }

      assert {:ok, %{review_path: path}} = CodeReview.run_step(:file_findings, state)
      assert path == Path.join([repo, "reviews", "feature-x.md"])
      assert File.exists?(path)

      contents = File.read!(path)
      assert contents =~ "# Code review: feature/x"
      assert contents =~ "**Bead:** gte-021 — code review"
      assert contents =~ "**Mode:** local"
      assert contents =~ "(2 findings)"
      assert contents =~ "lib/foo.ex:10 — error"
      assert contents =~ "lib/bar.ex:3 — info"
      # Error findings sort before info.
      assert :binary.match(contents, "lib/foo.ex") < :binary.match(contents, "lib/bar.ex")
    end

    test "github mode posts one inline comment per finding plus a summary" do
      calls = :counters.new(2, [])

      stub(fn conn ->
        cond do
          conn.request_path == "/repos/octo/widget/pulls/7" and conn.method == "GET" ->
            conn
            |> put_status(200)
            |> Req.Test.json(%{"number" => 7, "head" => %{"sha" => "deadbeef"}})

          String.ends_with?(conn.request_path, "/pulls/7/comments") and conn.method == "POST" ->
            :counters.add(calls, 1, 1)
            conn |> put_status(201) |> Req.Test.json(%{"id" => 1})

          String.ends_with?(conn.request_path, "/issues/7/comments") and conn.method == "POST" ->
            :counters.add(calls, 2, 1)
            conn |> put_status(201) |> Req.Test.json(%{"id" => 2})

          true ->
            conn
            |> put_status(404)
            |> Req.Test.json(%{"message" => "unhandled #{conn.request_path}"})
        end
      end)

      findings = [
        %{severity: :error, file: "a.ex", line: 1, message: "bad"},
        %{severity: :warning, file: "b.ex", line: 2, message: "meh"}
      ]

      state = %{
        mode: :github,
        repo: "octo/widget",
        pr_number: 7,
        findings: findings,
        github_opts: [token: @token, commit_id: "deadbeef"]
      }

      assert {:ok, _} = CodeReview.run_step(:file_findings, state)
      assert :counters.get(calls, 1) == 2
      assert :counters.get(calls, 2) == 1
    end
  end

  # =======================================================================
  # :verdict
  # =======================================================================

  describe "run_step(:verdict, ...)" do
    test "no findings → :approve, and the review file is rewritten" do
      %{repo: repo} = setup_repo()

      # First write an initial review file via the helper.
      :ok = LocalMode.write_findings(repo, "feature/x", %{id: "gte-021", title: "t"}, [])
      path = LocalMode.review_path(repo, "feature/x")

      state = %{mode: :local, findings: [], review_path: path}
      assert {:ok, %{verdict: :approve}} = CodeReview.run_step(:verdict, state)

      contents = File.read!(path)
      assert contents =~ "**Verdict:** APPROVE"
      refute contents =~ "Verdict (pending)"
    end

    test "any :error finding → :request_changes" do
      %{repo: repo} = setup_repo()

      findings = [%{severity: :error, file: "x.ex", line: 1, message: "bad"}]
      :ok = LocalMode.write_findings(repo, "feature/x", nil, findings)
      path = LocalMode.review_path(repo, "feature/x")

      state = %{mode: :local, findings: findings, review_path: path}
      assert {:ok, %{verdict: :request_changes}} = CodeReview.run_step(:verdict, state)
      assert File.read!(path) =~ "**Verdict:** REQUEST_CHANGES"
    end

    test "warnings only → :approve (only :error escalates)" do
      assert CodeReview.compute_verdict([
               %{severity: :warning, file: "a", line: 1, message: "x"},
               %{severity: :info, file: "b", line: 1, message: "y"}
             ]) == :approve
    end

    test "github mode submits a review with the verdict event" do
      events = :ets.new(:events, [:public])

      stub(fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/pulls/7/reviews") and conn.method == "POST" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            decoded = Jason.decode!(body)
            :ets.insert(events, {:review, decoded})
            conn |> put_status(200) |> Req.Test.json(%{"id" => 99, "state" => "APPROVED"})

          true ->
            conn |> put_status(404) |> Req.Test.json(%{"message" => "unhandled"})
        end
      end)

      state = %{
        mode: :github,
        repo: "octo/widget",
        pr_number: 7,
        findings: [],
        github_opts: [token: @token]
      }

      assert {:ok, %{verdict: :approve}} = CodeReview.run_step(:verdict, state)
      assert [{:review, %{"event" => "APPROVE"} = payload}] = :ets.lookup(events, :review)
      assert is_binary(payload["body"])
    end
  end

  # =======================================================================
  # End-to-end
  # =======================================================================

  describe "GtElixir.Workflow.run/2 — local mode end-to-end" do
    test "produces verdict, writes review file, marks all steps completed" do
      %{repo: repo} = setup_repo()

      # Inject a check runner that emits one warning so we exercise the
      # finding-rendering code path while still landing on :approve.
      runner = fn _diff, _state ->
        {:ok, [%{severity: :warning, file: "added.txt", line: 1, message: "stub"}]}
      end

      initial = %{
        mode: :local,
        worktree_path: repo,
        base: "main",
        bead: %{id: "gte-021", title: "code review"},
        check_runner: runner
      }

      assert {:ok, final} = GtElixir.Workflow.run(CodeReview, initial)

      assert final.completed_steps == [
               :load_pr,
               :read_diff,
               :run_checks,
               :file_findings,
               :verdict
             ]

      assert final.verdict == :approve
      assert final.branch == "feature/x"
      assert is_binary(final.diff)
      assert length(final.findings) == 1
      assert File.exists?(final.review_path)
      assert File.read!(final.review_path) =~ "**Verdict:** APPROVE"
    end
  end

  # =======================================================================
  # GitHub.pr_review/5 — added in this PR
  # =======================================================================

  describe "GitHub.pr_review/5" do
    test "POSTs /pulls/:n/reviews with event=APPROVE for :approve" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/repos/octo/widget/pulls/9/reviews"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["event"] == "APPROVE"
        assert decoded["body"] == "lgtm"
        conn |> put_status(200) |> Req.Test.json(%{"id" => 1})
      end)

      assert {:ok, %{"id" => 1}} =
               GtElixir.GitHub.pr_review("octo/widget", 9, :approve, "lgtm", token: @token)
    end

    test "POSTs event=REQUEST_CHANGES for :request_changes" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["event"] == "REQUEST_CHANGES"
        conn |> put_status(200) |> Req.Test.json(%{"id" => 2})
      end)

      assert {:ok, _} =
               GtElixir.GitHub.pr_review("octo/widget", 9, :request_changes, "fixme",
                 token: @token
               )
    end
  end

  # =======================================================================
  # Checks default runner
  # =======================================================================

  describe "Checks.run/2" do
    test "default Phase 2 runner returns {:ok, []}" do
      assert {:ok, []} = Checks.run("any diff", %{mode: :local})
    end
  end
end
