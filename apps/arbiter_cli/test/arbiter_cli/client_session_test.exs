defmodule ArbiterCli.ClientSessionTest do
  # `ARB_SESSION_ID` makes `Client` *refuse* unauthenticated requests (unlike
  # `ARB_TOKEN`, which only adds a header), so any other `arbiter_cli` test
  # calling `Client` concurrently with these could observe the env var and
  # fail with `:no_session_token`. Kept out of the async client_test.exs and
  # run serially instead (bd-5b5hq7 round 2).
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Client

  describe "inside an Arbiter session (ARB_SESSION_ID set)" do
    setup do
      on_exit(fn ->
        System.delete_env("ARB_SESSION_ID")
        System.delete_env("ARB_SESSION_ROOT")
        System.delete_env("ARB_TOKEN")
      end)

      :ok
    end

    test "authenticates with the session's own token file, never unauthenticated" do
      root = session_root!()
      File.write!(Path.join(root, "mcp_token"), "session-token-abc\n")
      File.chmod!(Path.join(root, "mcp_token"), 0o600)

      System.put_env("ARB_SESSION_ID", "sess-1")
      System.put_env("ARB_SESSION_ROOT", root)
      System.delete_env("ARB_TOKEN")

      stub_routes([
        {
          {"get", "/api/test"},
          fn conn ->
            auth = Plug.Conn.get_req_header(conn, "authorization")

            if auth == ["Bearer session-token-abc"] do
              conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ok" => true})
            else
              conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad auth"})
            end
          end
        }
      ])

      assert {:ok, %{"ok" => true}} = Client.get("/api/test")
    end

    test "an explicit ARB_TOKEN still overrides the session token file" do
      root = session_root!()
      File.write!(Path.join(root, "mcp_token"), "session-token-abc\n")

      System.put_env("ARB_SESSION_ID", "sess-1")
      System.put_env("ARB_SESSION_ROOT", root)
      System.put_env("ARB_TOKEN", "operator-override")

      stub_routes([
        {
          {"get", "/api/test"},
          fn conn ->
            auth = Plug.Conn.get_req_header(conn, "authorization")

            if auth == ["Bearer operator-override"] do
              conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ok" => true})
            else
              conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad auth"})
            end
          end
        }
      ])

      assert {:ok, %{"ok" => true}} = Client.get("/api/test")
    end

    test "refuses with a clear error when no session token file exists — never falls back to unauthenticated" do
      root = session_root!()

      System.put_env("ARB_SESSION_ID", "sess-1")
      System.put_env("ARB_SESSION_ROOT", root)
      System.delete_env("ARB_TOKEN")

      stub_routes([
        {
          {"get", "/api/test"},
          fn _conn ->
            raise "the request must never reach the server unauthenticated"
          end
        }
      ])

      assert {:error, %Client.Error{kind: :no_session_token, message: message, hint: hint}} =
               Client.get("/api/test")

      assert message =~ "session"
      assert hint =~ "ARB_SESSION_ID"
    end

    test "falls back to the .mcp.json token in cwd when the session token file is missing" do
      root = session_root!()
      cwd = session_root!()

      mcp_json =
        Jason.encode!(%{
          "mcpServers" => %{
            "arbiter" => %{
              "type" => "http",
              "url" => "http://127.0.0.1:4848/mcp",
              "headers" => %{"Authorization" => "Bearer mcp-json-token"}
            }
          }
        })

      File.write!(Path.join(cwd, ".mcp.json"), mcp_json)

      System.put_env("ARB_SESSION_ID", "sess-1")
      System.put_env("ARB_SESSION_ROOT", root)
      System.delete_env("ARB_TOKEN")

      prior_cwd = File.cwd!()
      File.cd!(cwd)
      on_exit(fn -> File.cd!(prior_cwd) end)

      stub_routes([
        {
          {"get", "/api/test"},
          fn conn ->
            auth = Plug.Conn.get_req_header(conn, "authorization")

            if auth == ["Bearer mcp-json-token"] do
              conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"ok" => true})
            else
              conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad auth"})
            end
          end
        }
      ])

      assert {:ok, %{"ok" => true}} = Client.get("/api/test")
    end
  end

  defp session_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "arb-client-test-session-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
