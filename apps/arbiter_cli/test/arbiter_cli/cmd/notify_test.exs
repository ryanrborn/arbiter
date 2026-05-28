defmodule ArbiterCli.Cmd.NotifyTest do
  use ArbiterCli.CliCase, async: false

  describe "arb notify" do
    test "lists recent notifications" do
      stub_get(
        "/api/messages",
        %{
          "data" => [
            %{
              "id" => "n-1",
              "kind" => "notification",
              "from_ref" => "bd-7",
              "subject" => "bd-7 complete",
              "body" => "bd-7 finished its workflow.",
              "inserted_at" => "2026-05-27T00:00:00Z"
            }
          ]
        },
        200
      )

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Notify.run([]) end)
      assert code == 0
      assert out =~ "Recent notifications (1)"
      assert out =~ "bd-7 complete"
      assert out =~ "bd-7"
    end

    test "prints friendly message when empty" do
      stub_get("/api/messages", %{"data" => []}, 200)
      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Notify.run([]) end)
      assert code == 0
      assert out =~ "(no notifications)"
    end

    test "--json emits JSON" do
      stub_get("/api/messages", %{"data" => [%{"id" => "n-1", "kind" => "notification"}]}, 200)
      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Notify.run(["--json"]) end)
      assert code == 0
      assert {:ok, %{"data" => [%{"id" => "n-1"}]}} = Jason.decode(out)
    end
  end
end
