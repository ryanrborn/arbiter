defmodule Arbiter.Polecat.ClaudeSessionTest do
  # async: false — Port + Phoenix.PubSub + shared Polecat registry are all
  # global resources. Per-test unique bead_ids keep cases independent.
  use ExUnit.Case, async: false

  alias Arbiter.Polecat
  alias Arbiter.Polecat.ClaudeSession

  @fixture Path.expand("../../fixtures/echo_with_done.sh", __DIR__)

  defp new_bead_id, do: "gte-013-#{System.unique_integer([:positive])}"

  defp start_polecat(extra_opts \\ []) do
    bead_id = new_bead_id()

    {:ok, pid} =
      Polecat.start(Keyword.merge([bead_id: bead_id, rig: "arbiter"], extra_opts))

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    {pid, bead_id}
  end

  defp tmp_dir!(tag) do
    dir = Path.join(System.tmp_dir!(), "#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Wait until `fun.()` is truthy or we've slept past `timeout_ms`. Returns
  # the truthy value or fails the test.
  defp eventually(fun, timeout_ms \\ 2_000, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline, step_ms)
  end

  defp do_eventually(fun, deadline, step_ms) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("eventually/2 timed out")
        else
          Process.sleep(step_ms)
          do_eventually(fun, deadline, step_ms)
        end

      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("eventually/2 timed out")
        else
          Process.sleep(step_ms)
          do_eventually(fun, deadline, step_ms)
        end

      truthy ->
        truthy
    end
  end

  setup do
    setup_assertions()
    :ok
  end

  # Sanity: the fixture must exist and be executable; otherwise every test
  # below would fail with a misleading exec-not-found error.
  defp setup_assertions do
    unless File.exists?(@fixture) and File.stat!(@fixture).mode |> Bitwise.band(0o100) > 0 do
      flunk("fixture missing or not executable: #{@fixture}")
    end
  end

  describe "start/1" do
    test "returns {:ok, port} with a valid command override" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-ok")

      assert {:ok, port} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: cwd,
                 command: [@fixture]
               )

      assert is_port(port)
    end

    test "returns {:error, {:executable_not_found, _}} for a nonexistent absolute path" do
      {pid, _} = start_polecat()
      cwd = tmp_dir!("cs-bad")

      assert {:error, {:executable_not_found, "/nope/definitely/missing/binary"}} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: cwd,
                 command: ["/nope/definitely/missing/binary"]
               )
    end

    test "returns {:error, {:invalid_worktree, _}} when cwd doesn't exist" do
      {pid, _} = start_polecat()

      assert {:error, {:invalid_worktree, "/no/such/dir/here"}} =
               ClaudeSession.start(
                 owner: pid,
                 worktree_path: "/no/such/dir/here",
                 command: [@fixture]
               )
    end

    test "requires :owner pid" do
      assert {:error, :missing_owner} =
               ClaudeSession.start(worktree_path: System.tmp_dir!(), command: [@fixture])
    end
  end

  describe "output streaming" do
    test "fixture lines land in meta[:output_lines] in order" do
      {pid, bead_id} = start_polecat()
      cwd = tmp_dir!("cs-lines")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture],
          topic: "polecat:#{bead_id}"
        )

      # Wait until the exit_status is recorded — by then all output has
      # already been processed by the polecat.
      eventually(fn ->
        case Polecat.state(pid) do
          %{meta: %{exit_status: status}} when not is_nil(status) -> status
          _ -> nil
        end
      end)

      lines = Polecat.state(pid).meta.output_lines

      assert "starting fake claude session" in lines
      assert "doing important work" in lines
      assert "gt done" in lines
      # Order is preserved (oldest first).
      assert Enum.find_index(lines, &(&1 == "starting fake claude session")) <
               Enum.find_index(lines, &(&1 == "gt done"))
    end

    test "broadcasts :polecat_output on the configured topic" do
      {pid, bead_id} = start_polecat()
      cwd = tmp_dir!("cs-bcast")
      topic = "polecat:#{bead_id}"

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture],
          topic: topic
        )

      assert_receive {:polecat_output, ^bead_id, "starting fake claude session"}, 2_000
      assert_receive {:polecat_output, ^bead_id, "doing important work"}, 2_000
      assert_receive {:polecat_output, ^bead_id, "gt done"}, 2_000
    end

    test "default topic is polecat:<bead_id> when :topic not provided" do
      {pid, bead_id} = start_polecat()
      cwd = tmp_dir!("cs-default-topic")

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "polecat:#{bead_id}")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: [@fixture]
        )

      assert_receive {:polecat_output, ^bead_id, "starting fake claude session"}, 2_000
    end
  end

  describe "completion detection" do
    test "a line matching ~r/\\bgt done\\b/ triggers Polecat.complete/2" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-done")

      # Must be :running for :completed to be a legal transition.
      :ok = Polecat.advance(pid, :implement)

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      status =
        eventually(fn ->
          case Polecat.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
      assert Polecat.state(pid).meta.result == :claude_done
    end

    test "completion signal completes the polecat even when status is :idle" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-idle-done")

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      # claude_driven mode keeps the polecat at :idle (the Machine is not
      # ticked, so advance/2 is never called). The "gt done" signal must
      # still complete the polecat from :idle.
      status =
        eventually(fn ->
          case Polecat.state(pid) do
            %{status: :completed} = s -> s.status
            _ -> nil
          end
        end)

      assert status == :completed
      assert Polecat.state(pid).meta.result == :claude_done
    end
  end

  describe "exit handling" do
    test "exit status is captured in meta[:exit_status]" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-exit")

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture])

      status =
        eventually(fn ->
          case Polecat.state(pid).meta do
            %{exit_status: s} when not is_nil(s) -> s
            _ -> nil
          end
        end)

      assert status == 0
    end

    test ":polecat_exited is broadcast on child exit" do
      {pid, bead_id} = start_polecat()
      cwd = tmp_dir!("cs-exit-bcast")
      topic = "polecat:#{bead_id}"

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

      {:ok, _port} =
        ClaudeSession.start(owner: pid, worktree_path: cwd, command: [@fixture], topic: topic)

      assert_receive {:polecat_exited, ^bead_id, 0}, 2_000
    end

    test "non-zero exit status propagates" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-nonzero")

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "echo failing; exit 42"]
        )

      status =
        eventually(fn ->
          case Polecat.state(pid).meta do
            %{exit_status: s} when not is_nil(s) -> s
            _ -> nil
          end
        end)

      assert status == 42
    end
  end

  describe "buffering" do
    test "output_lines is capped at the configured line cap" do
      {pid, _bead_id} = start_polecat()
      cwd = tmp_dir!("cs-cap")
      cap = ClaudeSession.line_cap()
      to_emit = cap + 50

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: cwd,
          command: ["sh", "-c", "for i in $(seq 1 #{to_emit}); do echo line-$i; done"]
        )

      eventually(
        fn ->
          case Polecat.state(pid).meta do
            %{exit_status: s} when not is_nil(s) -> s
            _ -> nil
          end
        end,
        5_000
      )

      lines = Polecat.state(pid).meta.output_lines
      assert length(lines) == cap
      # The cap drops the OLDEST entries (we keep the most recent `cap`).
      assert List.last(lines) == "line-#{to_emit}"
      refute "line-1" in lines
    end
  end

  describe "concurrent polecats" do
    test "each polecat sees only its own output" do
      {pid_a, bead_a} = start_polecat()
      {pid_b, bead_b} = start_polecat()

      cwd = tmp_dir!("cs-concurrent")

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "polecat:#{bead_a}")
      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, "polecat:#{bead_b}")

      {:ok, _} =
        ClaudeSession.start(
          owner: pid_a,
          worktree_path: cwd,
          command: ["sh", "-c", "echo from-a-1; echo from-a-2"]
        )

      {:ok, _} =
        ClaudeSession.start(
          owner: pid_b,
          worktree_path: cwd,
          command: ["sh", "-c", "echo from-b-1; echo from-b-2"]
        )

      # Wait for both exits.
      eventually(fn ->
        case {Polecat.state(pid_a).meta, Polecat.state(pid_b).meta} do
          {%{exit_status: a}, %{exit_status: b}} when not is_nil(a) and not is_nil(b) -> true
          _ -> nil
        end
      end)

      a_lines = Polecat.state(pid_a).meta.output_lines
      b_lines = Polecat.state(pid_b).meta.output_lines

      assert "from-a-1" in a_lines
      assert "from-a-2" in a_lines
      refute "from-b-1" in a_lines
      refute "from-b-2" in a_lines

      assert "from-b-1" in b_lines
      assert "from-b-2" in b_lines
      refute "from-a-1" in b_lines
      refute "from-a-2" in b_lines

      # Each PubSub topic only saw its own bead's output.
      assert_receive {:polecat_output, ^bead_a, "from-a-1"}, 2_000
      assert_receive {:polecat_output, ^bead_b, "from-b-1"}, 2_000
      refute_receive {:polecat_output, ^bead_a, "from-b-1"}, 100
      refute_receive {:polecat_output, ^bead_b, "from-a-1"}, 100
    end
  end
end
