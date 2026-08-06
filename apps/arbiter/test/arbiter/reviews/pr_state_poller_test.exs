defmodule Arbiter.Reviews.PrStatePollerTest do
  @moduledoc """
  The background poller (bd-3jjk0e) walks non-terminal ExternalReview records
  and advances their pr_state on an interval — independent of any open
  dashboard. These tests drive one synchronous `poll/1` cycle with a stubbed
  GitHub adapter and assert the records are updated (or left frozen) correctly.
  """
  # async: false — the GitHub merger uses the process-global Req.Test stub
  # registry and the per-process active-config dictionary.
  use Arbiter.DataCase, async: false

  alias Arbiter.GitHub.Limiter
  alias Arbiter.Reviews.{PrStatePoller, Record}
  alias Arbiter.Tasks.Workspace

  @env_var "PR_STATE_POLLER_GH_TOKEN"

  setup do
    System.put_env(@env_var, "test-token")
    on_exit(fn -> System.delete_env(@env_var) end)
    :ok
  end

  defp uniq_prefix, do: "pp" <> Integer.to_string(:erlang.unique_integer([:positive]))

  defp github_ws do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "poller-ws-" <> uniq_prefix(),
        prefix: uniq_prefix(),
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

  defp record(ws, attrs) do
    # pr_state / not_found_count / gone_at are not accepted by :create — they
    # are set only via :update_pr_state.
    {pr_state_attrs, create_attrs} =
      Map.split(attrs, [:pr_state, :not_found_count, :gone_at])

    {:ok, rec} =
      Ash.create(
        Record,
        Map.merge(
          %{
            pr_ref: "octo/widget#42",
            workspace_id: ws.id,
            strategy: "github",
            status: :completed,
            started_at: DateTime.utc_now()
          },
          create_attrs
        )
      )

    case pr_state_attrs do
      empty when map_size(empty) == 0 -> rec
      _ -> Ash.update!(rec, pr_state_attrs, action: :update_pr_state)
    end
  end

  # Boot a poller with polling disabled (no timer) so we drive it synchronously.
  # The resolve cycle runs in the poller's process, so hand it access to this
  # test's Req.Test stub (and the shared DB sandbox connection).
  defp start_poller do
    poller = start_supervised!({PrStatePoller, name: nil, enabled: false})
    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), poller)
    poller
  end

  defp stub_pr(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)

  defp stub_open do
    stub_pr(fn conn ->
      case conn.request_path do
        "/repos/octo/widget/pulls/42" ->
          Req.Test.json(conn, %{"state" => "open", "merged" => false, "html_url" => "u"})

        _ ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end
    end)
  end

  test "resolves a nil-pr_state github review to its live state" do
    ws = github_ws()
    rec = record(ws, %{pr_state: nil})
    stub_open()

    poller = start_poller()
    assert :ok = PrStatePoller.poll(poller)

    assert Ash.get!(Record, rec.id).pr_state == "open"
  end

  test "recovers a previously-\"unknown\" row to its real state" do
    ws = github_ws()
    rec = record(ws, %{pr_state: "unknown"})
    stub_open()

    poller = start_poller()
    assert :ok = PrStatePoller.poll(poller)

    assert Ash.get!(Record, rec.id).pr_state == "open"
  end

  test "leaves a terminal (merged) row frozen — never re-polled" do
    ws = github_ws()
    rec = record(ws, %{pr_state: "merged"})

    # 404 everything: if the poller *did* re-resolve this row it would flip to
    # "gone". A frozen merged row must survive untouched.
    stub_pr(fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    poller = start_poller()
    assert :ok = PrStatePoller.poll(poller)

    assert Ash.get!(Record, rec.id).pr_state == "merged"
  end

  test "resolves a direct-strategy review to terminal \"n/a\"" do
    ws = github_ws()
    rec = record(ws, %{strategy: "direct", pr_state: nil, pr_ref: "n/a"})

    poller = start_poller()
    assert :ok = PrStatePoller.poll(poller)

    assert Ash.get!(Record, rec.id).pr_state == "n/a"
  end

  # bd-7qzqfs: a single 404 (e.g. a transient token/installation access blip —
  # GitHub returns 404, not 403, so as not to leak private-resource existence)
  # must not permanently drop a live PR out of tracking.
  describe "not-found confirmation (bd-7qzqfs)" do
    defp stub_not_found do
      stub_pr(fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)
    end

    test "a single 404 leaves the row \"unknown\" (retryable), not terminal \"gone\"" do
      ws = github_ws()
      rec = record(ws, %{pr_state: "open"})
      stub_not_found()

      poller = start_poller()
      assert :ok = PrStatePoller.poll(poller)

      updated = Ash.get!(Record, rec.id)
      assert updated.pr_state == "unknown"
      assert updated.not_found_count == 1
      assert is_nil(updated.gone_at)
    end

    test "only commits terminal \"gone\" after consecutive 404s across polls" do
      ws = github_ws()
      rec = record(ws, %{pr_state: "open"})
      stub_not_found()
      poller = start_poller()

      assert :ok = PrStatePoller.poll(poller)
      assert Ash.get!(Record, rec.id).pr_state == "unknown"

      assert :ok = PrStatePoller.poll(poller)
      updated = Ash.get!(Record, rec.id)
      assert updated.pr_state == "gone"
      assert updated.not_found_count == 2
      refute is_nil(updated.gone_at)
    end

    test "a 404 followed by a real 200 heals the row instead of freezing it" do
      ws = github_ws()
      rec = record(ws, %{pr_state: "open"})
      stub_not_found()
      poller = start_poller()

      assert :ok = PrStatePoller.poll(poller)
      assert Ash.get!(Record, rec.id).pr_state == "unknown"

      stub_open()
      assert :ok = PrStatePoller.poll(poller)

      updated = Ash.get!(Record, rec.id)
      assert updated.pr_state == "open"
      assert updated.not_found_count == 0
    end

    test "a \"gone\" row with a stale confirmation is re-verified and recovers if the PR is actually live" do
      ws = github_ws()

      rec =
        record(ws, %{
          pr_state: "gone",
          not_found_count: 2,
          gone_at: DateTime.add(DateTime.utc_now(), -8, :day)
        })

      stub_open()
      poller = start_poller()
      assert :ok = PrStatePoller.poll(poller)

      updated = Ash.get!(Record, rec.id)
      assert updated.pr_state == "open"
      assert updated.not_found_count == 0
    end

    test "a fresh \"gone\" row is frozen — not re-polled" do
      ws = github_ws()

      rec =
        record(ws, %{
          pr_state: "gone",
          not_found_count: 2,
          gone_at: DateTime.utc_now()
        })

      # If the poller re-resolved this row despite it being frozen, this stub
      # would raise (unstubbed request), proving it was skipped.
      poller = start_poller()
      assert :ok = PrStatePoller.poll(poller)

      assert Ash.get!(Record, rec.id).pr_state == "gone"
    end
  end

  # bd-b88l3l: the poller's forge traffic must be tagged :background so the
  # Limiter can pause it under quota pressure instead of it silently running
  # at the un-throttled :foreground default.
  test "tags its forge calls with :background priority" do
    ws = github_ws()
    record(ws, %{pr_state: nil})

    test_pid = self()

    stub_pr(fn conn ->
      send(test_pid, {:priority_seen, Limiter.current_priority()})

      case conn.request_path do
        "/repos/octo/widget/pulls/42" ->
          Req.Test.json(conn, %{"state" => "open", "merged" => false, "html_url" => "u"})

        _ ->
          conn |> Plug.Conn.put_status(200) |> Req.Test.json([])
      end
    end)

    poller = start_poller()
    assert :ok = PrStatePoller.poll(poller)

    assert_received {:priority_seen, :background}
  end
end
