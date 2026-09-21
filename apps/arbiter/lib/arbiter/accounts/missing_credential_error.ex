defmodule Arbiter.Accounts.MissingCredentialError do
  @moduledoc """
  Raised when `:provider_accounts_enabled` is on but the workspace a spawn is
  for has no account credential to supply a provider credential the workspace
  demonstrably still needs (P3 / bd-aiodva, `docs/provider-account-design.md`
  §7.5 "Release N+1").

  This is the acceptance-3 guarantee of the read flip: the failure mode the
  flip must never have is a *silent* one — a worker dispatched with no token,
  which authenticates as nobody, 401s several minutes in and burns a run
  before anyone notices. The flip fails loudly at the point the credential is
  resolved instead.

  It fires only when the credential would actually be lost: the workspace's
  `worker_env` blob (or, for `ConfigDir.oauth_token/1`, the pre-P3 precedence
  chain as a whole) still answers with a token, and the account tables do not.
  A workspace that never had a provider credential resolves to "no credential"
  exactly as it did pre-P3 and never raises — nothing is being taken away.

  The two fixes, both cheap:

    * run `mix arbiter.accounts.migrate` for the workspace, so the credential
      it already holds becomes an account row; or
    * set `:provider_accounts_enabled` back to `false` — §7.5's rollback for
      this release is the flag, and the blob is still there and still correct.
  """

  defexception [:workspace_id, :env_vars, :message]

  @type t :: %__MODULE__{
          workspace_id: String.t() | nil,
          env_vars: [String.t()],
          message: String.t()
        }

  @impl true
  def exception(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    env_vars = opts |> Keyword.get(:env_vars, []) |> List.wrap()

    %__MODULE__{
      workspace_id: workspace_id,
      env_vars: env_vars,
      message: build_message(workspace_id, env_vars)
    }
  end

  defp build_message(workspace_id, env_vars) do
    "provider accounts are enabled (:provider_accounts_enabled) but workspace " <>
      "#{workspace_id || "(unknown)"} has no active provider account credential for " <>
      "#{vars(env_vars)}, while its worker_env still supplies one. Dispatching would " <>
      "hand the worker no credential at all. Run `mix arbiter.accounts.migrate` for " <>
      "this workspace, or set :provider_accounts_enabled to false to roll the read " <>
      "flip back (docs/provider-account-design.md §7.5)."
  end

  defp vars([]), do: "its provider credential"
  defp vars(env_vars), do: Enum.join(env_vars, ", ")
end
