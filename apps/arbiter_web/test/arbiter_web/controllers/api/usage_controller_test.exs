defmodule ArbiterWeb.Api.UsageControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  @ws "ws-api-usage"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp insert_event!(attrs) do
    base = %{
      task_id: "bd-#{System.unique_integer([:positive])}",
      repo: "arbiter",
      workspace_id: @ws,
      step: :work,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  # bd-3j4ch4 calibration fixtures: a closed, rated task with one priced row.
  defp closed_task!(ws, difficulty, cost) do
    {:ok, issue} =
      Ash.create(Issue, %{
        title: "calib d#{difficulty} $#{cost}",
        workspace_id: ws.id,
        difficulty: difficulty,
        issue_type: :feature
      })

    {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)

    insert_event!(%{
      task_id: closed.id,
      base_task_id: closed.id,
      role: "base",
      cost_usd: cost
    })

    closed
  end

  describe "GET /api/usage" do
    test "rolls up by task", %{conn: conn} do
      _ = insert_event!(%{task_id: "bd-r1", cost_usd: 1.0, tokens_in: 100})
      _ = insert_event!(%{task_id: "bd-r1", cost_usd: 2.0, tokens_in: 200})
      _ = insert_event!(%{task_id: "bd-r2", cost_usd: 0.5})

      conn = get(conn, ~p"/api/usage", %{by: "task", workspace_id: @ws})
      body = json_response(conn, 200)
      assert body["by"] == "task"

      data = Map.new(body["data"], &{&1["group"], &1})
      assert data["bd-r1"]["rows"] == 2
      assert_in_delta data["bd-r1"]["total_cost_usd"], 3.0, 0.001
      assert data["bd-r1"]["tokens_in"] == 300
      assert_in_delta data["bd-r2"]["total_cost_usd"], 0.5, 0.001
    end

    test "rolls up by day chronologically", %{conn: conn} do
      _ = insert_event!(%{cost_usd: 1.0, occurred_at: ~U[2026-06-01 10:00:00.000000Z]})
      _ = insert_event!(%{cost_usd: 0.5, occurred_at: ~U[2026-06-02 10:00:00.000000Z]})

      conn = get(conn, ~p"/api/usage", %{by: "day", workspace_id: @ws})
      groups = Enum.map(json_response(conn, 200)["data"], & &1["group"])
      assert groups == ["2026-06-01", "2026-06-02"]
    end

    test "by step splits work vs review", %{conn: conn} do
      _ = insert_event!(%{step: :work, cost_usd: 1.0})
      _ = insert_event!(%{step: :review, cost_usd: 0.5, task_id: "bd-r#review"})

      conn = get(conn, ~p"/api/usage", %{by: "step", workspace_id: @ws})
      by_step = Map.new(json_response(conn, 200)["data"], &{&1["group"], &1})
      assert by_step["work"]["rows"] == 1
      assert by_step["review"]["rows"] == 1
    end

    test "by=campaign is accepted as a deprecated alias for by=epic", %{conn: conn} do
      _ = insert_event!(%{cost_usd: 1.0})

      conn = get(conn, ~p"/api/usage", %{by: "campaign", workspace_id: @ws})
      body = json_response(conn, 200)["data"]
      assert Enum.any?(body, &(&1["group"] == "(no_epic)"))
    end

    test "the response echoes the normalized by dimension for a deprecated alias", %{conn: conn} do
      conn = get(conn, ~p"/api/usage", %{by: "campaign", workspace_id: @ws})
      assert json_response(conn, 200)["by"] == "epic"
    end

    test "by=session groups session-sourced rows only", %{conn: conn} do
      _ =
        insert_event!(%{
          task_id: nil,
          source: :coordinator_session,
          session_id: "sess-web-1",
          cost_usd: 1.0,
          tokens_in: 100
        })

      _ =
        insert_event!(%{
          task_id: nil,
          source: :coordinator_session,
          session_id: "sess-web-1",
          cost_usd: 2.0,
          tokens_in: 200
        })

      _ = insert_event!(%{task_id: "bd-no-session", cost_usd: 5.0})

      conn = get(conn, ~p"/api/usage", %{by: "session", workspace_id: @ws})
      body = json_response(conn, 200)["data"]

      assert [row] = body
      assert row["group"] == "sess-web-1"
      assert row["rows"] == 2
      assert_in_delta row["total_cost_usd"], 3.0, 0.001
    end

    # bd-481sz7: agy/Antigravity rows always carry cost_usd: nil (subscription,
    # metered by quota %, not a priced API). A group made up entirely of such
    # rows must render total_cost_usd as null/n/a, never as a real $0.00 —
    # `arb usage` reads null and prints "n/a"; a $0.00 would misreport a
    # subscription as free.
    test "a model group with no priced rows reports total_cost_usd: null", %{conn: conn} do
      _ =
        insert_event!(%{
          model: "gemini-3.8-flash-low",
          provider: "gemini",
          cost_usd: nil,
          cost_note: "agy/Antigravity reports no cost",
          tokens_in: 4000,
          tokens_out: 250,
          thinking_tokens: 60
        })

      conn = get(conn, ~p"/api/usage", %{by: "model", workspace_id: @ws})
      data = Map.new(json_response(conn, 200)["data"], &{&1["group"], &1})

      row = data["gemini-3.8-flash-low"]
      assert row["total_cost_usd"] == nil
      assert row["tokens_in"] == 4000
      assert row["thinking_tokens"] == 60
    end

    test "missing by returns 400", %{conn: conn} do
      conn = get(conn, ~p"/api/usage", %{})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end

    test "invalid by returns 400", %{conn: conn} do
      conn = get(conn, ~p"/api/usage", %{by: "galaxy"})
      assert %{"error" => %{"type" => "invalid_request"}} = json_response(conn, 400)
    end
  end

  describe "GET /api/usage/events" do
    test "returns raw event rows newest first", %{conn: conn} do
      now = DateTime.utc_now()

      _ =
        insert_event!(%{
          task_id: "bd-e1",
          cost_usd: 0.1,
          occurred_at: DateTime.add(now, -20, :second)
        })

      _ = insert_event!(%{task_id: "bd-e2", cost_usd: 0.2, occurred_at: now})

      conn = get(conn, ~p"/api/usage/events", %{workspace_id: @ws})
      data = json_response(conn, 200)["data"]
      ids = Enum.map(data, & &1["task_id"])
      assert hd(ids) == "bd-e2"
    end

    test "task_id filter", %{conn: conn} do
      _ = insert_event!(%{task_id: "bd-only", cost_usd: 0.3})
      _ = insert_event!(%{task_id: "bd-other", cost_usd: 0.4})

      conn = get(conn, ~p"/api/usage/events", %{task_id: "bd-only", workspace_id: @ws})
      data = json_response(conn, 200)["data"]
      assert Enum.all?(data, &(&1["task_id"] == "bd-only"))
    end

    test "task_id filter includes review_gate reviewer events (#review suffix)", %{conn: conn} do
      _ = insert_event!(%{task_id: "bd-trib", step: :work, cost_usd: 0.1})
      _ = insert_event!(%{task_id: "bd-trib#review", step: :review, cost_usd: 0.2})
      _ = insert_event!(%{task_id: "bd-trib#review#r2", step: :review, cost_usd: 0.3})
      _ = insert_event!(%{task_id: "bd-unrelated", cost_usd: 0.9})

      conn = get(conn, ~p"/api/usage/events", %{task_id: "bd-trib", workspace_id: @ws})
      data = json_response(conn, 200)["data"]
      returned_ids = Enum.map(data, & &1["task_id"]) |> Enum.sort()
      assert returned_ids == ["bd-trib", "bd-trib#review", "bd-trib#review#r2"]
    end

    test "task_id filter with --step review returns only reviewer events", %{conn: conn} do
      _ = insert_event!(%{task_id: "bd-trib2", step: :work, cost_usd: 0.1})
      _ = insert_event!(%{task_id: "bd-trib2#review", step: :review, cost_usd: 0.2})

      conn =
        get(conn, ~p"/api/usage/events", %{task_id: "bd-trib2", step: "review", workspace_id: @ws})

      data = json_response(conn, 200)["data"]
      assert length(data) == 1
      assert hd(data)["task_id"] == "bd-trib2#review"
      assert hd(data)["step"] == "review"
    end

    test "session_id filter", %{conn: conn} do
      _ =
        insert_event!(%{
          task_id: nil,
          source: :coordinator_session,
          session_id: "sess-only",
          cost_usd: 0.3
        })

      _ =
        insert_event!(%{
          task_id: nil,
          source: :coordinator_session,
          session_id: "sess-other",
          cost_usd: 0.4
        })

      conn = get(conn, ~p"/api/usage/events", %{session_id: "sess-only", workspace_id: @ws})
      data = json_response(conn, 200)["data"]
      assert Enum.all?(data, &(&1["session_id"] == "sess-only"))
      assert data != []
    end
  end

  describe "source discriminator (bd-adyhvn)" do
    test "by=source splits task-attributed spend from probe spend", %{conn: conn} do
      _ = insert_event!(%{task_id: "bd-src1", source: :task, cost_usd: 1.0})

      _ =
        insert_event!(%{task_id: nil, source: :probe, cost_usd: 0.25, cache_read_tokens: 57_062})

      _ = insert_event!(%{task_id: nil, source: :preflight, cost_usd: 0.1})

      conn = get(conn, ~p"/api/usage", %{by: "source", workspace_id: @ws})
      body = json_response(conn, 200)
      assert body["by"] == "source"

      data = Map.new(body["data"], &{&1["group"], &1})
      assert_in_delta data["task"]["total_cost_usd"], 1.0, 0.001
      assert_in_delta data["probe"]["total_cost_usd"], 0.25, 0.001
      assert data["probe"]["cache_read_tokens"] == 57_062
      assert_in_delta data["preflight"]["total_cost_usd"], 0.1, 0.001
    end

    test "by=task carries no phantom group for task-less rows", %{conn: conn} do
      _ = insert_event!(%{task_id: "bd-src2", source: :task, cost_usd: 1.0})
      _ = insert_event!(%{task_id: nil, source: :probe, cost_usd: 0.25})

      conn = get(conn, ~p"/api/usage", %{by: "task", workspace_id: @ws})
      groups = json_response(conn, 200)["data"] |> Enum.map(& &1["group"])

      assert "bd-src2" in groups
      refute nil in groups
      refute "" in groups
      refute "probe" in groups
      refute "loop-analyze" in groups
    end

    test "events are filterable by source and always render one", %{conn: conn} do
      _ = insert_event!(%{task_id: "bd-src3", source: :task, cost_usd: 1.0})
      _ = insert_event!(%{task_id: nil, source: :probe, cost_usd: 0.25})

      conn = get(conn, ~p"/api/usage/events", %{source: "probe", workspace_id: @ws})
      data = json_response(conn, 200)["data"]

      assert [event] = data
      assert event["source"] == "probe"
      assert event["task_id"] == nil
    end

    test "an unknown source is a 400, not a crash", %{conn: conn} do
      conn = get(conn, ~p"/api/usage/events", %{source: "not_a_source", workspace_id: @ws})
      assert json_response(conn, 400)
    end
  end

  # Provider accounts P10 (bd-icwk2k, `docs/provider-account-design.md` §8):
  # `by=provider_account` and `?account=` read `usage_events.provider_account_id`
  # directly (P9), so probe/pre-flight rows (no `workspace_id`) are included.
  describe "account dimension (P10, bd-icwk2k)" do
    defp account!(provider \\ :claude) do
      n = System.unique_integer([:positive])

      Ash.create!(Arbiter.Accounts.ProviderAccount, %{
        provider: provider,
        slug: "usage-ctrl-#{n}",
        label: "acct #{n}"
      })
    end

    test "by=provider_account groups rows, including probe rows with no workspace", %{
      conn: conn
    } do
      account = account!()

      _ =
        insert_event!(%{
          task_id: "bd-acct1",
          source: :task,
          cost_usd: 1.0,
          provider_account_id: account.id
        })

      _ =
        insert_event!(%{
          task_id: nil,
          source: :preflight,
          workspace_id: nil,
          cost_usd: 0.5,
          provider_account_id: account.id
        })

      conn = get(conn, ~p"/api/usage", %{by: "provider_account"})
      body = json_response(conn, 200)
      data = Map.new(body["data"], &{&1["group"], &1})

      assert data[account.id]["rows"] == 2
      assert_in_delta data[account.id]["total_cost_usd"], 1.5, 0.001
    end

    test "?account=<slug> narrows a rollup to one account", %{conn: conn} do
      mine = account!()
      theirs = account!()

      _ = insert_event!(%{task_id: "bd-acct2", cost_usd: 1.0, provider_account_id: mine.id})
      _ = insert_event!(%{task_id: "bd-acct3", cost_usd: 9.0, provider_account_id: theirs.id})

      conn = get(conn, ~p"/api/usage", %{by: "task", account: mine.slug})
      groups = json_response(conn, 200)["data"] |> Enum.map(& &1["group"])

      assert groups == ["bd-acct2"]
    end

    test "?account=<slug> narrows the raw event list too", %{conn: conn} do
      mine = account!()
      theirs = account!()

      _ = insert_event!(%{task_id: "bd-acct4", cost_usd: 1.0, provider_account_id: mine.id})
      _ = insert_event!(%{task_id: "bd-acct5", cost_usd: 9.0, provider_account_id: theirs.id})

      conn = get(conn, ~p"/api/usage/events", %{account: mine.slug})
      data = json_response(conn, 200)["data"]

      assert [event] = data
      assert event["task_id"] == "bd-acct4"
    end

    test "an unknown account ref is a 400, not a crash", %{conn: conn} do
      conn = get(conn, ~p"/api/usage", %{by: "task", account: "no-such-account"})
      assert json_response(conn, 400)
    end
  end

  # bd-3j4ch4: the mis-rating report backing `arb usage --calibration`.
  describe "GET /api/usage/calibration" do
    test "reports per-tier rates and the flagged tasks", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "calib-ws", prefix: "cal"})

      Enum.each(1..10, &closed_task!(ws, 1, &1 * 1.0))
      Enum.each(11..20, &closed_task!(ws, 2, &1 * 1.0))
      Enum.each(21..30, &closed_task!(ws, 3, &1 * 1.0))

      # A D2 task that cost like a D3 one.
      under = closed_task!(ws, 2, 25.0)

      conn = get(conn, ~p"/api/usage/calibration")
      body = json_response(conn, 200)

      assert body["window_days"] == 60

      d2 = Enum.find(body["tiers"], &(&1["difficulty"] == 2))
      assert d2["n"] == 11
      assert d2["under_rated"] == 1
      assert d2["over_rated"] == 0
      assert d2["under_rate"] > 0.0

      flag = Enum.find(body["flagged"], &(&1["task_id"] == under.id))
      assert flag["direction"] == "under_rated"
      assert flag["suggested_difficulty"] == 3
      assert flag["re_dispatched"] == false
    end

    # The contract with `arb usage --calibration`, which lives in another app
    # and renders these keys by name. Drift here reads as a blank column, not
    # as a failure, so pin the shape.
    test "renders exactly the keys the CLI renderer consumes", %{conn: conn} do
      {:ok, ws} = Ash.create(Workspace, %{name: "calib-shape-ws", prefix: "cals"})
      Enum.each(1..10, &closed_task!(ws, 2, &1 * 1.0))
      Enum.each(21..30, &closed_task!(ws, 3, &1 * 1.0))
      closed_task!(ws, 2, 25.0)

      body = conn |> get(~p"/api/usage/calibration") |> json_response(200)

      assert Enum.sort(Map.keys(body)) ==
               ~w(flagged re_dispatched_flagged tiers window_days)

      assert Enum.sort(Map.keys(hd(body["tiers"]))) ==
               ~w(difficulty median n n_scored over_rate over_rated p25 p75 p90
                  re_dispatched under_rate under_rated)

      assert Enum.sort(Map.keys(hd(body["flagged"]))) ==
               ~w(actual_cost_usd difficulty direction issue_type re_dispatched
                  suggested_difficulty task_id title)
    end

    test "an empty ledger is an empty report, not a crash", %{conn: conn} do
      conn = get(conn, ~p"/api/usage/calibration")
      body = json_response(conn, 200)

      assert body["tiers"] == []
      assert body["flagged"] == []
    end
  end
end
