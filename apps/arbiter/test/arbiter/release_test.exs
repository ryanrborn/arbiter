defmodule Arbiter.ReleaseTest do
  @moduledoc """
  bd-64ye6w: every `mix arbiter.backfill_*` task's logic is callable as
  `Arbiter.Release.backfill(<name>, opts)` without Mix or the full
  `Arbiter.Application` tree.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Release
  alias Arbiter.Tasks.{Issue, Workspace}

  # `mix test` boots the full `Arbiter.Application` tree in *this* node
  # regardless of what this helper does (other tests need the
  # endpoint/registries), so the runtime check below spins up a separate
  # `:peer` node to observe the helper's real behavior in isolation. This
  # source check is a cheap first line of defense against a future edit
  # that quietly widens what gets started.
  @release_source File.read!("lib/arbiter/release.ex")
  @start_release_repo_body Regex.run(
                             ~r/def start_release_repo! do(.*?)\n  end/s,
                             @release_source
                           )
                           |> Enum.at(1)

  describe "start_release_repo!/0" do
    test "is a no-op when the repo is already started (as it is under the test sandbox)" do
      assert Release.start_release_repo!() == :ok
    end

    test "starts only Ash + the Repo, never the full application or its supervisors" do
      assert @start_release_repo_body =~ "Arbiter.Repo.start_link"
      assert @start_release_repo_body =~ ~r/ensure_all_started\(:ash\)/
      assert @start_release_repo_body =~ ~r/ensure_all_started\(:ash_sqlite\)/

      refute @start_release_repo_body =~ "Arbiter.Application"
      refute @start_release_repo_body =~ "Arbiter.Supervisor"
      refute @start_release_repo_body =~ ~r/ensure_all_started\(:arbiter\)/
      refute @start_release_repo_body =~ "app.start"
    end

    test "at runtime, in a fresh node, boots the Repo but not the endpoint, Autopilot, or :arbiter itself" do
      # No `name:` and a `:standard_io` control connection: the peer runs
      # undistributed and is driven via `:peer.call/4`, so neither node
      # needs epmd (CI runners don't have one running).
      code_paths = Enum.map(:code.get_path(), &to_charlist/1)

      {:ok, peer_pid, _nonode} =
        :peer.start_link(%{
          args: [~c"-pa" | code_paths],
          connection: :standard_io
        })

      on_exit(fn ->
        try do
          :peer.stop(peer_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      tmp_db =
        Path.join(
          System.tmp_dir!(),
          "arbiter_release_peer_#{System.unique_integer([:positive])}.sqlite3"
        )

      on_exit(fn -> File.rm(tmp_db) end)

      peer_arbiter_env =
        Application.get_all_env(:arbiter)
        |> Keyword.update!(Arbiter.Repo, &Keyword.put(&1, :database, tmp_db))

      :ok =
        :peer.call(peer_pid, Application, :put_all_env, [
          [
            arbiter: peer_arbiter_env,
            ash: Application.get_all_env(:ash),
            ash_sqlite: Application.get_all_env(:ash_sqlite)
          ]
        ])

      # `start_release_repo!/0` links the Repo to its caller (in a real
      # release that's the long-lived `eval` process), and each
      # `:peer.call/4` runs in a short-lived process — so start and observe
      # within one call, before that process exits and takes the Repo down.
      {observed, _binding} =
        :peer.call(peer_pid, Code, :eval_string, [
          """
          {Arbiter.Release.start_release_repo!(),
           Process.whereis(Arbiter.Repo),
           Process.whereis(ArbiterWeb.Endpoint),
           Process.whereis(Arbiter.Board.Autopilot),
           Application.started_applications()}
          """
        ])

      {start_result, repo_pid, endpoint_pid, autopilot_pid, started_apps} = observed

      assert start_result == :ok
      assert is_pid(repo_pid)
      assert endpoint_pid == nil
      assert autopilot_pid == nil
      refute Enum.any?(started_apps, fn {app, _, _} -> app == :arbiter end)
    end
  end

  describe "backfill/2" do
    test ":codex_usage runs without Mix and reports on an empty corpus" do
      report = Release.backfill(:codex_usage, [])

      assert report.scanned == 0
      assert report.backfilled == 0
    end

    test ":gemini_usage_note runs without Mix and reports on an empty corpus" do
      report = Release.backfill(:gemini_usage_note, [])

      assert report.scanned == 0
      assert report.noted == 0
    end

    test ":run_steps runs without Mix and reports on an empty corpus" do
      report = Release.backfill(:run_steps, [])

      assert report.scanned == 0
      assert report.inserted == 0
    end

    test ":issue_repos dry run reports the plan and writes nothing" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "release-#{System.unique_integer([:positive])}",
          prefix: "rel",
          config: %{"repo_paths" => %{"tonic" => "/srv/tonic"}}
        })

      issue = issue_without_repo!(%{title: "orphan", workspace_id: ws.id})

      plan = Release.backfill(:issue_repos, [])

      report = Enum.find(plan, &(&1.workspace_id == ws.id))
      assert report.resolved_repo == "tonic"
      assert report.null_repo_count == 1

      assert {:ok, %Issue{repo: nil}} = Ash.get(Issue, issue.id)
    end

    test ":issue_repos apply? writes the resolved repo" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "release-#{System.unique_integer([:positive])}",
          prefix: "rel",
          config: %{"repo_paths" => %{"tonic" => "/srv/tonic"}}
        })

      issue = issue_without_repo!(%{title: "orphan", workspace_id: ws.id})

      reports = Release.backfill(:issue_repos, apply?: true)

      report = Enum.find(reports, &(&1.workspace_id == ws.id))
      assert report.updated == 1

      assert {:ok, %Issue{repo: "tonic"}} = Ash.get(Issue, issue.id)
    end

    test ":task_statuses dry run reports proposals and writes nothing" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "release-#{System.unique_integer([:positive])}",
          prefix: "rel"
        })

      {:ok, task} = Ash.create(Issue, %{title: "thing", workspace_id: ws.id})

      proposals =
        Release.backfill(:task_statuses,
          git_log_lines: ["abc1234567890|feat(#{task.id}): ship the thing"]
        )

      assert [proposal] = proposals
      assert proposal.task_id == task.id

      assert {:ok, %Issue{status: :open}} = Ash.get(Issue, task.id)
    end

    test ":task_statuses apply? closes the matched task" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "release-#{System.unique_integer([:positive])}",
          prefix: "rel"
        })

      {:ok, task} = Ash.create(Issue, %{title: "thing", workspace_id: ws.id})

      {closed, errors} =
        Release.backfill(:task_statuses,
          apply?: true,
          git_log_lines: ["abc1234567890|feat(#{task.id}): ship the thing"]
        )

      assert closed == [task.id]
      assert errors == []
      assert {:ok, %Issue{status: :closed}} = Ash.get(Issue, task.id)
    end
  end
end
