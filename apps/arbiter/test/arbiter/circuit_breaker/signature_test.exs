defmodule Arbiter.CircuitBreaker.SignatureTest do
  @moduledoc """
  Acceptance 3 of bd-5jr49o: signature normalisation must strip the volatile
  parts of a subject (counts, SHAs, timestamps, attempt numbers, durations,
  uuids) so a flood dedupes — while keeping the identifying parts (forge refs,
  task ids, repo slugs, reason atoms) so two genuinely different subjects never
  collide.
  """
  use ExUnit.Case, async: true

  alias Arbiter.CircuitBreaker.Signature

  defp norm(subject), do: Signature.normalize_subject(subject)

  describe "volatile fields do not defeat deduplication" do
    test "attempt / retry / round numbers collapse" do
      assert norm("auto-merge stalled after attempt 3") ==
               norm("auto-merge stalled after attempt 17")

      assert norm("dispatch failed (retry 1 of 5)") == norm("dispatch failed (retry 4 of 5)")
      assert norm("review round 2") == norm("review round 9")
    end

    test "counts collapse" do
      assert norm("303 watchdog retries pending") == norm("7 watchdog retries pending")
      assert norm("14 identical escalations") == norm("2 identical escalations")
    end

    test "commit shas collapse" do
      assert norm("unreviewed_head 7e827973a1b2c3d4e5f60718293a4b5c6d7e8f90") ==
               norm("unreviewed_head 273a05b8ffeeddccbbaa99887766554433221100")

      assert norm("head 7e82797") == norm("head 273a05b")
    end

    test "timestamps collapse" do
      assert norm("last seen 2026-09-13T04:12:59Z") == norm("last seen 2026-09-12T22:01:03Z")
      assert norm("last seen 2026-09-13 04:12:59") == norm("last seen 2026-09-12 22:01:03")
    end

    test "durations and elapsed times collapse" do
      assert norm("stalled for 75m") == norm("stalled for 12m")
      assert norm("probe timed out after 300000ms") == norm("probe timed out after 500ms")
      assert norm("idle 1.5h") == norm("idle 12.25h")
    end

    test "uuids collapse" do
      assert norm("run 550e8400-e29b-41d4-a716-446655440000 failed") ==
               norm("run 6ba7b810-9dad-11d1-80b4-00c04fd430c8 failed")
    end

    test "whitespace and case are normalised" do
      assert norm("Merge   Blocked\n— needs approval") == norm("merge blocked — needs approval")
    end
  end

  describe "genuinely different subjects do not collide" do
    test "different PR numbers stay distinct" do
      refute norm("follow-up for #1632") == norm("follow-up for #1630")
      refute norm("leo/verus_server#3282") == norm("leo/verus_server#3283")
    end

    test "different gitlab MR refs stay distinct" do
      refute norm("merge blocked !77") == norm("merge blocked !78")
    end

    test "different repos on the same PR number stay distinct" do
      refute norm("a/one#12") == norm("b/two#12")
    end

    test "different task ids stay distinct" do
      refute norm("bd-7rxwzc merge blocked") == norm("bd-brwx7w merge blocked")
    end

    test "different block reasons stay distinct" do
      refute norm("merge blocked — needs approval") == norm("merge blocked — ci failed")
    end
  end

  describe "structured subjects" do
    test "a list subject keeps each component distinct and order-sensitive" do
      assert norm(["repo/x", 12]) == norm(["repo/x", 12])
      refute norm(["repo/x", 12]) == norm(["repo/x", 13])
      refute norm(["repo/x", 12]) == norm([12, "repo/x"])
    end

    test "integers in a structured subject are identifying, not volatile" do
      refute norm(["pr", 3282]) == norm(["pr", 3283])
    end

    test "atoms and nil are stable components" do
      assert norm([:needs_approval, nil]) == norm([:needs_approval, nil])
      refute norm([:needs_approval]) == norm([:ci_failed])
    end

    test "free text inside a structured subject is still scrubbed" do
      assert norm(["pr", 3282, "attempt 4 at 2026-09-13T04:12:59Z"]) ==
               norm(["pr", 3282, "attempt 19 at 2026-09-12T01:02:03Z"])
    end

    # The escalation tells the operator to run `arb breaker reset '<signature>'`
    # and `arb breaker list` prints the same string. A control byte would be
    # invisible in a terminal and would not survive copy/paste (round 2,
    # finding 2), so every byte of a signature has to be printable.
    test "the component separator is printable, so the signature can be pasted into a shell" do
      sig =
        Signature.signature("ws-1", :preflight_auth_failed, ["bd-pfa001", :quota_exhausted])

      assert String.printable?(sig)
      assert sig == "ws-1|preflight_auth_failed|bd-pfa001 :: :quota_exhausted"
      refute String.contains?(sig, <<0x1F>>)
    end

    # Injectivity across the separator: a literal `::` inside a component is
    # collapsed by `scrub/1`, so it cannot be mistaken for a component boundary.
    test "a literal separator inside a component cannot forge a boundary" do
      refute norm(["a", "b::c"]) == norm(["a::b", "c"])
      assert norm(["a", "b::c"]) == norm(["a", "b:c"])
    end
  end

  # `:coordinator_escalation` keys on free-text escalation subject lines, and
  # `scrub/1` deliberately does not strip punctuation — so a subject like
  # "auto-merge didn't land" puts a literal apostrophe inside the signature.
  # Both operator-facing surfaces print it inside `'...'`, which that apostrophe
  # would otherwise terminate (round 2, observation 2).
  describe "shell_quote/1" do
    test "an apostrophe in the signature survives a real shell round-trip" do
      sig =
        Signature.signature("ws-1", :coordinator_escalation, ["bd-x1", "auto-merge didn't land"])

      assert String.contains?(sig, "'"), "fixture must actually exercise the apostrophe"

      # Hand the quoted word to a real shell and read back the single argument
      # it would pass to `arb` — the only assertion that proves runnability.
      {out, 0} =
        System.cmd("sh", ["-c", ~s|set -- #{Signature.shell_quote(sig)}; printf '%s' "$1"|])

      assert out == sig
    end

    test "quotes a plain signature as one word, and is idempotent under re-parse" do
      sig = Signature.signature("ws-1", :pr_patrol_follow_up, ["owner/repo", 4242])

      assert Signature.shell_quote(sig) == "'" <> sig <> "'"

      {out, 0} =
        System.cmd("sh", ["-c", ~s|set -- #{Signature.shell_quote(sig)}; printf '%s' "$#"|])

      assert out == "1"
    end

    test "shell metacharacters in a signature are inert once quoted" do
      sig = Signature.signature("ws-1", :coordinator_escalation, ["a'b|c $(id) `id` \\d"])

      {out, 0} =
        System.cmd("sh", ["-c", ~s|set -- #{Signature.shell_quote(sig)}; printf '%s' "$1"|])

      assert out == sig
    end
  end

  describe "signature/3" do
    test "is a readable, stable string scoped by workspace and kind" do
      sig = Signature.signature("ws-1", :pr_patrol_follow_up, ["repo/x", 12])
      assert sig == Signature.signature("ws-1", :pr_patrol_follow_up, ["repo/x", 12])
      assert sig =~ "ws-1"
      assert sig =~ "pr_patrol_follow_up"
      refute sig == Signature.signature("ws-2", :pr_patrol_follow_up, ["repo/x", 12])
      refute sig == Signature.signature("ws-1", :other_kind, ["repo/x", 12])
    end

    test "a nil workspace is its own scope rather than crashing" do
      assert is_binary(Signature.signature(nil, :k, "s"))
      refute Signature.signature(nil, :k, "s") == Signature.signature("ws-1", :k, "s")
    end

    test "an enormous subject is truncated but still discriminating" do
      long_a = String.duplicate("x", 5_000) <> " a"
      long_b = String.duplicate("x", 5_000) <> " b"
      assert byte_size(Signature.signature("ws", :k, long_a)) < 1_000
      refute Signature.signature("ws", :k, long_a) == Signature.signature("ws", :k, long_b)
    end
  end
end
