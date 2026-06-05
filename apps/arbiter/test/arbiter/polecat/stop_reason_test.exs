defmodule Arbiter.Polecat.StopReasonTest do
  use ExUnit.Case, async: true

  alias Arbiter.Polecat.StopReason

  describe "classify/2 — auth expiry (provider-agnostic)" do
    test "Claude 401 / invalid authentication credentials" do
      reason =
        StopReason.classify(1, [
          "starting",
          "API Error: 401 Invalid authentication credentials"
        ])

      assert reason.category == :auth_expired
      assert reason.exit_status == 1
      assert reason.remediation =~ "Re-authenticate"
    end

    test "OAuth-expiry phrasing" do
      reason = StopReason.classify(1, ["your session has expired, please log in"])
      assert reason.category == :auth_expired
    end

    test "Gemini API key not valid" do
      reason = StopReason.classify(1, ["error: API key not valid. Please pass a valid API key."])
      assert reason.category == :auth_expired
    end

    test "auth wins over a non-zero exit code (specific beats generic)" do
      # Exit 1 alone would be :crashed; the 401 signature refines it to auth.
      reason = StopReason.classify(1, ["401 unauthorized"])
      assert reason.category == :auth_expired
    end

    test "auth wins even on a clean (0) exit when the CLI printed the error" do
      reason = StopReason.classify(0, ["invalid authentication credentials"])
      assert reason.category == :auth_expired
    end
  end

  describe "classify/2 — credit / rate limit" do
    test "insufficient credit balance" do
      reason = StopReason.classify(1, ["Your credit balance is too low to run this request."])
      assert reason.category == :credit_exhausted
      assert reason.remediation =~ "Top up"
    end

    test "out of tokens / quota exceeded" do
      assert StopReason.classify(1, ["you are out of credits"]).category == :credit_exhausted

      assert StopReason.classify(1, ["quota exceeded for this project"]).category ==
               :credit_exhausted
    end

    test "429 / rate limited / overloaded" do
      assert StopReason.classify(1, ["HTTP 429 Too Many Requests"]).category == :rate_limited
      assert StopReason.classify(1, ["the API is currently overloaded"]).category == :rate_limited

      assert StopReason.classify(1, ["RESOURCE_EXHAUSTED: rate limit"]).category ==
               :rate_limited
    end

    test "auth outranks credit when both appear" do
      reason =
        StopReason.classify(1, ["401 invalid authentication credentials", "credit balance"])

      assert reason.category == :auth_expired
    end
  end

  describe "classify/2 — signals / crashes / clean exit" do
    test "128+N exit band maps to a kill signal" do
      # 137 = 128 + 9 (SIGKILL)
      reason = StopReason.classify(137, ["worker doing things"])
      assert reason.category == :killed
      assert reason.signal == 9
      assert reason.summary =~ "signal 9"
    end

    test "SIGTERM (143 = 128+15)" do
      reason = StopReason.classify(143, [])
      assert reason.category == :killed
      assert reason.signal == 15
    end

    test "plain non-zero exit with no signature is a crash" do
      reason = StopReason.classify(1, ["error: unknown option '--reasoning-effort'"])
      assert reason.category == :crashed
      assert reason.exit_status == 1
      assert reason.signal == nil
    end

    test "clean exit with no arb done is exited_without_done" do
      reason = StopReason.classify(0, ["did some work", "but never finished"])
      assert reason.category == :exited_without_done
      assert reason.exit_status == 0
    end

    test "nil exit (watchdog) is a stall" do
      reason = StopReason.classify(nil, ["thinking..."])
      assert reason.category == :stalled
      assert reason.exit_status == nil
    end
  end

  describe "label/1 and to_map/1" do
    test "label is a compact one-liner with the exit code" do
      assert StopReason.classify(1, ["401"]) |> StopReason.label() ==
               "credentials expired (exit 1)"

      assert StopReason.classify(137, []) |> StopReason.label() == "killed by signal 9 (exit 137)"
      assert StopReason.classify(nil, []) |> StopReason.label() == "stalled (no output)"
    end

    test "to_map is a plain serializable map" do
      map = StopReason.classify(1, ["401"]) |> StopReason.to_map()
      assert map.category == :auth_expired
      assert is_binary(map.summary)
      assert map.exit_status == 1
      refute Map.has_key?(map, :__struct__)
    end
  end
end
