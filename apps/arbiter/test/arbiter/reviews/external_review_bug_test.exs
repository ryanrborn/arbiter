defmodule Arbiter.Reviews.ExternalReviewBugTest do
  use Arbiter.DataCase, async: true
  alias Arbiter.Reviews.ExternalReview

  test "follow_up_eligible? returns false when repos == []" do
    ws = %Arbiter.Tasks.Workspace{
      id: "ws-1",
      name: "empty-repos",
      config: %{
        "review_automation" => %{"default" => "auto"},
        "merge" => %{"strategy" => "github", "config" => %{}}
      }
    }

    prepared = %{
      workspace: ws,
      repo_name: "some-repo",
      mr_ref: "octo/widget#42"
    }

    # Since it's a private function, we'll invoke it dynamically or test via ExternalReview.review
    # Actually, we can just compile and run a script
  end
end
