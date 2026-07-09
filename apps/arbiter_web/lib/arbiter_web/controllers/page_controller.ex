defmodule ArbiterWeb.PageController do
  use ArbiterWeb, :controller

  def home(conn, _params) do
    render(conn, :home,
      issues_label: "Issues",
      workers_label: "Workers",
      domains_label: "Workspaces"
    )
  end
end
