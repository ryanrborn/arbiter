# ---- stub merger adapters used by the adapter-mode tests ----------------
#
# Each stub implements the full Merger behaviour but only the callbacks
# the test cares about have non-trivial behavior. We define them at the
# top level so a re-run doesn't trigger "redefining module" warnings.

defmodule Arbiter.Workflows.CodeReviewTest.Stubs do
  @moduledoc false

  defmodule Base do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
  end

  defmodule GetWithBranch do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(mr_ref), do: {:ok, %{ref: mr_ref, branch: "feat/y", status: :open}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
  end

  defmodule FailingGet do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:error, :not_found}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
  end

  defmodule DiffOk do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff("#42", _opts), do: {:ok, "diff --git a/x b/x\n+hi\n"}
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
  end

  defmodule DiffError do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:error, :transport_down}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
  end

  defmodule CommentSpy do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(mr_ref, finding, _opts) do
      send(:code_review_test_pid, {:posted, mr_ref, finding})
      {:ok, %{id: 1}}
    end

    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
  end

  defmodule PathAdapter do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{path: "/tmp/reviews/x.md"}}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{path: "/tmp/reviews/x.md"}}
  end

  defmodule FailingComment do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:error, :forbidden}
    @impl true
    def submit_review(_, _, _, _), do: {:ok, %{}}
  end

  defmodule VerdictSpy do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(_, _), do: :ok
    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(mr_ref, verdict, body, _opts) do
      send(:verdict_test_pid, {:submitted, mr_ref, verdict, body})
      {:ok, %{}}
    end
  end

  # Simulates the adapter behaviour AFTER the self-review fallback has been
  # applied: submit_review/4 returns {:ok, %{}} (success) even though the
  # formal review was rejected. This tests that the CodeReview workflow does
  # not fail when an adapter falls back to a comment on a self-authored PR.
  defmodule SelfReviewFallbackAdapter do
    @moduledoc false
    @behaviour Arbiter.Mergers.Merger
    @impl true
    def open(_, _, _, _), do: {:error, :unused}
    @impl true
    def get(_), do: {:ok, %{}}
    @impl true
    def merge(_), do: :ok
    @impl true
    def close(_), do: :ok
    @impl true
    def add_comment(mr_ref, body) do
      send(:self_review_test_pid, {:comment_fallback, mr_ref, body})
      :ok
    end

    @impl true
    def request_review(_, _), do: :ok
    @impl true
    def link_for(_), do: ""
    @impl true
    def get_diff(_, _), do: {:ok, ""}
    @impl true
    def post_inline_comment(_, _, _), do: {:ok, %{}}
    @impl true
    def submit_review(mr_ref, verdict, body, _opts) do
      # Adapter has already applied the fallback internally; returns success.
      send(:self_review_test_pid, {:submit_review_called, mr_ref, verdict, body})
      {:ok, %{self_review_fallback: true}}
    end
  end
end

