defmodule ArbiterWeb.PageController do
  use ArbiterWeb, :controller

  alias Arbiter.Vernacular

  def home(conn, _params) do
    Vernacular.put_global()

    render(conn, :home,
      worker_label: Vernacular.label(:worker),
      issue_label: Vernacular.label(:issue),
      workspace_label: Vernacular.label(:workspace),
      rig_label: Vernacular.label(:rig),
      pr_label: Vernacular.label(:pr),
      batch_label: Vernacular.label(:batch),
      epic_label: Vernacular.label(:epic),
      merge_queue_label: Vernacular.label(:merge_queue)
    )
  end
end
