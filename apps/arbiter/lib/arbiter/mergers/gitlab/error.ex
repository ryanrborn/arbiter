defmodule Arbiter.Mergers.Gitlab.Error do
  @moduledoc """
  Normalised error returned by every `Arbiter.Mergers.Gitlab` function on
  failure. Mirrors `Arbiter.Trackers.Jira.Error` for consistency across
  adapters.

  ## Kinds

    * `:unauthenticated` — 401, token missing/rejected
    * `:forbidden` — 403, scope/permission issue
    * `:not_found` — 404, project or merge request doesn't exist
    * `:validation_failed` — 400/422, GitLab rejected the body
    * `:conflict` — 405/406/409, the merge request can't be merged in its
      current state (conflicts, unresolved discussions, not approved, …)
    * `:server_error` — 5xx
    * `:http` — any other 4xx not covered above
    * `:network` — transport-level failure
    * `:config_missing` — workspace config is missing host / project_id /
      credentials, or no active workspace is set
    * `:bad_ref` — an `mr_ref` could not be parsed into an iid
    * `:git_push_failed` — local `git push` failed before MR creation
  """

  defstruct [:kind, :status, :message, :raw]

  @type kind ::
          :unauthenticated
          | :forbidden
          | :not_found
          | :validation_failed
          | :conflict
          | :server_error
          | :http
          | :network
          | :config_missing
          | :bad_ref
          | :git_push_failed

  @type t :: %__MODULE__{
          kind: kind,
          status: nil | non_neg_integer(),
          message: String.t(),
          raw: any()
        }
end
