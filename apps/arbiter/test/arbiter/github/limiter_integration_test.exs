defmodule Arbiter.GitHub.LimiterIntegrationTest do
  # async: false — points every GitHub-client choke point at an isolated limiter
  # via the global `:github_limiter_server` app env, so it must not run
  # concurrently with other GitHub tests sharing the singleton.
  use ExUnit.Case, async: false

  alias Arbiter.GitHub
  alias Arbiter.GitHub.Error
  alias Arbiter.GitHub.Limiter
  alias Arbiter.Mergers
  alias Arbiter.Mergers.Github.Config

  @repo "octo/widget"
  @token "pat_integration"

  setup do
    name = :"limiter_int_#{System.unique_integer([:positive])}"
    # An explicit cooldown: the suite-wide default is 0 so a trip can't leak a
    # pause across tests (see config/test.exs), but the retry-shedding test
    # below needs the backoff to actually be armed.
    start_supervised!(
      {Limiter,
       name: name, probe: false, background_headroom: 1000, secondary_cooldown_ms: 120_000}
    )

    previous = Application.get_env(:arbiter, :github_limiter_server)
    Application.put_env(:arbiter, :github_limiter_server, name)

    on_exit(fn ->
      if previous do
        Application.put_env(:arbiter, :github_limiter_server, previous)
      else
        Application.delete_env(:arbiter, :github_limiter_server)
      end
    end)

    {:ok, limiter: name}
  end

  # A stub that records — on the test process — that GitHub was actually hit, so
  # we can prove a paused background call issues ZERO real traffic.
  defp counting_stub do
    test = self()

    Req.Test.stub(GitHub.HTTP, fn conn ->
      send(test, :github_hit)

      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "500")
      |> Plug.Conn.put_resp_header("x-ratelimit-limit", "5000")
      |> Plug.Conn.put_status(200)
      |> Req.Test.json(%{"number" => 1, "state" => "open"})
    end)
  end

  describe "background is starved before foreground when the pool is saturated" do
    test "a saturated pool pauses background (zero HTTP) but never blocks foreground",
         %{limiter: srv} do
      counting_stub()

      # Saturate the (shared) pool below the reserved headroom band.
      Limiter.observe(@token, %{remaining: 500, limit: 5000, reset_at: nil}, srv)

      # Background: withheld at the seam, mapped to an ordinary error, and — the
      # crucial part — the stub is never reached (no message).
      bg_result =
        Limiter.with_priority(:background, fn ->
          GitHub.pr_get(@repo, 1, token: @token)
        end)

      assert {:error, %Error{kind: :network, message: message}} = bg_result
      assert message =~ "paused"
      refute_received :github_hit

      # Foreground: proceeds despite the identical saturation, and does hit HTTP.
      assert {:ok, %{"number" => 1}} = GitHub.pr_get(@repo, 1, token: @token)
      assert_received :github_hit
    end

    test "regression: saturating background does not make a foreground op fail",
         %{limiter: srv} do
      counting_stub()
      Limiter.observe(@token, %{remaining: 0, limit: 5000, reset_at: nil}, srv)

      # Hammer the pool with background calls — every one is withheld, so none
      # touch GitHub and none consume the (already exhausted) pool further.
      for _ <- 1..50 do
        Limiter.with_priority(:background, fn -> GitHub.pr_get(@repo, 1, token: @token) end)
      end

      refute_received :github_hit

      # The foreground operation still succeeds.
      assert {:ok, %{"number" => 1}} = GitHub.pr_get(@repo, 1, token: @token)
      assert_received :github_hit

      # And the limiter's own numbers show the background load was all paused.
      stats = Limiter.stats(srv)
      assert stats[:shared].counts.background_paused == 50
      assert stats[:shared].counts.foreground >= 1
    end
  end

  describe "observation flows from real responses back into the limiter" do
    test "a successful foreground call updates the pool's remaining", %{limiter: srv} do
      Req.Test.stub(GitHub.HTTP, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "800")
        |> Plug.Conn.put_resp_header("x-ratelimit-limit", "5000")
        |> Plug.Conn.put_status(200)
        |> Req.Test.json(%{"number" => 1})
      end)

      assert {:ok, _} = GitHub.pr_get(@repo, 1, token: @token)

      # The gate fed the response headers back; background now sees low headroom.
      assert stats = Limiter.stats(srv)
      assert stats[:shared].remaining == 800
      assert {:paused, :low_headroom} = Limiter.acquire(@token, :background, srv)
    end
  end

  # bd-8y1i58: the merger's bounded secondary-limit retry loop (bd-1yva53) ran
  # *inside* a single `gate/2` call, so one acquire could issue up to three real
  # GitHub requests. The limiter's own numbers — the thing an operator reads
  # when diagnosing an exhausted account — undercounted by up to 3x, and a
  # background retry storm could not be shed once it had started.
  describe "every real request is gated, including secondary-limit retries" do
    setup do
      System.put_env("LIMITER_MERGER_TOKEN", @token)

      Config.put_active(%{
        "owner" => "octo",
        "repo" => "widget",
        "credentials_ref" => "env:LIMITER_MERGER_TOKEN"
      })

      Application.put_env(:arbiter, :github_retry_sleep_fun, fn _ms -> :ok end)

      on_exit(fn ->
        Config.clear()
        System.delete_env("LIMITER_MERGER_TOKEN")
        Application.delete_env(:arbiter, :github_retry_sleep_fun)
      end)

      :ok
    end

    defp secondary_limit_conn(conn) do
      conn
      |> Plug.Conn.put_resp_header("retry-after", "1")
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "4000")
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{"message" => "You have exceeded a secondary rate limit"})
    end

    test "a retried foreground request is counted once per real HTTP call",
         %{limiter: srv} do
      {:ok, hits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Mergers.Github.HTTP, fn conn ->
        Agent.update(hits, &(&1 + 1))
        secondary_limit_conn(conn)
      end)

      assert {:error, _} = Mergers.Github.get("#42")

      # 1 initial + 2 bounded retries = 3 real requests…
      assert Agent.get(hits, & &1) == 3
      # …and the limiter's counter agrees.
      assert Limiter.stats(srv)[:shared].counts.foreground == 3
    end

    test "a background retry is shed once the secondary limit is recorded",
         %{limiter: srv} do
      {:ok, hits} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Mergers.Github.HTTP, fn conn ->
        Agent.update(hits, &(&1 + 1))
        secondary_limit_conn(conn)
      end)

      assert {:error, _} =
               Limiter.with_priority(:background, fn -> Mergers.Github.get("#42") end)

      # The first 403 arms the secondary backoff, so the retry is withheld
      # rather than sustaining the limit with more traffic.
      assert Agent.get(hits, & &1) == 1

      counts = Limiter.stats(srv)[:shared].counts
      assert counts.background == 1
      assert counts.background_paused == 1
      assert counts.secondary_trips == 1
    end
  end
end
