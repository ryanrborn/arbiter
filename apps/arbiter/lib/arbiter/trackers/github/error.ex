defmodule Arbiter.Trackers.GitHub.Error do
  @moduledoc """
  Normalised error returned by every `Arbiter.Trackers.GitHub` callback on
  failure. Mirrors the shape of `Arbiter.Trackers.Jira.Error`,
  `Arbiter.Mergers.Github.Error`, and `Arbiter.GitHub.Error` for consistency.

  ## Kinds

    * `:unauthenticated` — 401, token missing/rejected
    * `:forbidden` — 403, scope/permission issue or rate-limit hit
    * `:not_found` — 404, issue/repo doesn't exist
    * `:validation_failed` — 400/422, GitHub rejected the body (or a response
      came back shaped wrong)
    * `:server_error` — 5xx
    * `:http` — any other 4xx not covered above
    * `:network` — transport-level failure
    * `:transition_not_found` — the requested task status had no mapping to a
      GitHub state/label in the workspace's `status_map`
    * `:config_missing` — workspace config is missing owner / repo /
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
