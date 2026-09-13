defmodule Arbiter.Boot.Time do
  @moduledoc """
  When this BEAM node started (bd-9so315).

  Post-merge verification needs to tell the coordinator whether the *running*
  server predates the merge — i.e. whether the merged code is even loaded yet,
  or whether a restart has to come first. There is no deploy record to read, so
  we derive it from the VM's own wall-clock statistic, which counts
  milliseconds since the node came up.

  Tests (and anything else that needs to pin the answer) can override it with
  `Application.put_env(:arbiter, :boot_time_override, %DateTime{})`.
  """

  @doc "UTC timestamp of this node's start."
  @spec booted_at() :: DateTime.t()
  def booted_at do
    case Application.get_env(:arbiter, :boot_time_override) do
      %DateTime{} = dt ->
        dt

      _ ->
        {total_ms, _since_last_call} = :erlang.statistics(:wall_clock)
        DateTime.add(DateTime.utc_now(), -total_ms, :millisecond)
    end
  end

  @doc """
  True when the running node started before `at` — so whatever landed at `at`
  is not in this process's loaded code and a restart is required to observe it.
  """
  @spec predates?(DateTime.t()) :: boolean()
  def predates?(%DateTime{} = at), do: DateTime.compare(booted_at(), at) == :lt
end
