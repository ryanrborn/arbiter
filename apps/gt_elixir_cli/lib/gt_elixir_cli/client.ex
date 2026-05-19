defmodule GtElixirCli.Client do
  @moduledoc """
  Thin Req wrapper for talking to the gt_elixir_web REST API. Surfaces clean
  `{:ok, body}` / `{:error, %Error{}}` tuples so command modules don't deal
  with raw HTTP plumbing.

  Configuration:

    * `BD2_HOST` env var overrides the base URL (default `http://127.0.0.1:4000`)

  Tests can override the Req adapter via `:req_options` in the process dict:

      Process.put(:bd2_req_options, plug: {Req.Test, MyStub})
  """

  defmodule Error do
    @moduledoc """
    Normalised error returned by every Client function on failure.

    Kinds:
      * `:connection_refused` — Phoenix isn't running
      * `:timeout`
      * `:transport` — other transport-layer error (DNS, etc.)
      * `:http` — server returned a 4xx/5xx; `status` + `body` populated
      * `:decode` — server returned non-JSON
    """
    defstruct [:kind, :status, :body, :message, :hint]

    @type t :: %__MODULE__{
            kind: atom(),
            status: nil | integer(),
            body: any(),
            message: String.t(),
            hint: nil | String.t()
          }
  end

  @default_base "http://127.0.0.1:4000"

  @spec base_url() :: String.t()
  def base_url do
    System.get_env("BD2_HOST", @default_base)
  end

  @spec get(String.t(), keyword()) :: {:ok, any()} | {:error, Error.t()}
  def get(path, params \\ []), do: request(:get, path, params: params)

  @spec post(String.t(), map()) :: {:ok, any()} | {:error, Error.t()}
  def post(path, body), do: request(:post, path, json: body)

  @spec patch(String.t(), map()) :: {:ok, any()} | {:error, Error.t()}
  def patch(path, body), do: request(:patch, path, json: body)

  @spec delete(String.t(), keyword()) :: {:ok, any()} | {:error, Error.t()}
  def delete(path, params \\ []), do: request(:delete, path, params: params)

  defp request(method, path, opts) do
    url = base_url() <> path

    req_opts =
      [
        method: method,
        url: url,
        receive_timeout: 10_000,
        connect_options: [timeout: 5_000],
        retry: false
      ] ++ opts ++ test_opts()

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        {:ok, resp.body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, http_error(status, body)}

      {:error, %{reason: :econnrefused}} ->
        {:error,
         %Error{
           kind: :connection_refused,
           message: "could not connect to #{base_url()}",
           hint:
             "Phoenix app isn't running. Start it with `mix phx.server` from the umbrella root."
         }}

      {:error, %{reason: :timeout}} ->
        {:error, %Error{kind: :timeout, message: "request to #{url} timed out"}}

      {:error, %{reason: :nxdomain}} ->
        {:error,
         %Error{
           kind: :transport,
           message: "could not resolve host for #{url}",
           hint: "Check that BD2_HOST is set correctly."
         }}

      {:error, %{__exception__: true} = e} ->
        {:error, %Error{kind: :transport, message: Exception.message(e)}}

      {:error, other} ->
        {:error, %Error{kind: :transport, message: inspect(other)}}
    end
  end

  defp http_error(status, %{"error" => %{"message" => msg} = err}) do
    %Error{
      kind: :http,
      status: status,
      body: err,
      message: msg
    }
  end

  defp http_error(status, body) do
    %Error{
      kind: :http,
      status: status,
      body: body,
      message: "HTTP #{status}"
    }
  end

  # Test hook: a test can stuff Req options (e.g. `plug: {Req.Test, MyStub}`)
  # into the process dict to redirect requests to a stub.
  defp test_opts do
    Process.get(:bd2_req_options, [])
  end
end
