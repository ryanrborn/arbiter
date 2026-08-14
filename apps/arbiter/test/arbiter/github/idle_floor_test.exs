defmodule Arbiter.GitHub.IdleFloorTest do
  @moduledoc """
  bd-8y1i58 — the idle floor.

  A completely idle installation exhausted its whole 5,000-call GitHub budget in
  under an hour, and roughly three quarters of that was classified *foreground*
  — the class the limiter is explicitly forbidden from shedding. Two record
  -scanning sweeps were the cause: `MergedPRFinalizer` ran untagged (so its
  default `:foreground` class applied), and the dashboard's Review History
  refresh fanned out over `Task.start/1`, which does not carry the ambient
  priority across the process boundary.

  These are the two invariants that would have caught it:

    1. With no work in flight, the periodic record sweeps issue **zero** GitHub
       traffic. The idle floor is a floor, not a function of backlog size.
    2. With a backlog present, everything those sweeps issue is **background** —
       so it can be shed when the account is low, and so the operator's own
       `gh` is never starved by unattended polling.
  """
  # async: false — points every GitHub-client choke point at an isolated limiter
  # via the global `:github_limiter_server` app env, and the merger client uses
  # the process-global Req.Test stub registry.
  use Arbiter.DataCase, async: false

  alias Arbiter.GitHub.Limiter
  alias Arbiter.Reviews.{PrStatePoller, Record}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.MergedPRFinalizer

  @env_var "IDLE_FLOOR_GH_TOKEN"
  @stub Arbiter.Mergers.Github.HTTP

  setup do
    System.put_env(@env_var, "idle-floor-token")

    name = :"idle_floor_limiter_#{System.unique_integer([:positive])}"
    start_supervised!({Limiter, name: name, probe: false, background_headroom: 0})

    previous = Application.get_env(:arbiter, :github_limiter_server)
    Application.put_env(:arbiter, :github_limiter_server, name)

    on_exit(fn ->
      System.delete_env(@env_var)

      if previous do
        Application.put_env(:arbiter, :github_limiter_server, previous)
      else
        Application.delete_env(:arbiter, :github_limiter_server)
      end
    end)

    {:ok, limiter: name, ws: github_ws()}
  end

  defp uniq, do: Integer.to_string(:erlang.unique_integer([:positive]))

  defp github_ws do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "idle-floor-" <> uniq(),
        prefix: "if" <> uniq(),
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "octo",
              "repo" => "widget",
              "credentials_ref" => "env:#{@env_var}"
            }
          }
        }
      })

    ws
  end

  # Records every GitHub request on the test process so "zero traffic" is an
  # assertion about real HTTP, not about the limiter's own bookkeeping.
  defp counting_stub do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(test, {:github_hit, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "4900")
      |> Plug.Conn.put_resp_header("x-ratelimit-limit", "5000")
      |> Plug.Conn.put_status(200)
      |> Req.Test.json(%{"number" => 42, "state" => "open", "merged" => false, "html_url" => "u"})
    end)
  end

  # Same accounting as `counting_stub/0`, but the PR now reports as merged —
  # the state transition a backed-off record has to notice.
  defp merged_stub do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      send(test, {:github_hit, conn.request_path})

      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "4900")
      |> Plug.Conn.put_resp_header("x-ratelimit-limit", "5000")
      |> Plug.Conn.put_status(200)
      |> Req.Test.json(%{
        "number" => 42,
        "state" => "closed",
        "merged" => true,
        "html_url" => "u"
      })
    end)
  end

  defp github_hits(acc \\ 0) do
    receive do
      {:github_hit, _path} -> github_hits(acc + 1)
    after
      0 -> acc
    end
  end

  defp start_finalizer(ws, opts \\ []) do
    name = :"idle_floor_finalizer_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {MergedPRFinalizer,
         Keyword.merge([repo: "octo/widget", workspace_id: ws.id, name: name], opts)}
      )

    Req.Test.allow(@stub, self(), pid)
    name
  end

  defp start_poller(opts \\ []) do
    poller =
      start_supervised!({PrStatePoller, Keyword.merge([name: nil, enabled: false], opts)})

    Req.Test.allow(@stub, self(), poller)
    poller
  end

  # A poller driven by a clock this test advances by hand, so backoff growth is
  # observable without sleeping through real minutes.
  defp start_clocked_poller(opts) do
    {:ok, clock} = Agent.start_link(fn -> DateTime.utc_now() end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    poller = start_poller(Keyword.merge([clock_fun: fn -> Agent.get(clock, & &1) end], opts))
    advance = fn ms -> Agent.update(clock, &DateTime.add(&1, ms, :millisecond)) end

    {poller, advance}
  end

  # Run one cycle and report whether it issued any GitHub traffic.
  defp cycle_hits(poller) do
    :ok = PrStatePoller.poll(poller)
    github_hits()
  end

  defp open_task(ws, pr_ref) do
    {:ok, task} = Ash.create(Issue, %{title: "task #{pr_ref}", workspace_id: ws.id})
    {:ok, task} = Ash.update(task, %{pr_ref: pr_ref}, action: :update)
    task
  end

  defp review_record(ws) do
    {:ok, rec} =
      Ash.create(Record, %{
        pr_ref: "octo/widget#42",
        workspace_id: ws.id,
        strategy: "github",
        status: :completed,
        started_at: DateTime.utc_now()
      })

    rec
  end

  describe "invariant 1: no work in flight means no GitHub traffic" do
    test "the finalizer sweep issues nothing when there are no open tasks", %{ws: ws} do
      counting_stub()

      name = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      assert github_hits() == 0
    end

    test "the pr_state poller issues nothing when there are no non-terminal records" do
      counting_stub()

      poller = start_poller()
      :ok = PrStatePoller.poll(poller)

      assert github_hits() == 0
    end
  end

  describe "invariant 2: a backlog is swept as background, never foreground" do
    test "the finalizer sweep is entirely background-classified", %{ws: ws, limiter: srv} do
      counting_stub()
      for n <- 1..5, do: open_task(ws, to_string(n))

      name = start_finalizer(ws)
      :ok = MergedPRFinalizer.tick(name)

      assert github_hits() > 0

      counts = Limiter.stats(srv)[:shared].counts
      assert counts.foreground == 0
      assert counts.background > 0
    end

    test "the pr_state poller cycle is entirely background-classified",
         %{ws: ws, limiter: srv} do
      counting_stub()
      review_record(ws)

      poller = start_poller()
      :ok = PrStatePoller.poll(poller)

      assert github_hits() > 0

      counts = Limiter.stats(srv)[:shared].counts
      assert counts.foreground == 0
      assert counts.background > 0
    end

    test "a backlog far larger than one tick's budget still costs one budget",
         %{ws: ws, limiter: srv} do
      counting_stub()
      for n <- 100..139, do: open_task(ws, to_string(n))

      name = start_finalizer(ws, max_checks_per_tick: 5)
      :ok = MergedPRFinalizer.tick(name)

      # `adapter.get/1` costs two calls (the PR, then its reviews), so the
      # budget bounds the sweep at 5 PRs — not all 40 open tasks.
      assert github_hits() <= 10

      counts = Limiter.stats(srv)[:shared].counts
      assert counts.foreground == 0
    end
  end

  # bd-7qgxf9 — the background half of the idle floor.
  #
  # #1126 dropped the *foreground* idle floor to zero, and the two invariants
  # above lock that in. But "no work in flight" was encoded as "no non-terminal
  # records", and that is not what an idle installation looks like: a real
  # install carries a standing population of review records whose PR is simply
  # still `open` (or stuck `unknown` after a transient failure). Those are not
  # work in flight — arbiter has nothing pending on them — yet the poller
  # re-resolved every one of them once a minute, forever, at a flat rate wholly
  # decoupled from whether anything was happening. Roughly 30 such records is
  # the reported ~30 calls/min = ~1,776/hr on a completely quiet fleet.
  #
  # The floor therefore has to be a property of *time since anything changed*,
  # not of backlog size: a record nobody is touching must cost asymptotically
  # nothing, while one that actually moves snaps back to the fast cadence.
  describe "invariant 3: a settled backlog decays toward zero (bd-7qgxf9)" do
    test "a record whose state stops changing is polled less and less often", %{ws: ws} do
      counting_stub()
      review_record(ws)

      {poller, advance} = start_clocked_poller(interval_ms: 60_000)

      # Cycle 1 resolves nil -> "open". That is a real transition, so the record
      # stays on the base cadence.
      assert cycle_hits(poller) > 0

      # One interval later it is due again, and comes back "open" — unchanged.
      advance.(60_000)
      assert cycle_hits(poller) > 0

      # One interval after that it must NOT be due: the first settled check has
      # already doubled its personal interval to two.
      advance.(60_000)
      assert cycle_hits(poller) == 0

      # ...and it comes due on the cycle after.
      advance.(60_000)
      assert cycle_hits(poller) > 0
    end

    test "an hour of cycles over a settled record costs a handful of calls, not sixty",
         %{ws: ws} do
      counting_stub()
      review_record(ws)

      {poller, advance} = start_clocked_poller(interval_ms: 60_000, backoff_ceiling_ms: 3_600_000)

      busy_cycles =
        Enum.count(0..60, fn n ->
          if n > 0, do: advance.(60_000)
          cycle_hits(poller) > 0
        end)

      # Before this fix every one of the 61 cycles hit GitHub. Exponential
      # backoff capped at the hour ceiling reaches the cap after ~6 checks.
      assert busy_cycles <= 8,
             "expected a settled record to decay to a handful of checks/hour, got #{busy_cycles}"
    end

    test "a record that actually changes state snaps back to the fast cadence", %{ws: ws} do
      counting_stub()
      review_record(ws)
      {poller, advance} = start_clocked_poller(interval_ms: 60_000)

      # Settle the record at "open" until it is well backed off.
      Enum.each(0..20, fn n ->
        if n > 0, do: advance.(60_000)
        cycle_hits(poller)
      end)

      advance.(60_000)
      assert cycle_hits(poller) == 0, "record should be backed off before the state change"

      # The PR merges. The first check that observes it must reset the backoff,
      # so a genuinely moving record is never left on a stale hour-long cadence.
      merged_stub()
      advance.(3_600_000)
      assert cycle_hits(poller) > 0

      # It is now terminal, so it drops out of the poll set entirely — the
      # strongest form of the floor.
      advance.(60_000)
      assert cycle_hits(poller) == 0
    end

    test "a backlog far larger than one cycle's budget still costs one budget", %{ws: ws} do
      counting_stub()
      for _ <- 1..40, do: review_record(ws)

      poller = start_poller(max_checks_per_cycle: 5)

      # `Github.get/1` costs two calls (the PR, then its reviews), so the budget
      # bounds the cycle at 5 records — not all 40.
      assert cycle_hits(poller) <= 10
    end

    test "background traffic is attributed to the subsystem that issued it",
         %{ws: ws, limiter: srv} do
      counting_stub()
      review_record(ws)

      poller = start_poller()
      :ok = PrStatePoller.poll(poller)

      by_subsystem = Limiter.stats(srv)[:shared].counts.by_subsystem

      assert Map.get(by_subsystem, :pr_state_poller, 0) > 0,
             "expected the poller's calls to be attributable, got #{inspect(by_subsystem)}"
    end
  end

  describe "the reserve leaves a band for the operator's own gh" do
    test "below the reserve, even foreground arbiter traffic is withheld" do
      name = :"idle_floor_reserve_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {Limiter, name: name, probe: false, foreground_reserve: 500},
          id: name
        )
      )

      Limiter.observe("tok", %{remaining: 400, limit: 5000}, name)

      assert Limiter.acquire("tok", :foreground, name) == {:paused, :foreground_reserve}
      assert Limiter.acquire("tok", :background, name) == {:paused, :foreground_reserve}
    end
  end
end