defmodule Arbiter.Workflows.CodeReviewTest do
  # async: false — adapter-mode tests share the Req.Test stub registries
  # (`Arbiter.Mergers.Github.HTTP`, `Arbiter.Mergers.Gitlab.HTTP`) which
  # live in process-global tables.
  use ExUnit.Case, async: false

  alias Arbiter.Workflows.CodeReviewTest.Stubs

  alias Arbiter.Workflows.CodeReview
  alias Arbiter.Workflows.CodeReview.{Checks, LocalMode}

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

  # A repo checkout with a function definition (`sign/1`) plus a second file
  # that calls it — used to prove repo-scoped review can trace a consumer a
  # diff-only review would never see.
  defp setup_repo_with_consumer(opts \\ []) do
    token_path = Keyword.get(opts, :token_path, "lib/verus/token.ex")
    unique = "gte021-consumer-#{:erlang.unique_integer([:positive])}"
    repo = Path.join(System.tmp_dir!(), unique)
    File.mkdir_p!(Path.join(repo, Path.dirname(token_path)))
    File.mkdir_p!(Path.join(repo, "lib/verus"))

    File.write!(Path.join(repo, token_path), """
    defmodule Verus.Token do
      def sign(payload) do
        :ok
      end
    end
    """)

    File.write!(Path.join(repo, "lib/verus/session.ex"), """
    defmodule Verus.Session do
      def start(payload) do
        Verus.Token.sign(payload)
      end
    end
    """)

    {_, 0} = System.cmd("git", ["init", "-q", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
    {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

    on_exit(fn -> File.rm_rf!(repo) end)

    %{repo: repo}
  end

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
      for v <- [:worktree_path, :mode, :adapter, :mr_ref], do: assert(v in vars)
    end

    test "step_definition(:load_pr) has expected shape" do
      defn = CodeReview.step_definition(:load_pr)
      assert defn.needs == []
      assert :worktree_path in defn.vars
      assert :mode in defn.vars
      assert :adapter in defn.vars
      assert :mr_ref in defn.vars
      assert is_binary(defn.description)
    end

    test "step_definition(:verdict) depends on :file_findings" do
      assert CodeReview.step_definition(:verdict).needs == [:file_findings]
    end

    test "module does not call merger merge/1, Worker.Worktree.push, or GitHub.pr_merge" do
      # Static guarantee: the workflow itself does not reference any of the
      # forbidden merge / push symbols. We inspect the source (stripping the
      # @moduledoc block so the documented forbidden-actions list doesn't
      # trigger a false match).
      source =
        File.read!(Path.expand("../../../lib/arbiter/workflows/code_review.ex", __DIR__))

      stripped =
        Regex.replace(~r/@moduledoc\s+"""(.|\n)*?"""/m, source, "", global: false)

      refute stripped =~ "pr_merge"
      refute stripped =~ "Worktree.push"
      refute stripped =~ ":merge,"
      refute stripped =~ ", :merge,"
      refute stripped =~ "Merger.merge"
    end
  end

  # =======================================================================
  # :load_pr (local mode)
  # =======================================================================

  describe "run_step(:load_pr, ...) — local" do
    test "local mode records the current branch from the worktree" do
      %{repo: repo} = setup_repo()

      state = %{mode: :local, worktree_path: repo}
      assert {:ok, new_state} = CodeReview.run_step(:load_pr, state)
      assert new_state.branch == "feature/x"
      assert new_state.pr == nil
    end

    test "missing required keys returns {:error, {:bad_state, _}}" do
      assert {:error, {:bad_state, _}} = CodeReview.run_step(:load_pr, %{mode: :local})
    end
  end

  # =======================================================================
  # :load_pr (adapter mode)
  # =======================================================================

  describe "run_step(:load_pr, ...) — adapter" do
    test "adapter mode calls adapter.get/1 and stores the response under :pr" do
      state = %{mode: :adapter, adapter: Stubs.GetWithBranch, mr_ref: "#7"}
      assert {:ok, new_state} = CodeReview.run_step(:load_pr, state)
      assert new_state.branch == "feat/y"
      assert new_state.pr.ref == "#7"
    end

    test "load_pr tolerates an adapter.get/1 error so review can proceed" do
      state = %{mode: :adapter, adapter: Stubs.FailingGet, mr_ref: "#1"}
      assert {:ok, new_state} = CodeReview.run_step(:load_pr, state)
      assert is_nil(new_state.branch)
      assert is_nil(new_state.pr)
    end
  end

  # =======================================================================
  # :read_diff
  # =======================================================================

  describe "run_step(:read_diff, ...)" do
    test "local mode shells out to git diff against the configured base" do
      %{repo: repo} = setup_repo()

      state = %{mode: :local, worktree_path: repo, base: "main"}

      assert {:ok, %{diff: diff}} = CodeReview.run_step(:read_diff, state)
      assert is_binary(diff)
      assert diff =~ "added.txt"
      assert diff =~ "+line one"
    end

    test "adapter mode calls adapter.get_diff/2 and stores the diff" do
      state = %{mode: :adapter, adapter: Stubs.DiffOk, mr_ref: "#42"}
      assert {:ok, %{diff: "diff --git a/x b/x\n+hi\n"}} = CodeReview.run_step(:read_diff, state)
    end

    test "adapter errors propagate from read_diff" do
      state = %{mode: :adapter, adapter: Stubs.DiffError, mr_ref: "#1"}
      assert {:error, :transport_down} = CodeReview.run_step(:read_diff, state)
    end

    test "missing required keys returns {:error, _}" do
      assert {:error, _} = CodeReview.run_step(:read_diff, %{mode: :local})
    end
  end

  # =======================================================================
  # :run_checks
  # =======================================================================

  describe "run_step(:run_checks, ...)" do
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

    test "default runner short-circuits empty diff to {:ok, []}" do
      state = %{mode: :local, diff: ""}
      assert {:ok, %{findings: []}} = CodeReview.run_step(:run_checks, state)
    end

    test "scope: :repo populates :consumer_refs with cross-file callers before invoking the runner" do
      %{repo: repo} = setup_repo_with_consumer()

      diff = """
      diff --git a/lib/verus/token.ex b/lib/verus/token.ex
      --- a/lib/verus/token.ex
      +++ b/lib/verus/token.ex
      @@ -1,3 +1,3 @@
      -  def sign(payload, algorithm) do
      +  def sign(payload) do
      """

      state = %{
        mode: :adapter,
        diff: diff,
        scope: :repo,
        repo_path: repo,
        check_runner: fn _diff, _state -> {:ok, []} end
      }

      assert {:ok, %{consumer_refs: [%{identifier: "sign", file: "lib/verus/session.ex"}]}} =
               CodeReview.run_step(:run_checks, state)
    end

    test "auto-escalates to repo scope when a changed file matches a sensitive glob" do
      %{repo: repo} = setup_repo_with_consumer(token_path: "lib/verus/sigv4/token.ex")

      diff = """
      diff --git a/lib/verus/sigv4/token.ex b/lib/verus/sigv4/token.ex
      --- a/lib/verus/sigv4/token.ex
      +++ b/lib/verus/sigv4/token.ex
      @@ -1,3 +1,3 @@
      -  def sign(payload, algorithm) do
      +  def sign(payload) do
      """

      state = %{
        mode: :adapter,
        diff: diff,
        repo_path: repo,
        sensitive_globs: ["**/sigv4/**"],
        check_runner: fn _diff, _state -> {:ok, []} end
      }

      assert {:ok, %{consumer_refs: [%{identifier: "sign", file: "lib/verus/session.ex"}]}} =
               CodeReview.run_step(:run_checks, state)
    end

    test "does not escalate when no changed file matches a sensitive glob" do
      %{repo: repo} = setup_repo_with_consumer()

      diff = """
      diff --git a/lib/verus/token.ex b/lib/verus/token.ex
      --- a/lib/verus/token.ex
      +++ b/lib/verus/token.ex
      @@ -1,3 +1,3 @@
      -  def sign(payload, algorithm) do
      +  def sign(payload) do
      """

      state = %{
        mode: :adapter,
        diff: diff,
        repo_path: repo,
        sensitive_globs: ["**/sigv4/**"],
        check_runner: fn _diff, _state -> {:ok, []} end
      }

      assert {:ok, result} = CodeReview.run_step(:run_checks, state)
      refute Map.has_key?(result, :consumer_refs)
    end

    test "scope: :diff (default) leaves :consumer_refs unset" do
      %{repo: repo} = setup_repo_with_consumer()

      diff = """
      diff --git a/lib/verus/token.ex b/lib/verus/token.ex
      --- a/lib/verus/token.ex
      +++ b/lib/verus/token.ex
      @@ -1,3 +1,3 @@
      -  def sign(payload, algorithm) do
      +  def sign(payload) do
      """

      state = %{
        mode: :adapter,
        diff: diff,
        repo_path: repo,
        check_runner: fn _diff, _state -> {:ok, []} end
      }

      assert {:ok, result} = CodeReview.run_step(:run_checks, state)
      refute Map.has_key?(result, :consumer_refs)
    end
  end

  # =======================================================================
  # :file_findings
  # =======================================================================

  describe "run_step(:file_findings, ...) — local" do
    test "writes reviews/<branch>.md with structured contents" do
      %{repo: repo} = setup_repo()

      findings = [
        %{severity: :error, file: "lib/foo.ex", line: 10, message: "boom"},
        %{severity: :info, file: "lib/bar.ex", line: 3, message: "fyi"}
      ]

      state = %{
        mode: :local,
        worktree_path: repo,
        branch: "feature/x",
        task: %{id: "gte-021", title: "code review"},
        findings: findings
      }

      assert {:ok, %{review_path: path}} = CodeReview.run_step(:file_findings, state)
      assert path == Path.join([repo, "reviews", "feature-x.md"])
      assert File.exists?(path)

      contents = File.read!(path)
      assert contents =~ "# Code review: feature/x"
      assert contents =~ "**Task:** gte-021 — code review"
      assert contents =~ "**Mode:** local"
      assert contents =~ "(2 findings)"
      assert contents =~ "lib/foo.ex:10 — error"
      assert contents =~ "lib/bar.ex:3 — info"
      # Error findings sort before info.
      assert :binary.match(contents, "lib/foo.ex") < :binary.match(contents, "lib/bar.ex")
    end
  end

  describe "run_step(:file_findings, ...) — adapter" do
    test "posts one inline comment per finding via adapter.post_inline_comment/3" do
      Process.register(self(), :code_review_test_pid)

      try do
        findings = [
          %{severity: :error, file: "a.ex", line: 1, message: "bad"},
          %{severity: :warning, file: "b.ex", line: 2, message: "meh"}
        ]

        state = %{mode: :adapter, adapter: Stubs.CommentSpy, mr_ref: "#7", findings: findings}
        assert {:ok, _} = CodeReview.run_step(:file_findings, state)

        assert_received {:posted, "#7", %{file: "a.ex", line: 1}}
        assert_received {:posted, "#7", %{file: "b.ex", line: 2}}
      after
        Process.unregister(:code_review_test_pid)
      end
    end

    test "captures adapter's review_path response (Direct-style)" do
      state = %{
        mode: :adapter,
        adapter: Stubs.PathAdapter,
        mr_ref: "direct:feature/x",
        findings: [%{severity: :info, file: "a", line: 1, message: "x"}]
      }

      assert {:ok, %{review_path: "/tmp/reviews/x.md"}} =
               CodeReview.run_step(:file_findings, state)
    end

    test "post_inline_comment error halts and propagates" do
      state = %{
        mode: :adapter,
        adapter: Stubs.FailingComment,
        mr_ref: "#1",
        findings: [%{severity: :info, file: "a", line: 1, message: "x"}]
      }

      assert {:error, :forbidden} = CodeReview.run_step(:file_findings, state)
    end
  end

  # =======================================================================
  # :verdict
  # =======================================================================

  describe "run_step(:verdict, ...) — local" do
    test "no findings → :approve, and the review file is rewritten" do
      %{repo: repo} = setup_repo()

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
  end

  describe "run_step(:verdict, ...) — adapter" do
    setup do
      Process.register(self(), :verdict_test_pid)
      on_exit(fn -> :ok end)
      :ok
    end

    test "submits an :approve verdict via adapter.submit_review/4" do
      state = %{mode: :adapter, adapter: Stubs.VerdictSpy, mr_ref: "!42", findings: []}
      assert {:ok, %{verdict: :approve}} = CodeReview.run_step(:verdict, state)
      assert_received {:submitted, "!42", :approve, body}
      assert body =~ "Approved"
    end

    test "submits :request_changes when any finding has severity :error" do
      findings = [%{severity: :error, file: "a", line: 1, message: "x"}]
      state = %{mode: :adapter, adapter: Stubs.VerdictSpy, mr_ref: "#1", findings: findings}
      assert {:ok, %{verdict: :request_changes}} = CodeReview.run_step(:verdict, state)
      assert_received {:submitted, "#1", :request_changes, _body}
    end
  end

  # =======================================================================
  # Report-only (propose) mode — bd-36qzgx
  # =======================================================================

  describe "report_only mode — file_findings + verdict post NOTHING" do
    test "file_findings captures proposed comments and posts no inline comment" do
      Process.register(self(), :code_review_test_pid)

      try do
        findings = [
          %{severity: :error, file: "a.ex", line: 1, message: "bad"},
          %{severity: :warning, file: "b.ex", line: 2, message: "meh"}
        ]

        state = %{
          mode: :adapter,
          adapter: Stubs.CommentSpy,
          mr_ref: "#7",
          report_only: true,
          findings: findings
        }

        assert {:ok, %{proposed_comments: proposed}} =
                 CodeReview.run_step(:file_findings, state)

        # NOTHING posted — the CommentSpy would have sent a :posted message.
        refute_received {:posted, _, _}

        assert [
                 %{file: "a.ex", line: 1, severity: :error, body: "**ERROR**: bad"},
                 %{file: "b.ex", line: 2, severity: :warning, body: "**WARNING**: meh"}
               ] = proposed
      after
        Process.unregister(:code_review_test_pid)
      end
    end

    test "verdict computes the recommended verdict + summary but submits nothing" do
      Process.register(self(), :verdict_test_pid)

      try do
        findings = [%{severity: :error, file: "a.ex", line: 1, message: "boom"}]

        state = %{
          mode: :adapter,
          adapter: Stubs.VerdictSpy,
          mr_ref: "#7",
          report_only: true,
          findings: findings
        }

        assert {:ok, result} = CodeReview.run_step(:verdict, state)
        assert result.verdict == :request_changes
        assert result.proposed_review_body =~ "Requesting changes"

        # VerdictSpy would have sent {:submitted, ...} had submit_review been called.
        refute_received {:submitted, _, _, _}
      after
        Process.unregister(:verdict_test_pid)
      end
    end

    test "full workflow in report_only mode makes ZERO writes to the adapter" do
      runner = fn _diff, _state ->
        {:ok,
         [
           %{severity: :error, file: "x.ex", line: 3, message: "leak"},
           %{severity: :info, file: "y.ex", line: 9, message: "nit"}
         ]}
      end

      Arbiter.Test.StubMerger.reset()
      Arbiter.Test.StubMerger.queue_get("#42", [%{status: :open}])

      initial = %{
        mode: :adapter,
        adapter: Arbiter.Test.StubMerger,
        mr_ref: "#42",
        report_only: true,
        check_runner: runner
      }

      assert {:ok, final} = Arbiter.Workflow.run(CodeReview, initial)

      assert final.verdict == :request_changes
      assert length(final.proposed_comments) == 2
      assert final.proposed_review_body =~ "Requesting changes"

      # The hard invariant: nothing was posted / submitted.
      assert Arbiter.Test.StubMerger.inline_comments() == []
      assert Arbiter.Test.StubMerger.submitted_reviews() == []
    end
  end

  # =======================================================================
  # End-to-end — :local
  # =======================================================================

  describe "Arbiter.Workflow.run/2 — local mode end-to-end" do
    test "produces verdict, writes review file, marks all steps completed" do
      %{repo: repo} = setup_repo()

      runner = fn _diff, _state ->
        {:ok, [%{severity: :warning, file: "added.txt", line: 1, message: "stub"}]}
      end

      initial = %{
        mode: :local,
        worktree_path: repo,
        base: "main",
        task: %{id: "gte-021", title: "code review"},
        check_runner: runner
      }

      assert {:ok, final} = Arbiter.Workflow.run(CodeReview, initial)

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
  # End-to-end — :adapter against the Direct merger
  # =======================================================================

  describe "Arbiter.Workflow.run/2 — adapter mode against Direct" do
    test "fetches the diff, posts findings, writes a verdict — no push, no merge" do
      %{repo: repo} = setup_repo()

      runner = fn _diff, _state ->
        {:ok,
         [
           %{severity: :error, file: "added.txt", line: 1, message: "stub error"},
           %{severity: :info, file: "added.txt", line: 1, message: "stub info"}
         ]}
      end

      initial = %{
        mode: :adapter,
        adapter: Arbiter.Mergers.Direct,
        mr_ref: "direct:feature/x",
        adapter_opts: %{repo_path: repo, target_branch: "main"},
        task: %{id: "gte-021", title: "code review"},
        check_runner: runner
      }

      assert {:ok, final} = Arbiter.Workflow.run(CodeReview, initial)

      assert final.completed_steps == [
               :load_pr,
               :read_diff,
               :run_checks,
               :file_findings,
               :verdict
             ]

      assert final.verdict == :request_changes
      assert is_binary(final.diff)
      assert final.diff =~ "added.txt"
      assert length(final.findings) == 2

      review_path = Path.join([repo, "reviews", "feature-x.md"])
      assert File.exists?(review_path)
      assert final.review_path == review_path

      contents = File.read!(review_path)
      assert contents =~ "# Code review: feature/x"
      assert contents =~ "**Task:** gte-021 — code review"
      assert contents =~ "**Verdict:** REQUEST_CHANGES"
      assert contents =~ "added.txt:1 — error"
      assert contents =~ "stub error"

      # Static guarantee: the workflow doesn't push or merge — main's tip is
      # unchanged and only the single feature commit lives ahead of it.
      assert {main_log, 0} = System.cmd("git", ["-C", repo, "log", "--oneline", "main"])
      assert String.split(main_log, "\n", trim: true) |> length() == 1

      assert {commits, 0} = System.cmd("git", ["-C", repo, "rev-list", "main..feature/x"])
      assert String.split(commits, "\n", trim: true) |> length() == 1
    end
  end

  # =======================================================================
  # End-to-end — :adapter against the GitHub merger
  # =======================================================================

  describe "Arbiter.Workflow.run/2 — adapter mode against GitHub" do
    setup do
      env = "ARB_CODEREVIEW_GH_TOKEN"
      System.put_env(env, "test-gh-token")

      Arbiter.Mergers.Github.Config.put_active(%{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "env:#{env}"
      })

      on_exit(fn ->
        Arbiter.Mergers.Github.Config.clear()
        System.delete_env(env)
      end)

      :ok
    end

    test "fetches the diff via GitHub API, posts inline comments, submits a review" do
      events = :ets.new(:events, [:public, :duplicate_bag])

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        path = conn.request_path

        cond do
          # Diff fetch: Accept negotiates raw diff
          conn.method == "GET" and path == "/repos/octo/widget/pulls/42" and
              "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
            :ets.insert(events, {:get_diff, path})

            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, "diff --git a/x.ex b/x.ex\n+hello\n")

          # PR get to fetch head SHA for inline comments
          conn.method == "GET" and path == "/repos/octo/widget/pulls/42" ->
            conn
            |> put_status(200)
            |> Req.Test.json(%{"number" => 42, "head" => %{"sha" => "deadbeef"}})

          # Inline comment
          conn.method == "POST" and path == "/repos/octo/widget/pulls/42/comments" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            :ets.insert(events, {:inline_comment, Jason.decode!(body)})
            conn |> put_status(201) |> Req.Test.json(%{"id" => 1})

          # Submit review
          conn.method == "POST" and path == "/repos/octo/widget/pulls/42/reviews" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            :ets.insert(events, {:submit_review, Jason.decode!(body)})
            conn |> put_status(200) |> Req.Test.json(%{"id" => 99})

          true ->
            conn
            |> put_status(404)
            |> Req.Test.json(%{"message" => "unhandled #{conn.method} #{path}"})
        end
      end)

      runner = fn _diff, _state ->
        {:ok, [%{severity: :error, file: "x.ex", line: 1, message: "boom"}]}
      end

      initial = %{
        mode: :adapter,
        adapter: Arbiter.Mergers.Github,
        mr_ref: "#42",
        adapter_opts: %{commit_id: "deadbeef"},
        check_runner: runner
      }

      assert {:ok, final} = Arbiter.Workflow.run(CodeReview, initial)

      assert final.verdict == :request_changes
      assert final.diff =~ "x.ex"
      assert length(final.findings) == 1

      # Ordering: diff fetched, inline comment posted, review submitted.
      assert [_] = :ets.lookup(events, :get_diff)
      assert [{:inline_comment, payload}] = :ets.lookup(events, :inline_comment)
      assert payload["path"] == "x.ex"
      assert payload["line"] == 1
      assert payload["commit_id"] == "deadbeef"
      assert payload["body"] =~ "ERROR"

      assert [{:submit_review, review}] = :ets.lookup(events, :submit_review)
      assert review["event"] == "REQUEST_CHANGES"
      assert review["body"] =~ "Requesting changes"
    end
  end

  # =======================================================================
  # End-to-end — :adapter against the GitLab merger
  # =======================================================================

  describe "Arbiter.Workflow.run/2 — adapter mode against GitLab" do
    setup do
      env = "ARB_CODEREVIEW_GL_TOKEN"
      System.put_env(env, "test-gl-token")

      Arbiter.Mergers.Gitlab.Config.put_active(%{
        "host" => "gitlab.example.com",
        "project_id" => 99,
        "credentials_ref" => "env:#{env}"
      })

      on_exit(fn ->
        Arbiter.Mergers.Gitlab.Config.clear()
        System.delete_env(env)
      end)

      :ok
    end

    test "fetches /changes, posts notes per finding, approves and posts a summary note" do
      events = :ets.new(:gl_events, [:public, :duplicate_bag])

      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and path == "/api/v4/projects/99/merge_requests/7/changes" ->
            :ets.insert(events, {:get_changes, path})

            conn
            |> put_status(200)
            |> Req.Test.json(%{
              "changes" => [
                %{
                  "old_path" => "x.ex",
                  "new_path" => "x.ex",
                  "diff" => "@@ -1 +1 @@\n-old\n+new\n"
                }
              ]
            })

          conn.method == "POST" and path == "/api/v4/projects/99/merge_requests/7/notes" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            :ets.insert(events, {:note, Jason.decode!(body)})
            conn |> put_status(201) |> Req.Test.json(%{"id" => :rand.uniform(1000)})

          conn.method == "POST" and path == "/api/v4/projects/99/merge_requests/7/approve" ->
            :ets.insert(events, {:approve, path})
            conn |> put_status(201) |> Req.Test.json(%{"id" => 1})

          conn.method == "POST" and path == "/api/v4/projects/99/merge_requests/7/unapprove" ->
            :ets.insert(events, {:unapprove, path})
            conn |> put_status(201) |> Req.Test.json(%{})

          true ->
            conn
            |> put_status(404)
            |> Req.Test.json(%{"message" => "unhandled #{conn.method} #{path}"})
        end
      end)

      runner = fn _diff, _state ->
        {:ok, [%{severity: :warning, file: "x.ex", line: 1, message: "consider naming"}]}
      end

      initial = %{
        mode: :adapter,
        adapter: Arbiter.Mergers.Gitlab,
        mr_ref: "!7",
        check_runner: runner
      }

      assert {:ok, final} = Arbiter.Workflow.run(CodeReview, initial)

      assert final.verdict == :approve
      assert final.diff =~ "x.ex"
      assert length(final.findings) == 1

      assert [_] = :ets.lookup(events, :get_changes)
      # Two notes total: the per-finding note, and the verdict summary note
      # posted by submit_review/4.
      notes = :ets.lookup(events, :note)
      assert length(notes) == 2

      bodies = Enum.map(notes, fn {:note, body} -> body["body"] end)
      assert Enum.any?(bodies, &(&1 =~ "WARNING"))
      assert Enum.any?(bodies, &(&1 =~ "Approved"))

      assert [_] = :ets.lookup(events, :approve)
    end
  end

  # =======================================================================
  # Checks default runner
  # =======================================================================

  describe "Checks.run/2" do
    test "empty diff short-circuits to {:ok, []}" do
      assert {:ok, []} = Checks.run("", %{mode: :local})
    end

    test "parses a valid JSON findings response from the override invoker" do
      raw = ~s({"findings": [{"severity":"error","file":"a.ex","line":3,"message":"oops"}]})
      Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state -> {:ok, raw} end)
      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      assert {:ok, [%{severity: :error, file: "a.ex", line: 3, message: "oops"}]} =
               Checks.run("DIFF", %{mode: :local})
    end

    test "tolerates surrounding prose around the JSON block" do
      raw = """
      Sure! Here's my review:

      {"findings": [{"severity":"info","file":"b.ex","line":1,"message":"nice"}]}

      Hope this helps.
      """

      Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state -> {:ok, raw} end)
      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      assert {:ok, [%{severity: :info, file: "b.ex", line: 1, message: "nice"}]} =
               Checks.run("DIFF", %{mode: :local})
    end

    test "non-JSON output yields {:ok, []} (treated as clean approval)" do
      Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state ->
        {:ok, "no JSON here"}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      assert {:ok, []} = Checks.run("DIFF", %{mode: :local})
    end

    test "invoker errors propagate" do
      Application.put_env(:arbiter, :code_review_invoker, fn _prompt, _state ->
        {:error, :boom}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      assert {:error, :boom} = Checks.run("DIFF", %{mode: :local})
    end

    test "folds :consumer_refs (repo-scoped reviews) into the reviewer prompt (bd-5xsp25)" do
      test_pid = self()

      Application.put_env(:arbiter, :code_review_invoker, fn prompt, _state ->
        send(test_pid, {:prompt, prompt})
        {:ok, ~s({"findings": []})}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      state = %{
        mode: :local,
        consumer_refs: [
          %{
            identifier: "sign",
            file: "lib/verus/session.ex",
            line: 3,
            snippet: "Verus.Token.sign(payload)"
          }
        ]
      }

      assert {:ok, []} = Checks.run("DIFF", state)
      assert_received {:prompt, prompt}
      assert prompt =~ "lib/verus/session.ex:3"
      assert prompt =~ "sign"
      assert prompt =~ "Verus.Token.sign(payload)"
    end

    test "omits the consumer section from the prompt when :consumer_refs is absent (diff scope)" do
      test_pid = self()

      Application.put_env(:arbiter, :code_review_invoker, fn prompt, _state ->
        send(test_pid, {:prompt, prompt})
        {:ok, ~s({"findings": []})}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      assert {:ok, []} = Checks.run("DIFF", %{mode: :local})
      assert_received {:prompt, prompt}
      refute prompt =~ "consumer"
    end

    # -- bd-adpwl0: tracker ticket body + PR title/body injection ------------

    test "folds :tracker_context into the reviewer prompt" do
      test_pid = self()

      Application.put_env(:arbiter, :code_review_invoker, fn prompt, _state ->
        send(test_pid, {:prompt, prompt})
        {:ok, ~s({"findings": []})}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      state = %{
        mode: :adapter,
        tracker_context: %{
          ref: "VR-18174",
          type: :jira,
          title: "Prompt too long on large PRs",
          description: "The reviewer chokes on bundled app.js diffs."
        }
      }

      assert {:ok, []} = Checks.run("DIFF", state)
      assert_received {:prompt, prompt}
      assert prompt =~ "VR-18174"
      assert prompt =~ "Prompt too long on large PRs"
      assert prompt =~ "The reviewer chokes on bundled app.js diffs."
    end

    test "omits the tracker section from the prompt when :tracker_context is absent" do
      test_pid = self()

      Application.put_env(:arbiter, :code_review_invoker, fn prompt, _state ->
        send(test_pid, {:prompt, prompt})
        {:ok, ~s({"findings": []})}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      assert {:ok, []} = Checks.run("DIFF", %{mode: :local})
      assert_received {:prompt, prompt}
      refute prompt =~ "Tracker ticket"
    end

    test "folds the PR title/body from state.pr into the reviewer prompt" do
      test_pid = self()

      Application.put_env(:arbiter, :code_review_invoker, fn prompt, _state ->
        send(test_pid, {:prompt, prompt})
        {:ok, ~s({"findings": []})}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      state = %{
        mode: :adapter,
        pr: %{title: "Fix widget overflow", body: "Closes #42 by clamping the widget height."}
      }

      assert {:ok, []} = Checks.run("DIFF", state)
      assert_received {:prompt, prompt}
      assert prompt =~ "Fix widget overflow"
      assert prompt =~ "Closes #42 by clamping the widget height."
    end

    test "omits the PR section from the prompt when state.pr has no title/body" do
      test_pid = self()

      Application.put_env(:arbiter, :code_review_invoker, fn prompt, _state ->
        send(test_pid, {:prompt, prompt})
        {:ok, ~s({"findings": []})}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      assert {:ok, []} = Checks.run("DIFF", %{mode: :adapter, pr: %{status: :open}})
      assert_received {:prompt, prompt}
      refute prompt =~ "PR description"
    end

    test "elides generated/lockfile paths from the reviewed diff, with a note of what was dropped" do
      test_pid = self()

      Application.put_env(:arbiter, :code_review_invoker, fn prompt, _state ->
        send(test_pid, {:prompt, prompt})
        {:ok, ~s({"findings": []})}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      diff = """
      diff --git a/lib/foo.ex b/lib/foo.ex
      +real change
      diff --git a/priv/static/app.js b/priv/static/app.js
      +minified junk
      diff --git a/package-lock.json b/package-lock.json
      +lockfile churn
      diff --git a/mix.lock b/mix.lock
      +lockfile churn
      """

      assert {:ok, []} = Checks.run(diff, %{mode: :adapter})
      assert_received {:prompt, prompt}
      assert prompt =~ "lib/foo.ex"
      assert prompt =~ "real change"
      refute prompt =~ "minified junk"
      refute prompt =~ "lockfile churn"
      assert prompt =~ "priv/static/app.js"
      assert prompt =~ "package-lock.json"
      assert prompt =~ "mix.lock"
    end

    test "diff without any excluded paths reaches the reviewer byte-for-byte unchanged" do
      test_pid = self()

      Application.put_env(:arbiter, :code_review_invoker, fn prompt, _state ->
        send(test_pid, {:prompt, prompt})
        {:ok, ~s({"findings": []})}
      end)

      on_exit(fn -> Application.delete_env(:arbiter, :code_review_invoker) end)

      diff = "diff --git a/lib/foo.ex b/lib/foo.ex\n+real change\n"

      assert {:ok, []} = Checks.run(diff, %{mode: :local})
      assert_received {:prompt, prompt}
      assert prompt =~ diff
      refute prompt =~ "elided"
    end

    # -- bd-dl49fo regression: large-diff E2BIG (MAX_ARG_STRLEN) fix ----------

    test "root-cause doc: System.cmd with arg > MAX_ARG_STRLEN (131_072 B) exits 7" do
      # Linux enforces a per-argument limit of 131_072 bytes (MAX_ARG_STRLEN).
      # When exceeded, execve returns errno E2BIG = 7.  Erlang's System.cmd
      # surfaces this as exit-code 7 with empty stdout — not an exception —
      # which is exactly the {:claude_failed, 7, ""} pattern that broke
      # external reviews on the verus-client (FE) rig.
      big = String.duplicate("x", 131_072)
      assert {"", 7} = System.cmd("echo", [big])
    end

    test "default invoker handles a prompt larger than MAX_ARG_STRLEN via stdin" do
      # Arrange: install a tiny fake 'claude' binary that reads stdin and exits 0.
      # Put its directory first in PATH so System.find_executable picks it up
      # before the real claude.
      tmp_dir =
        Path.join(System.tmp_dir!(), "fake_claude_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      fake = Path.join(tmp_dir, "claude")

      # The script intentionally consumes stdin so the FD doesn't go unread.
      File.write!(fake, "#!/bin/sh\ncat > /dev/null\n")
      File.chmod!(fake, 0o755)

      orig_path = System.get_env("PATH", "")

      on_exit(fn ->
        System.put_env("PATH", orig_path)
        File.rm_rf(tmp_dir)
        Application.delete_env(:arbiter, :code_review_invoker)
      end)

      System.put_env("PATH", "#{tmp_dir}:#{orig_path}")
      Application.delete_env(:arbiter, :code_review_invoker)

      # A diff larger than 131_072 bytes — typical of a large FE PR with
      # TS/JS changes and package-lock.json churn.
      large_diff =
        "diff --git a/package-lock.json b/package-lock.json\n" <>
          String.duplicate("+x\n", 50_000)

      assert byte_size(large_diff) > 131_072

      # Act: run without the invoker override so default_invoke → invoke_via_stdin fires.
      result = Checks.run(large_diff, %{mode: :adapter, adapter: nil})

      # Assert: must succeed — NOT {:error, {:claude_failed, 7, ""}}.
      assert {:ok, findings, _usage} = result
      assert findings == []
    end
  end

  # =======================================================================
  # Self-review fallback — workflow succeeds when the adapter falls back
  # =======================================================================

  describe "self-review fallback (adapter returns {:ok, _} after internal fallback)" do
    setup do
      Process.register(self(), :self_review_test_pid)
      on_exit(fn -> :ok end)
      :ok
    end

    test "workflow completes and preserves the verdict when submit_review falls back" do
      findings = [%{severity: :error, file: "a.ex", line: 1, message: "blocking"}]

      state = %{
        mode: :adapter,
        adapter: Stubs.SelfReviewFallbackAdapter,
        mr_ref: "#99",
        findings: findings
      }

      assert {:ok, %{verdict: :request_changes}} = CodeReview.run_step(:verdict, state)
      assert_received {:submit_review_called, "#99", :request_changes, _body}
    end

    test "workflow completes with :approve when submit_review falls back" do
      state = %{
        mode: :adapter,
        adapter: Stubs.SelfReviewFallbackAdapter,
        mr_ref: "#99",
        findings: []
      }

      assert {:ok, %{verdict: :approve}} = CodeReview.run_step(:verdict, state)
      assert_received {:submit_review_called, "#99", :approve, _body}
    end
  end

  # =======================================================================
  # End-to-end — self-review fallback against the GitHub adapter
  # =======================================================================

  describe "Arbiter.Workflow.run/2 — GitHub adapter self-review fallback" do
    setup do
      env = "ARB_CODEREVIEW_GH_SELFREVIEW_TOKEN"
      System.put_env(env, "test-gh-selfreview-token")

      Arbiter.Mergers.Github.Config.put_active(%{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "env:#{env}"
      })

      on_exit(fn ->
        Arbiter.Mergers.Github.Config.clear()
        System.delete_env(env)
      end)

      :ok
    end

    test "workflow succeeds and verdict is preserved when GitHub rejects formal review with 422 self-review error" do
      events = :ets.new(:gh_selfreview_events, [:public, :duplicate_bag])

      Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
        path = conn.request_path

        cond do
          conn.method == "GET" and
              "application/vnd.github.v3.diff" in Plug.Conn.get_req_header(conn, "accept") ->
            conn
            |> Plug.Conn.put_resp_header("content-type", "text/plain")
            |> Plug.Conn.resp(200, "diff --git a/x.ex b/x.ex\n+changed\n")

          conn.method == "GET" and path == "/repos/octo/widget/pulls/5" ->
            conn
            |> put_status(200)
            |> Req.Test.json(%{"number" => 5, "head" => %{"sha" => "abc123"}})

          conn.method == "POST" and path == "/repos/octo/widget/pulls/5/comments" ->
            conn |> put_status(201) |> Req.Test.json(%{"id" => 1})

          # Formal review rejected: self-authored PR
          conn.method == "POST" and path == "/repos/octo/widget/pulls/5/reviews" ->
            :ets.insert(events, {:review_attempted, path})

            conn
            |> put_status(422)
            |> Req.Test.json(%{"message" => "Can not approve your own pull request."})

          # Fallback issue comment
          conn.method == "POST" and path == "/repos/octo/widget/issues/5/comments" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            :ets.insert(events, {:fallback_comment, Jason.decode!(body)})
            conn |> put_status(201) |> Req.Test.json(%{"id" => 99})

          true ->
            conn
            |> put_status(404)
            |> Req.Test.json(%{"message" => "unhandled #{conn.method} #{path}"})
        end
      end)

      runner = fn _diff, _state -> {:ok, []} end

      initial = %{
        mode: :adapter,
        adapter: Arbiter.Mergers.Github,
        mr_ref: "#5",
        check_runner: runner
      }

      assert {:ok, final} = Arbiter.Workflow.run(CodeReview, initial)

      # The workflow must succeed and preserve the verdict.
      assert final.verdict == :approve

      # The formal review was attempted.
      assert [_] = :ets.lookup(events, :review_attempted)

      # The fallback comment was posted containing the verdict.
      assert [{:fallback_comment, comment}] = :ets.lookup(events, :fallback_comment)
      assert comment["body"] =~ "VERDICT: APPROVE"
    end
  end
end
