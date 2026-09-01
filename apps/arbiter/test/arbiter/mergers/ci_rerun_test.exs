defmodule Arbiter.Mergers.CIRerunTest do
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.CIRerun

  describe "choose/1" do
    test "first attempt, single failing job with no reusable upstream: rerun only the failed jobs" do
      decision =
        CIRerun.choose(%{
          run_attempt: 1,
          jobs: [%{"name" => "mix test", "conclusion" => "failure"}],
          inputs: %{}
        })

      assert decision.mode == :failed_jobs
      assert decision.rationale =~ "no completed upstream job"
    end

    test "a job that already succeeded in the run means a failed-jobs rerun would reuse it" do
      decision =
        CIRerun.choose(%{
          run_attempt: 1,
          jobs: [
            %{"name" => "build-and-push", "conclusion" => "success"},
            %{"name" => "deploy-frontend", "conclusion" => "success"},
            %{"name" => "playwright-smoke", "conclusion" => "failure"}
          ],
          inputs: %{}
        })

      assert decision.mode == :all_jobs
      assert decision.rationale =~ "2 completed upstream job"
      assert decision.reused_jobs == ["build-and-push", "deploy-frontend"]
    end

    test "a second attempt escalates to a full rerun even with no upstream jobs" do
      decision =
        CIRerun.choose(%{
          run_attempt: 2,
          jobs: [%{"name" => "playwright-smoke", "conclusion" => "failure"}],
          inputs: %{}
        })

      assert decision.mode == :all_jobs
      assert decision.rationale =~ "attempt 2"
    end

    test "explicit inputs force a fresh workflow_dispatch" do
      decision =
        CIRerun.choose(%{
          run_attempt: 1,
          jobs: [%{"name" => "playwright-smoke", "conclusion" => "failure"}],
          inputs: %{"force_deploy" => "true"}
        })

      assert decision.mode == :workflow
      assert decision.rationale =~ "force_deploy"
    end

    test "skipped and cancelled jobs are not counted as reusable upstream work" do
      decision =
        CIRerun.choose(%{
          run_attempt: 1,
          jobs: [
            %{"name" => "lint", "conclusion" => "skipped"},
            %{"name" => "flake", "conclusion" => "cancelled"},
            %{"name" => "mix test", "conclusion" => "failure"}
          ],
          inputs: %{}
        })

      assert decision.mode == :failed_jobs
    end

    test "missing/partial run metadata degrades to the cheapest rerun" do
      assert CIRerun.choose(%{}).mode == :failed_jobs
    end
  end

  describe "explain/1" do
    test "renders a one-line human summary of the decision" do
      line =
        CIRerun.choose(%{
          run_attempt: 1,
          jobs: [
            %{"name" => "deploy-frontend", "conclusion" => "success"},
            %{"name" => "playwright-smoke", "conclusion" => "failure"}
          ],
          inputs: %{}
        })
        |> CIRerun.explain()

      assert line =~ "all_jobs"
      assert line =~ "deploy-frontend"
    end
  end
end
