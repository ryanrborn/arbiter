defmodule ArbiterWeb.PageController do
  use ArbiterWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
