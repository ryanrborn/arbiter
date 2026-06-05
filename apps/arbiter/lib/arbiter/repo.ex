defmodule Arbiter.Repo do
  use AshSqlite.Repo,
    otp_app: :arbiter

  # Don't open unnecessary transactions — will default to false in Ash 4.0
  def prefer_transaction?, do: false
end
