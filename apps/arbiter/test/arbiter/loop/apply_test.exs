defmodule Arbiter.Loop.ApplyTest do
  @moduledoc """
  bd-3b7svv: unit tests for the named steps `Arbiter.Loop.apply_pending/2` is
  built from. `pending_write_test.exs` and `repo_doc_patch_apply_test.exs`
  cover the whole pipeline end to end; these pin each step *on its own*, so a
  regression in validation, side-effect application, persistence or
  notification is attributable to one function rather than to "apply broke".

  The point of the split is that the evidence-bar discipline is checkable in
  isolation: `validate/1` refusing a `:hypothesis` is a property of that
  function, not an emergent property of the four steps running in order.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.Apply
  alias Arbiter.Loop.Apply.{Payload, RepoDoc}
  alias Arbiter.Loop.{Notify, PendingWrite, SkillClause}
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "loop-apply-ws", prefix: "la"})
    %{ws: ws}
  end

  defp candidate(overrides) do
    Map.merge(
      %{
        kind: :skill_patch,
        gist: "teach read discipline: context exhaustion",
        category: "context exhaustion — agent burned its own context window",
        target: nil,
        difficulty: nil,
        repo: nil,
        scope: :fleet,
        target_metric: nil,
        baseline: nil,
        incident_refs: ["run-a", "run-b"],
        task_refs: ["bd-1"],
        payload: %{},
        origin: "loop.analyze"
      },
      overrides
    )
  end

  # A `:task`-scoped row bypasses the evidence bar, so one `record/1` call is
  # enough to land in `:proposed` — the state every apply step expects.
  defp proposed_override(ws, issue, difficulty) do
    {:ok, row} =
      Loop.record(
        candidate(%{
          workspace_id: ws.id,
          kind: :difficulty_override,
          scope: :task,
          target: issue.id,
          gist: "raise difficulty on #{issue.id} to #{difficulty}",
          payload: %{"task_id" => issue.id, "difficulty" => difficulty}
        })
      )

    row
  end

  describe "Apply.validate/1 — the validation step" do
    test "passes a :proposed row", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "v", difficulty: 1, workspace_id: ws.id})
      row = proposed_override(ws, issue, 2)

      assert row.state == :proposed
      assert :ok == Apply.validate(row)
    end

    test "refuses a :hypothesis with the shortfall spelled out", %{ws: ws} do
      {:ok, row} = Loop.record(candidate(%{workspace_id: ws.id}))
      assert row.state == :hypothesis

      assert {:error, {:not_applicable, reason}} = Apply.validate(row)
      assert reason =~ "hypothesis"
      assert reason =~ "needs 1 more incident(s) and 1 more distinct task(s)"
    end

    test "refuses an already-applied row" do
      assert {:error, {:not_applicable, reason}} =
               Apply.validate(%PendingWrite{state: :applied})

      assert reason =~ "applied"
    end
  end

  describe "Apply.attribution/1" do
    test "labels the change with the proposal id, not the operator" do
      assert Apply.attribution(%PendingWrite{id: "abc-123"}) == "loop:proposal:abc-123"
    end
  end

  describe "Apply.side_effect/2 — the side-effect step, on its own" do
    test "applies a difficulty_override without touching the proposal row", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "inert", difficulty: 1, workspace_id: ws.id})
      row = proposed_override(ws, issue, 2)

      assert :ok == Apply.side_effect(row, Apply.attribution(row))

      {:ok, reloaded} = Ash.get(Issue, issue.id)
      assert reloaded.difficulty == 2

      # Persistence is a separate step: the side effect must not mark the row.
      {:ok, still} = Loop.get_pending(row.id)
      assert still.state == :proposed
      assert is_nil(still.applied_at)
    end

    test "reports a missing skill target as :unmapped without writing anything", %{ws: ws} do
      {:ok, row} =
        Loop.record(candidate(%{workspace_id: ws.id, scope: :task, payload: %{}}))

      assert {:error, {:unmapped, msg}} = Apply.side_effect(row, Apply.attribution(row))
      assert msg =~ "skill"
    end

    test "reports an unknown skill name as :unmapped", %{ws: ws} do
      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            scope: :task,
            payload: %{"skill" => "no-such-skill", "body" => "new body"}
          })
        )

      assert {:error, {:unmapped, msg}} = Apply.side_effect(row, Apply.attribution(row))
      assert msg =~ "no-such-skill"
    end

    test "a :skill_create side effect authors the skill with managed_by: :loop (bd-blxwla)", %{
      ws: ws
    } do
      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            kind: :skill_create,
            scope: :task,
            payload: %{"name" => "loop-authored", "body" => "# body"}
          })
        )

      assert :ok == Apply.side_effect(row, Apply.attribution(row))

      {:ok, skill} = Arbiter.Skills.get_skill("loop-authored")
      assert skill.managed_by == :loop
    end
  end

  describe "Apply.side_effect/2 — the skill_patch clause splice (bd-5w8h0r)" do
    setup %{ws: ws} do
      {:ok, skill} =
        Arbiter.Skills.create_skill(%{
          name: "test-driven-development",
          body: "# Test-driven development\n\nWrite the test first.\n"
        })

      %{ws: ws, skill: skill}
    end

    defp clause_row(ws, clause) do
      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            scope: :task,
            category: "missing test coverage",
            target: "test-driven-development",
            payload: %{
              "skill" => "test-driven-development",
              "clause_id" => "missing-test-coverage",
              "clause" => clause
            }
          })
        )

      row
    end

    defp rendered(incidents) do
      SkillClause.render(%{
        category: "missing test coverage",
        imperative: "Confirm every new branch has a test that fails without the change.",
        example: "no test for the error branch",
        incidents: incidents,
        tasks: ["bd-1", "bd-2"],
        fingerprint: String.duplicate("f", 64),
        window_until: ~U[2026-09-04 00:00:00Z]
      })
    end

    test "splices the clause into the live body, leaving the rest of the skill untouched", %{
      ws: ws
    } do
      row = clause_row(ws, rendered(4))

      assert :ok == Apply.side_effect(row, Apply.attribution(row))

      {:ok, skill} = Arbiter.Skills.get_skill("test-driven-development")
      assert skill.body =~ "Write the test first."
      assert skill.body =~ "## Missing test coverage"
      assert skill.body =~ "4 incidents"
    end

    test "a later window replaces its own clause rather than appending a second copy", %{ws: ws} do
      first = clause_row(ws, rendered(4))
      assert :ok == Apply.side_effect(first, Apply.attribution(first))

      # A fresh row for the same finding, one window later, with more evidence.
      {:ok, second} =
        Ash.update(first, %{payload: Map.put(first.payload, "clause", rendered(9)), actor: "loop"},
          action: :reinforce,
          actor: "loop"
        )

      assert :ok == Apply.side_effect(second, Apply.attribution(second))

      {:ok, skill} = Arbiter.Skills.get_skill("test-driven-development")
      marker = SkillClause.begin_marker("missing-test-coverage")
      assert length(String.split(skill.body, marker)) - 1 == 1
      assert skill.body =~ "9 incidents"
      refute skill.body =~ "4 incidents"
    end

    test "a human edit made while the row sat in the queue survives the apply", %{ws: ws} do
      row = clause_row(ws, rendered(4))

      {:ok, _} =
        Arbiter.Skills.update_skill(
          "test-driven-development",
          %{body: "# Test-driven development\n\nWrite the test first.\n\nAlso: run the suite.\n"},
          actor: "ryan"
        )

      assert :ok == Apply.side_effect(row, Apply.attribution(row))

      {:ok, skill} = Arbiter.Skills.get_skill("test-driven-development")
      assert skill.body =~ "Also: run the suite.",
             "the payload carries a clause, not a whole body — applying it must not revert a human edit"

      assert skill.body =~ "## Missing test coverage"
    end

    test "a clause naming a skill that does not exist is :unmapped, not a silent create", %{
      ws: ws
    } do
      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            scope: :task,
            target: "no-such-skill",
            payload: %{
              "skill" => "no-such-skill",
              "clause_id" => "missing-test-coverage",
              "clause" => rendered(4)
            }
          })
        )

      assert {:error, {:unmapped, msg}} = Apply.side_effect(row, Apply.attribution(row))
      assert msg =~ "no-such-skill"
    end
  end

  describe "Apply.persist/2 — the persistence step, on its own" do
    test "stamps :applied and applied_at without running a side effect", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "untouched", difficulty: 1, workspace_id: ws.id})
      row = proposed_override(ws, issue, 3)

      assert {:ok, applied} = Apply.persist(row, "operator")
      assert applied.state == :applied
      refute is_nil(applied.applied_at)

      # The step is persistence only — the Issue is left alone.
      {:ok, reloaded} = Ash.get(Issue, issue.id)
      assert reloaded.difficulty == 1
    end
  end

  describe "Apply.notify/1 — the notification step, on its own" do
    test "broadcasts :applied on the queue's pubsub topic", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "announce", difficulty: 1, workspace_id: ws.id})
      row = proposed_override(ws, issue, 2)

      :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, Loop.pubsub_topic())

      assert :ok == Apply.notify(row)
      assert_receive {:loop_proposal, :applied, id}, 1_000
      assert id == row.id
    end
  end

  describe "Notify — the shared announcement step" do
    test "pubsub_topic/0 still names the queue topic" do
      assert Notify.topic() == Loop.pubsub_topic()
      assert is_binary(Notify.topic())
    end

    test "workspace_id/1 prefers the row's own workspace" do
      assert Notify.workspace_id(%PendingWrite{workspace_id: "ws-1"}) == "ws-1"
    end
  end

  describe "Payload — the input-validation step" do
    test "string/3 accepts a non-empty binary and names the gap otherwise" do
      assert {:ok, "v"} = Payload.string(%{"k" => "v"}, "k")
      assert {:error, {:unmapped, msg}} = Payload.string(%{}, "k")
      assert msg =~ "\"k\""
      assert {:error, {:unmapped, "custom"}} = Payload.string(%{"k" => ""}, "k", "custom")
      assert {:error, {:unmapped, _}} = Payload.string(%{"k" => 3}, "k")
    end

    test "integer/2 accepts an integer or a fully-parseable string" do
      assert {:ok, 2} = Payload.integer(%{"d" => 2}, "d")
      assert {:ok, 2} = Payload.integer(%{"d" => "2"}, "d")
      assert {:error, {:unmapped, msg}} = Payload.integer(%{"d" => "2x"}, "d")
      assert msg =~ "not an integer"
      assert {:error, {:unmapped, _}} = Payload.integer(%{}, "d")
    end

    test "map/2 requires a non-empty map" do
      assert {:ok, %{"a" => 1}} = Payload.map(%{"patch" => %{"a" => 1}}, "patch")
      assert {:error, {:unmapped, _}} = Payload.map(%{"patch" => %{}}, "patch")
      assert {:error, {:unmapped, _}} = Payload.map(%{}, "patch")
    end

    test "workspace_id/2 prefers the payload, then the row's workspace" do
      assert {:ok, "from-payload"} =
               Payload.workspace_id(%{"workspace_id" => "from-payload"}, "fb")

      assert {:ok, "fb"} = Payload.workspace_id(%{}, "fb")
      assert {:error, {:unmapped, msg}} = Payload.workspace_id(%{}, nil)
      assert msg =~ "workspace"
    end

    test "skill_attrs/2 splices a clause into the current body rather than replacing it" do
      current = "# TDD\n\nWrite the test first.\n"

      clause =
        SkillClause.render(%{
          category: "missing test coverage",
          imperative: "Write the failing test first.",
          incidents: 3,
          tasks: ["bd-1"]
        })

      assert {:ok, %{body: body}} =
               Payload.skill_attrs(
                 %{"clause_id" => "missing-test-coverage", "clause" => clause},
                 current
               )

      assert body =~ "Write the test first."
      assert body =~ "## Missing test coverage"
    end

    test "skill_attrs/1 collects only the keys present, and refuses an empty patch" do
      assert {:ok, %{body: "b"}} = Payload.skill_attrs(%{"body" => "b"})

      assert {:ok, %{body: "b", activation_mode: "always"}} =
               Payload.skill_attrs(%{"body" => "b", "activation_mode" => "always"})

      assert {:error, {:unmapped, msg}} = Payload.skill_attrs(%{"unrelated" => 1})
      assert msg =~ "no skill patch content"
    end

    test "maybe_put/3 drops nils" do
      assert %{} == Payload.maybe_put(%{}, :a, nil)
      assert %{a: 1} == Payload.maybe_put(%{}, :a, 1)
    end
  end

  describe "RepoDoc — the repo-scoped CLAUDE.md steps" do
    test "repo/1 requires a repo attribution and says why when missing" do
      assert {:ok, "myrepo"} = RepoDoc.repo(%PendingWrite{repo: "myrepo"})
      assert {:error, {:unmapped, msg}} = RepoDoc.repo(%PendingWrite{repo: nil})
      assert msg =~ "no repo"
      assert {:error, {:unmapped, _}} = RepoDoc.repo(%PendingWrite{repo: ""})
    end

    test "resolve_target/2 maps a registered repo to {path, target_branch}" do
      ws = %Workspace{config: %{"repo_paths" => %{"myrepo" => "/srv/myrepo"}}}
      assert {:ok, {"/srv/myrepo", "main"}} = RepoDoc.resolve_target(ws, "myrepo")

      with_branch = %Workspace{
        config: %{
          "repo_paths" => %{"myrepo" => %{"path" => "/srv/myrepo", "target_branch" => "trunk"}}
        }
      }

      assert {:ok, {"/srv/myrepo", "trunk"}} = RepoDoc.resolve_target(with_branch, "myrepo")
    end

    test "resolve_target/2 refuses an unregistered repo or an entry with no path" do
      ws = %Workspace{config: %{"repo_paths" => %{"myrepo" => "/srv/myrepo"}}}

      assert {:error, {:unmapped, msg}} = RepoDoc.resolve_target(ws, "other")
      assert msg =~ "repo_paths"

      pathless = %Workspace{
        config: %{"repo_paths" => %{"myrepo" => %{"target_branch" => "main"}}}
      }

      assert {:error, {:unmapped, msg}} = RepoDoc.resolve_target(pathless, "myrepo")
      assert msg =~ "no path"
    end

    test "doc_path/1 is pinned to CLAUDE.md — a payload cannot steer the write (bd-1cusio)" do
      assert RepoDoc.doc_path(%{}) == "CLAUDE.md"
      assert RepoDoc.doc_path(%{"path" => "../../etc/passwd"}) == "CLAUDE.md"
      assert RepoDoc.doc_path(%{"doc_path" => "/etc/passwd"}) == "CLAUDE.md"
    end

    test "cap_bytes/1 defaults to 4_000 and only accepts a positive integer override" do
      assert RepoDoc.cap_bytes(%{}) == 4_000
      assert RepoDoc.cap_bytes(%{"cap_bytes" => 120}) == 120
      assert RepoDoc.cap_bytes(%{"cap_bytes" => 0}) == 4_000
      assert RepoDoc.cap_bytes(%{"cap_bytes" => "120"}) == 4_000
    end

    test "commit_message/3 carries the attribution, and names evictions when there are any" do
      row = %PendingWrite{gist: "teach FLAG=1"}

      msg = RepoDoc.commit_message(row, [], "loop:proposal:p1")
      assert msg =~ "teach FLAG=1"
      assert msg =~ "Applied-by: loop:proposal:p1"
      refute msg =~ "Evicted"

      evicting = RepoDoc.commit_message(row, ["old-a", "old-b"], "loop:proposal:p1")
      assert evicting =~ "Evicted (over the CLAUDE.md size cap): old-a, old-b"
      assert evicting =~ "Applied-by: loop:proposal:p1"
    end

    test "pr_description/3 quotes the lesson and any evictions" do
      row = %PendingWrite{id: "p1"}

      base = RepoDoc.pr_description(row, "tests need FLAG=1", [])
      assert base =~ "proposal `p1`"
      assert base =~ "tests need FLAG=1"
      refute base =~ "Evicted"

      evicting = RepoDoc.pr_description(row, "tests need FLAG=1", ["old-a"])
      assert evicting =~ "**Evicted to stay under the CLAUDE.md size cap:** old-a"
    end
  end
end
