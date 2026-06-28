defmodule Arbiter.Trackers.Linear.Error do
  @moduledoc """
  Normalised error returned by every `Arbiter.Trackers.Linear` callback on
  failure. Mirrors the shape of `Arbiter.Trackers.GitHub.Error` and
  `Arbiter.Trackers.Jira.Error`.

  ## Kinds

    * `:unauthenticated` — 401, token missing/rejected
    * `:forbidden` — 403, scope/permission issue
    * `:not_found` — issue doesn't exist
    * `:validation_failed` — GraphQL rejected the input
    * `:server_error` — 5xx
    * `:http` — any other HTTP error
    * `:network` — transport-level failure
    * `:graphql_error` — the request succeeded (HTTP 200) but Linear returned
      `errors` in the response body
    * `:transition_not_found` — the requested task status had no mapping to a
      Linear workflow state in the team's state list
    * `:config_missing` — workspace config is missing credentials or no active
      workspace is set
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
          | :graphql_error
          | :transition_not_found
          | :config_missing

  @type t :: %__MODULE__{
          kind: kind,
          status: nil | non_neg_integer(),
          message: String.t(),
          raw: any()
        }
end
