defmodule Arbiter.Loop.ProposalsCiTest do
  # bd-cuu8n3: a repo whose lint share of CI fix_passes exceeds the threshold
  # produces a `:repo_doc_patch` proposal — the first automatic producer of
  # that kind.
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.{Analysis, Apply, Proposals, Report}
  alias Arbiter.Tasks.Workspace

  defp fix_pass(run_id, task_id, checks, ws_id) do
    %{
      run_id: run_id,
      task_id: task_id,
      repo: "arbiter",
      workspace_id: ws_id,
      evidence: %{
        checks: checks,
        code_changed?: true,
        rerun?: false,
        marked_external?: false,
        summary: nil
      }
    }
  end

  defp report(
         ws_id,
         ci_config \\ %{lint_share_threshold: 0.5, min_fix_passes: 3, check_commands: %{}}
       ) do
    lint = [
      %{name: "mix precommit (compile, deps, format)", summary: ""},
      %{name: "mix audit (credo, sobelow, dialyzer)", summary: ""}
    ]

    tasks =
      for id <- ~w(t1 t2 t3) do
        %{
          task_id: id,
          repo: "arbiter",
          model: "m",
          provider: "claude",
          workspace_id: ws_id,
          difficulty: 2,
          pr?: true
        }
      end

    ci = %{
      tasks: tasks,
      fix_passes: [
        fix_pass("r1", "t1", lint, ws_id),
        fix_pass("r2", "t2", lint, ws_id),
        fix_pass("r3", "t3", [%{name: "mix test", summary: ""}], ws_id)
      ]
    }

    Analysis.build_report([], meta: %{ci: ci}, label: "last 14d", ci_config: ci_config)
  end

  describe "candidates/2" do
    test "a lint-heavy repo yields one repo_doc_patch candidate naming its check command" do
      assert [c] =
               report("ws-1")
               |> Proposals.candidates(workspace_id: "ws-fallback")
               |> Enum.filter(&(&1.kind == :repo_doc_patch))

      assert c.repo == "arbiter"
      assert c.scope == :fleet
      assert c.workspace_id == "ws-1"
      assert Enum.sort(c.incident_refs) == ~w(r1 r2)
      assert Enum.sort(c.task_refs) == ~w(t1 t2)
      assert c.payload["lesson"] =~ "mix precommit && mix audit"
      assert c.payload["check_command"] == "mix precommit && mix audit"
      refute c.payload["lesson"] =~ "\n"
      assert c.gist =~ "mix precommit && mix audit"
      assert c.target_metric =~ "lint"
      assert c.baseline =~ "2 of 3"
    end

    test "the fingerprint is stable across windows (same repo → same row)" do
      [a] = report("ws-1") |> Proposals.candidates() |> Enum.filter(&(&1.kind == :repo_doc_patch))

      [b] =
        report("ws-1", %{lint_share_threshold: 0.1, min_fix_passes: 1, check_commands: %{}})
        |> Proposals.candidates()
        |> Enum.filter(&(&1.kind == :repo_doc_patch))

      assert Loop.fingerprint(a) == Loop.fingerprint(b)
    end

    test "no candidate below the threshold" do
      below = report("ws-1", %{lint_share_threshold: 0.9, min_fix_passes: 3, check_commands: %{}})
      refute Enum.any?(Proposals.candidates(below), &(&1.kind == :repo_doc_patch))
    end

    test "a report with no CI data yields no repo_doc_patch candidate" do
      refute Enum.any?(
               Proposals.candidates(%Report{window: %{}, totals: %{}}),
               &(&1.kind == :repo_doc_patch)
             )
    end
  end

  describe "record_all/2" do
    test "persists the proposal, applicable by the existing repo_doc_patch apply path" do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "ci-lint-ws",
          prefix: "cl",
          config: %{"repo_paths" => %{"arbiter" => "/tmp/nowhere"}}
        })

      %{rows: rows} = Proposals.record_all(report(ws.id), workspace_id: ws.id)

      assert [row] = Enum.filter(rows, &(&1.kind == :repo_doc_patch))
      assert row.repo == "arbiter"
      assert row.workspace_id == ws.id
      # 2 lint incidents across 2 tasks is under the default 3/2 bar: kept as
      # a hypothesis to accumulate, never applied.
      assert row.state == :hypothesis
      assert Apply.payload_ready?(row) == :ok
    end
  end
end
