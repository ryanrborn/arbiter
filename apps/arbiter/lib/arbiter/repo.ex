defmodule Arbiter.Repo do
  use AshSqlite.Repo,
    otp_app: :arbiter

  # Don't open unnecessary transactions — will default to false in Ash 4.0
  def prefer_transaction?, do: false

  @impl true
  def init(_type, config) do
    db_path = Keyword.get(config, :database, "")

    # Guard: a 0-byte file at the DB path means the path was created as an
    # empty placeholder (e.g. ~/.arbiter/arbiter.sqlite3 before T7 cutover).
    # Booting against it would silently wipe all data. Fail loudly instead.
    if db_path != "" and File.exists?(db_path) and File.stat!(db_path).size == 0 do
      raise """
      Arbiter.Repo: refusing to boot — DB file exists but is empty (0 bytes).

        Path: #{db_path}

      This usually means DATABASE_PATH points at the pre-cutover placeholder.
      Set DATABASE_PATH to the live database path and restart, or run the T7
      DB-copy cutover before starting the server.
      """
    end

    {:ok, config}
  end
end
