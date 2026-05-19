defmodule GtElixirCli.CliCase do
  @moduledoc """
  Test helpers for command-level testing.

  Sets up:
    * A `Req.Test` stub keyed by the test module's name
    * `:bd2_halt_strategy = :raise` so `Output.die/halt` raises instead of
      calling `System.halt/1`
    * IO capture helpers that also catch `GtElixirCli.Output.Halt`

  Usage:

      use GtElixirCli.CliCase

      test "show prints issue" do
        stub_get("/api/issues/foo-123", %{"id" => "foo-123", "title" => "T"})
        {out, _err, exit_code} = capture(fn ->
          GtElixirCli.Cmd.Show.run(["foo-123"])
        end)
        assert out =~ "foo-123"
        assert exit_code == 0
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import ExUnit.CaptureIO
      import GtElixirCli.CliCase

      setup do
        # Each test gets its own stub keyed by the test pid via the process dict.
        Process.put(:bd2_halt_strategy, :raise)

        stub_name = unique_stub_name()
        Process.put(:bd2_stub_name, stub_name)

        Process.put(:bd2_req_options,
          plug: {Req.Test, stub_name},
          retry: false
        )

        :ok
      end
    end
  end

  @doc "Generate a unique stub atom name for this test process."
  def unique_stub_name do
    pid_str = inspect(self()) |> String.replace(["#", "<", ">", ".", " "], "")

    String.to_atom(
      "Bd2Stub_" <> pid_str <> "_" <> Integer.to_string(System.unique_integer([:positive]))
    )
  end

  @doc """
  Stub a GET request. Matches by exact path.
  """
  def stub_get(path, response_body, status \\ 200) do
    stub_request(:get, path, response_body, status)
  end

  def stub_post(path, response_body, status \\ 201) do
    stub_request(:post, path, response_body, status)
  end

  def stub_patch(path, response_body, status \\ 200) do
    stub_request(:patch, path, response_body, status)
  end

  def stub_delete(path, response_body \\ "", status \\ 204) do
    stub_request(:delete, path, response_body, status)
  end

  def stub_request(method, path, body, status) do
    name = Process.get(:bd2_stub_name)
    method_str = method |> to_string() |> String.upcase()

    Req.Test.stub(name, fn conn ->
      cond do
        to_string(conn.method) != method_str ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "method mismatch"})

        conn.request_path != path ->
          conn
          |> Plug.Conn.put_status(500)
          |> Req.Test.json(%{error: "path mismatch: #{conn.request_path} vs #{path}"})

        true ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
    end)
  end

  @doc """
  Stub multiple requests, dispatched by `{method, path}`. The first matching
  entry wins; unmatched requests return 500. Each entry can be a 2-tuple
  `{body, status}` or a function `(conn -> conn)`.
  """
  def stub_routes(routes) when is_list(routes) do
    name = Process.get(:bd2_stub_name)

    Req.Test.stub(name, fn conn ->
      key = {String.downcase(to_string(conn.method)), conn.request_path}

      case Enum.find(routes, fn {k, _} -> k == key end) do
        {_, fun} when is_function(fun, 1) ->
          fun.(conn)

        {_, {body, status}} ->
          conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

        nil ->
          conn
          |> Plug.Conn.put_status(500)
          |> Req.Test.json(%{error: "unmatched: #{inspect(key)}"})
      end
    end)
  end

  @doc """
  Stubs a transport error for any request matching the method+path.
  """
  def stub_transport_error(method, path, reason) do
    name = Process.get(:bd2_stub_name)
    method_str = method |> to_string() |> String.upcase()

    Req.Test.stub(name, fn conn ->
      if to_string(conn.method) == method_str and conn.request_path == path do
        Req.Test.transport_error(conn, reason)
      else
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "unmatched"})
      end
    end)
  end

  @doc """
  Run `fun`, capturing stdout, stderr, and exit code. Returns
  `{stdout, stderr, exit_code}`. `exit_code` is 0 if `fun` returned normally,
  otherwise it's the code passed to `Output.halt/die`.
  """
  def capture(fun) do
    parent = self()

    stdout =
      ExUnit.CaptureIO.capture_io(fn ->
        stderr =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            try do
              fun.()
              send(parent, {:bd2_exit, 0})
            rescue
              e in GtElixirCli.Output.Halt ->
                send(parent, {:bd2_exit, e.code})
            end
          end)

        send(parent, {:bd2_stderr, stderr})
      end)

    stderr =
      receive do
        {:bd2_stderr, s} -> s
      after
        100 -> ""
      end

    exit_code =
      receive do
        {:bd2_exit, code} -> code
      after
        100 -> 0
      end

    {stdout, stderr, exit_code}
  end
end
