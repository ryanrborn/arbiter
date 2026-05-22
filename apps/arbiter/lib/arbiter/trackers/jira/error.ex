defmodule Arbiter.Trackers.Jira.Error do
  @moduledoc """
  Normalised error returned by every `Arbiter.Trackers.Jira` function on
  failure. Mirrors the shape of `Arbiter.GitHub.Error` for consistency.

  ## Kinds

    * `:unauthenticated` — 401, token missing/rejected
    * `:forbidden` — 403, scope/permission issue
    * `:not_found` — 404, issue/transition doesn't exist
    * `:validation_failed` — 400/422, Jira rejected the body
    * `:server_error` — 5xx
    * `:http` — any other 4xx not covered above
    * `:network` — transport-level failure
    * `:transition_not_found` — the requested bead status had no mapping to
      a Jira transition available in the issue's current state
    * `:config_missing` — workspace config is missing host / project_key /
      credentials, or no active workspace is set
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
          | :transition_not_found
          | :config_missing

  @type t :: %__MODULE__{
          kind: kind,
          status: nil | non_neg_integer(),
          message: String.t(),
          raw: any()
        }
end
