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
    # pr_state is not accepted by :create — it is set only via :update_pr_state.
    {pr_state, create_attrs} = Map.pop(attrs, :pr_state)

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

    case pr_state do
      nil -> rec
      state -> Ash.update!(rec, %{pr_state: state}, action: :update_pr_state)
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
end
