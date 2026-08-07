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

  defp start_poller do
    poller = start_supervised!({PrStatePoller, name: nil, enabled: false})
    Req.Test.allow(@stub, self(), poller)
    poller
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
