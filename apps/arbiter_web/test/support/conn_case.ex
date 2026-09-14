defmodule ArbiterWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. SQLite with WAL mode
  supports concurrent readers; `async: true` is safe for
  read-heavy tests, but the sandbox serialises writes.

  ## LiveView teardown and the sandbox connection (bd-5scl0c)

  A `Phoenix.LiveView.Channel` mounted by `Phoenix.LiveViewTest` can still be
  holding a checkout on the single shared sandbox connection when it is killed,
  and killing it mid-query drops that connection. Two things keep the fallout
  inside the owning test:

    * `Phoenix.LiveViewTest` starts each channel under the *ExUnit test
      supervisor*, and `ExUnit.OnExitHandler.run/2` terminates that supervisor
      and waits for its `:DOWN` before it runs any `on_exit` callback — so
      every LiveView this test mounted is already dead by the time teardown
      starts, let alone by the time the next test starts.
    * Every module that mounts a LiveView runs `async: false`, so there is no
      concurrently running test to lose the connection out from under.

  The second one is load-bearing and invisible, so it is asserted by
  `ArbiterWeb.ConnCaseSandboxTest`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ArbiterWeb.Endpoint

      use ArbiterWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ArbiterWeb.ConnCase
    end
  end

  setup tags do
    Arbiter.DataCase.setup_sandbox(tags)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
