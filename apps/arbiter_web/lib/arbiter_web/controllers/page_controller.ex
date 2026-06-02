defmodule ArbiterWeb.PageController do
  use ArbiterWeb, :controller

  alias Arbiter.Vernacular

  def home(conn, _params) do
    Vernacular.put_global()

    render(conn, :home,
      issues_label: plural_label(:issue),
      acolytes_label: plural_label(:worker),
      domains_label: plural_label(:workspace)
    )
  end

  # Capitalized plural of a vernacular term, e.g. :issue -> "Directives".
  defp plural_label(key) do
    (Vernacular.label(key) |> String.capitalize()) <> "s"
  end
end
