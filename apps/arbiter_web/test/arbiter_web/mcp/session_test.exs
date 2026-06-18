defmodule ArbiterWeb.MCP.SessionTest do
  use ExUnit.Case, async: true

  alias ArbiterWeb.MCP.Session

  test "new_id mints distinct, non-empty ids" do
    a = Session.new_id()
    b = Session.new_id()

    assert is_binary(a) and a != ""
    assert a != b
  end

  test "notify routes a message to the registered stream process" do
    test_pid = self()
    session_id = Session.new_id()

    # Stand in for the SSE stream process: register, then forward whatever the
    # session routes to it back to the test so we can assert delivery.
    stream =
      spawn_link(fn ->
        assert :ok = Session.register(session_id)
        send(test_pid, :registered)

        receive do
          {:mcp_sse, message} -> send(test_pid, {:got, message})
        after
          1_000 -> send(test_pid, :timeout)
        end
      end)

    assert_receive :registered

    assert :ok = Session.notify(session_id, %{"hello" => "world"})
    assert_receive {:got, %{"hello" => "world"}}

    _ = stream
  end

  test "notify with no open stream returns {:error, :no_session}" do
    assert {:error, :no_session} = Session.notify("nobody-home", %{})
  end

  test "a second register for the same id is rejected" do
    test_pid = self()
    session_id = Session.new_id()

    spawn_link(fn ->
      assert :ok = Session.register(session_id)
      send(test_pid, :first_registered)
      Process.sleep(200)
    end)

    assert_receive :first_registered
    assert {:error, :already_registered} = Session.register(session_id)
  end
end
