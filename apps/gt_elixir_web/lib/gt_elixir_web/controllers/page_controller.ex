defmodule GtElixirWeb.PageController do
  use GtElixirWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
