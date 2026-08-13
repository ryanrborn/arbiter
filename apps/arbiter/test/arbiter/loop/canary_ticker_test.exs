defmodule Arbiter.Loop.CanaryTickerTest do
  @moduledoc """
  Stage 3 (bd-6edc0u): the driver.

  Auto-revert is only *auto* if something judges the canary without an
  operator. These tests pin the two things that makes true: the ticker walks
  every workspace on its own, and it is a complete no-op on the ones that have
  not opted in.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.{Canary, CanaryTicker}
  alias Arbiter.Tasks.Workspace

  @routing_config %{
    "agent" => %{"type" => "claude", "config" => %{}},
    "routing" => %{"policy" => "by_difficulty"}
  }

  @rule %{"model_tier" => "premium", "thinking" => "high"}

  defp workspace!(name, extra_config \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: name,
        prefix: String.slice(name, 0, 2),
        config: Map.merge(@routing_config, extra_config)
      })

    ws
  end

  defp proposal!(ws) do
    {:ok, row} =
      Loop.record(%{
        kind: :config_set,
        gist: "raise D2 to premium/high",
        category: "difficulty misestimate — D2 under-provisioned",
        target: "routing.rules.D2",
        difficulty: 2,
        scope: :fleet,
        incident_refs: ["r1", "r2", "r3"],
        task_refs: ["bd-1", "bd-2"],
        payload: %{
          "workspace_id" => ws.id,
          "patch" => %{"routing" => %{"rules" => %{"D2" => @rule}}}
        },
        origin: "loop.analyze",
        workspace_id: ws.id
      })

    row
  end

  defp reload!(ws), do: Ash.get!(Workspace, ws.id)

  describe "poll/1" do
    test "starts a canary on an opted-in workspace with an eligible proposal" do
      ws = workspace!("ticker-on", %{"loop" => %{"autonomous_routing_enabled" => true}})
      row = proposal!(ws)

      assert :ok = CanaryTicker.poll(start_ticker!())

      assert %Canary{proposal_id: id} = Canary.active(reload!(ws))
      assert id == row.id
    end

    test "is a no-op on every workspace that has not opted in" do
      ws = workspace!("ticker-off")
      _row = proposal!(ws)

      before = reload!(ws).config

      assert :ok = CanaryTicker.poll(start_ticker!())

      assert reload!(ws).config == before,
             "with the flag unset the ticker must not touch the workspace at all"

      refute Canary.active(reload!(ws))
    end

    test "one workspace's failure does not stop the rest of the cycle" do
      broken = workspace!("ticker-broken", %{"loop" => %{"autonomous_routing_enabled" => true}})
      healthy = workspace!("ticker-healthy", %{"loop" => %{"autonomous_routing_enabled" => true}})

      # A canary block that cannot be parsed: `active/1` reads it as no canary,
      # and the cycle must carry on to the next workspace regardless.
      {:ok, broken} =
        Ash.update(broken, %{patch: %{"loop" => %{"canary" => %{"status" => "nonsense"}}}},
          action: :patch_config,
          actor: "test"
        )

      proposal!(healthy)

      assert :ok = CanaryTicker.poll(start_ticker!())

      assert Canary.active(reload!(healthy))
      refute Canary.active(reload!(broken))
    end
  end

  describe "the timer" do
    test "does not schedule itself when disabled" do
      pid = start_ticker!()
      assert :sys.get_state(pid).enabled == false
      refute_receive :tick, 50
    end
  end

  defp start_ticker!, do: start_supervised!({CanaryTicker, name: nil, enabled: false})
end
