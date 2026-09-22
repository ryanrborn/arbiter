defmodule ArbiterWeb.Api.CoverageShadowJSON do
  @moduledoc false

  def preflip_gate(%{gate: gate}) do
    %{
      data: %{
        merges: gate.merges,
        agreements: gate.agreements,
        blocking: gate.blocking,
        blocking_observations: gate.blocking_observations,
        deferred: gate.deferred,
        deferred_observations: gate.deferred_observations,
        min_merges: gate.min_merges,
        truncated?: gate.truncated?,
        pass?: gate.pass?,
        reason: gate.reason
      }
    }
  end
end
