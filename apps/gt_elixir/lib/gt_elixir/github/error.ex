defmodule GtElixir.GitHub.Error do
  @moduledoc """
  Normalised error returned by every `GtElixir.GitHub` function on failure.

  ## Kinds

    * `:unauthenticated` — 401, token missing or rejected
    * `:forbidden` — 403, token lacks scope or rate-limit hit
    * `:not_found` — 404, repo / PR / thread doesn't exist
    * `:validation_failed` — 422, GitHub rejected the request body, or a
      GraphQL response came back shaped wrong / with `errors`
    * `:server_error` — 5xx
    * `:http` — any other 4xx not covered above
    * `:network` — transport-level failure (timeout, DNS, connection refused)

  `status` is `nil` for transport errors. `message` is a short string for
  logs / display; `raw` is the original payload (parsed body, exception, etc.)
  for callers that need full detail.
  """

  defstruct [:kind, :status, :message, :raw]

  @type kind ::
          :unauthenticated
          | :forbidden
          | :not_found
          | :validation_failed
          | :server_error
          | :http
          | :network

  @type t :: %__MODULE__{
          kind: kind,
          status: nil | non_neg_integer(),
          message: String.t(),
          raw: any()
        }
end
