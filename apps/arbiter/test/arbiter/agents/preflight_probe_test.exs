defmodule Arbiter.Agents.PreflightProbeTest do
  @moduledoc """
  bd-svczq4: the pre-flight probe's *execution* contract.

  The gemini probe was an unbounded agentic turn rooted in the BEAM's own cwd
  (the live, hot-reloading checkout), it outlived the watchdog it was supposed
  to be bounded by, and a timeout refused a perfectly valid dispatch with a
  diagnosis that was factually wrong. These tests pin the four execution-side
  fixes: a neutral cwd, a per-adapter configurable watchdog, no surviving child
  after a timeout, and fail-open-with-a-warning as the documented default.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Gemini
  alias Arbiter.Agents.Preflight
  alias Arbiter.Worker.StopReason

  setup do
    prior = Application.get_env(:arbiter, Preflight)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, Preflight, prior),
        else: Application.delete_env(:arbiter, Preflight)
    end)

    :ok
  end

  defp put_config(pairs) do
    base = Application.get_env(:arbiter, Preflight, [])
    Application.put_env(:arbiter, Preflight, Keyword.merge(base, pairs))
  end

  defp tmp_path(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "arbiter-preflight-probe-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Path.join(dir, name)
  end

  defp alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))
  end

  defp await_gone(os_pid, attempts \\ 100) do
    Enum.reduce_while(1..attempts, false, fn _i, _acc ->
      if alive?(os_pid) do
        Process.sleep(20)
        {:cont, false}
      else
        {:halt, true}
      end
    end)
  end

  # Hazard A. `Port.open` carried no `:cd`, so the probe ran with tools enabled
  # inside whatever directory the BEAM happened to be in — on this host, the
  # live checkout Phoenix hot-reloads from.
  describe "probe cwd (Hazard A)" do
    test "probe_cwd/0 is a neutral directory, not the BEAM's cwd" do
      cwd = Preflight.probe_cwd()

      assert File.dir?(cwd)
      assert String.starts_with?(cwd, System.tmp_dir!())
      refute cwd == File.cwd!()
      refute File.exists?(Path.join(cwd, "mix.exs"))
      refute File.exists?(Path.join(cwd, ".git"))
    end

    test "a spawned probe actually runs there, not in the BEAM's cwd" do
      out = tmp_path("cwd.txt")

      assert :ok =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "pwd > #{out}; echo pong"],
                 probe_env: []
               )

      observed = out |> File.read!() |> String.trim()
      assert observed == Preflight.probe_cwd()
      refute observed == File.cwd!()
    end
  end

  # Defect 2. The 30s watchdog was a module attribute with no operator lever,
  # and agy's observed cold-start floor on this host was 102s.
  describe "timeout_ms/2 (Defect 2)" do
    test "an explicit opt always wins" do
      assert Preflight.timeout_ms(Gemini, timeout_ms: 1234) == 1234
    end

    test "gemini's built-in default clears its observed cold-start floor" do
      assert Preflight.timeout_ms(Gemini, []) >= 60_000
    end

    test "the default is per adapter, not one shared constant" do
      refute Preflight.timeout_ms(Gemini, []) == Preflight.timeout_ms(Claude, [])
    end

    test "app config can override per provider" do
      put_config(timeout_ms_by_provider: %{"gemini" => 45_000})
      assert Preflight.timeout_ms(Gemini, []) == 45_000
      assert Preflight.timeout_ms(Claude, []) != 45_000
    end

    test "app config can override the install-wide default" do
      put_config(timeout_ms: 7_000)
      assert Preflight.timeout_ms(Claude, []) == 7_000
    end
  end

  # Hazard B. `Port.close/1` does not kill a `:spawn_executable` child; the
  # timed-out agy probe outlived the watchdog by 72 seconds, still burning quota.
  describe "a timed-out probe leaves no surviving child (Hazard B)" do
    test "the spawned process and its descendants are gone after the watchdog fires" do
      parent_file = tmp_path("parent.pid")
      child_file = tmp_path("child.pid")

      script = "echo $$ > #{parent_file}; sleep 30 & echo $! > #{child_file}; wait"

      assert {:warn, _reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", script],
                 probe_env: [],
                 timeout_ms: 400
               )

      parent = parent_file |> File.read!() |> String.trim()
      child = child_file |> File.read!() |> String.trim()

      assert await_gone(parent), "probe process #{parent} survived the watchdog"
      assert await_gone(child), "probe descendant #{child} survived the watchdog"
    end
  end

  # Defect 3 + the fail-open decision (acceptance 5 & 6).
  describe "a pre-flight timeout" do
    test "warns and proceeds by default rather than refusing a valid dispatch" do
      assert {:warn, reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "sleep 30"],
                 probe_env: [],
                 timeout_ms: 300
               )

      assert reason.category == :preflight_timeout
    end

    test "can be configured to refuse instead" do
      put_config(on_timeout: :refuse)

      assert {:error, reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "sleep 30"],
                 probe_env: [],
                 timeout_ms: 300
               )

      assert reason.category == :preflight_timeout
    end

    test "reports what the probe actually did, and never claims 'no output' when there was some" do
      assert {:warn, reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "echo working; echo still working; sleep 30"],
                 probe_env: [],
                 timeout_ms: 500
               )

      assert reason.summary =~ "pre-flight"
      refute reason.summary =~ "no output"
      assert reason.summary =~ "2 line"
      refute reason.remediation =~ "transcript"
    end

    test "is a different StopReason from a worker hang" do
      assert {:warn, reason} =
               Preflight.check(Claude,
                 probe_command: ["sh", "-c", "sleep 30"],
                 probe_env: [],
                 timeout_ms: 300
               )

      hang = StopReason.classify(nil, [])
      refute reason.category == hang.category
      refute reason.summary == hang.summary
      refute reason.remediation == hang.remediation
    end
  end

  # Acceptance 8: a dispatch wave probes once, not once per dispatch.
  # Acceptance 6: the fail-open decision has to be *findable*, not just coded.
  describe "documented decision" do
    test "the moduledoc records the fail-open decision" do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Preflight)

      assert doc =~ "fails open"
      assert doc =~ "on_timeout"
    end
  end
end
