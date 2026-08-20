defmodule Arbiter.Http.Error do
  @moduledoc """
  How one provider turns an HTTP failure into its own `Error` struct.

  Every tracker/merger adapter defines its own `Error` module, but all seven
  build it the same way: `kind` from the status (sometimes the body too),
  `message` from a provider-specific field of the body, `raw` as the body, and
  — for GitHub — a `retry_after_ms` rate-limit hint. This struct captures just
  those provider-specific pieces so `Arbiter.Http.Client` can own the
  mechanics.

  It carries no request state, so a provider can hold one at module level and
  classify a response without re-resolving its config.
  """

  @enforce_keys [:module, :classify_kind, :error_message]
  defstruct [:module, :classify_kind, :error_message, :retry_after_ms]

  @type t :: %__MODULE__{
          module: module(),
          classify_kind: (integer(), term() -> atom()),
          error_message: (term(), integer() -> String.t()),
          retry_after_ms: (integer(), Req.Response.t() | nil -> pos_integer() | nil) | nil
        }

  @doc """
  Builds a spec.

    * `:module` — the provider's `Error` struct module.
    * `:classify_kind` — `(status, body -> kind)`.
    * `:error_message` — `(body, status -> String.t())`.
    * `:retry_after_ms` — optional `(status, resp | nil -> pos_integer | nil)`;
      set only by the two GitHub adapters, whose `Error` structs have the field.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts), do: struct!(__MODULE__, opts)

  @doc "Builds the provider error struct for a non-2xx response."
  @spec build(t(), integer(), term(), Req.Response.t() | nil) :: struct()
  def build(%__MODULE__{} = spec, status, body, resp \\ nil) do
    fields = [
      kind: spec.classify_kind.(status, body),
      status: status,
      message: spec.error_message.(body, status),
      raw: body
    ]

    fields =
      case spec.retry_after_ms do
        nil -> fields
        fun when is_function(fun, 2) -> Keyword.put(fields, :retry_after_ms, fun.(status, resp))
      end

    struct!(spec.module, fields)
  end

  @doc "Builds the provider's `:network` error for a transport-level failure."
  @spec transport(t(), term()) :: struct()
  def transport(%__MODULE__{module: module}, exception), do: transport(module, exception)

  def transport(module, %{reason: reason} = exception) when is_atom(module) do
    struct!(module,
      kind: :network,
      status: nil,
      message:
        case exception do
          %{__exception__: true} -> Exception.message(exception)
          _ -> inspect(reason)
        end,
      raw: exception
    )
  end

  def transport(module, other) when is_atom(module) do
    struct!(module, kind: :network, status: nil, message: inspect(other), raw: other)
  end
end
