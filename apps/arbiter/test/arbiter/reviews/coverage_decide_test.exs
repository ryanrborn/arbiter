defmodule Arbiter.Reviews.CoverageDecideTest do
  @moduledoc """
  P2 of `docs/review-coverage-and-guard-policy.md` (design #1635): §3.2's
  six-rule predicate, plus one table-driven case per §4 walkthrough.

  Every case here is a pure-function call — no git, no forge, no repo. Git and
  forge access is injected through `ctx`, which is the whole point of the
  shape: the rules that decide whether unreviewed code may merge are testable
  without a checkout.
  """
  use Arbiter.DataCase, async: true

  use ExUnitProperties

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Reviews.Coverage.Entry

  # The reviewed content (§4.2's `A`).
  @diff_a """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..2222222 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,3 +1,4 @@
   defmodule A do
  +  def hello, do: :world
   end
  """

  # The same net contribution after a base merge moved the file under it: new
  # blob hashes, shifted hunk header, identical content. §4.2's `M`.
  @diff_a_after_base_merge """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,3 +41,4 @@ defmodule A do
   defmodule A do
  +  def hello, do: :world
   end
  """

  # Authored content (§4.1's `B`, §4.5's `S3`).
  @diff_b """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..5555555 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,3 +1,4 @@
   defmodule A do
  +  def hello, do: :universe
   end
  """

  @fp_a NetDiff.fingerprint(@diff_a)
  @fp_b NetDiff.fingerprint(@diff_b)

  # A deterministic, *valid* 40-hex sha per short name, so the rows these
  # tests build are ones `Coverage.record/1` would actually accept.
  defp sha(seed), do: Base.encode16(:crypto.hash(:sha, seed), case: :lower)

  defp entry(overrides \\ %{}) do
    struct!(
      Entry,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          task_id: "bd-6woz0x",
          mr_ref: "ryanrborn/arbiter#1631",
          head_sha: sha("a"),
          base_ref: "main",
          net_diff_id: @fp_a,
          kind: :reviewed,
          source: :review_gate,
          round: nil,
          derived_from: nil,
          covered_at: ~U[2026-01-01 00:00:00.000000Z]
        },
        Map.new(overrides)
      )
    )
  end

  # A ctx whose diff fetch succeeds and returns content nobody has reviewed, so
  # rules 3 and 4 both miss unless a case says otherwise.
  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        local_head_sha: nil,
        base_ref: "main",
        ancestor?: fn _ancestor, _descendant -> false end,
        fetch_diff: fn _base, _head -> {:ok, @diff_b} end,
        source: :watchdog
      },
      Map.new(overrides)
    )
  end

  describe "rule 0 — no head" do
    test "a nil head is unknown, never uncovered" do
      assert Coverage.decide([entry()], nil, ctx()) == {:unknown, :no_head}
      assert Coverage.decide([], nil, ctx()) == {:unknown, :no_head}
    end
  end

  describe "rule 1 — head is covered" do
    test "an exact head match is covered, whatever the kind" do
      for kind <- [:reviewed, :mechanical, :operator] do
        derived_from = if kind == :mechanical, do: Ecto.UUID.generate()
        coverage = [entry(%{head_sha: sha("a"), kind: kind, derived_from: derived_from})]

        assert Coverage.decide(coverage, sha("a"), ctx()) == {:covered, sha("a")}
      end
    end

    test "rule 1 needs no ctx at all — no git, no forge" do
      assert Coverage.decide([entry(%{head_sha: sha("a")})], sha("a"), %{}) ==
               {:covered, sha("a")}
    end

    test "rule 1 records nothing" do
      assert Coverage.decide_with_record([entry(%{head_sha: sha("a")})], sha("a"), ctx()) ==
               {{:covered, sha("a")}, nil}
    end
  end

  describe "rule 2 — the forge is lagging our own push" do
    test "covered local head, different head, head is an ancestor => forge_lagging" do
      # §4.3: round 2 approved S2, the worker pushed it, the forge still says S1.
      coverage = [entry(%{head_sha: sha("s2")})]

      ctx =
        ctx(%{
          local_head_sha: sha("s2"),
          ancestor?: fn ancestor, descendant ->
            ancestor == sha("s1") and descendant == sha("s2")
          end
        })

      assert Coverage.decide(coverage, sha("s1"), ctx) == {:unknown, :forge_lagging}
    end

    test "ancestry is required, not mere inequality — an unrelated head is not forge_lagging" do
      coverage = [entry(%{head_sha: sha("s2")})]

      ctx =
        ctx(%{
          local_head_sha: sha("s2"),
          # Nothing is an ancestor of anything: the head is off on its own branch.
          ancestor?: fn _ancestor, _descendant -> false end
        })

      assert Coverage.decide(coverage, sha("unrelated"), ctx) == {:uncovered, :authored_content}
    end

    test "a descendant of our covered head is not forge_lagging — the rule is one-directional" do
      # §4.5: S3 is a CI fix-pass commit *on top of* the covered S2.
      coverage = [entry(%{head_sha: sha("s2")})]

      ctx =
        ctx(%{
          local_head_sha: sha("s2"),
          ancestor?: fn ancestor, descendant ->
            # S2 is an ancestor of S3, never the other way round.
            ancestor == sha("s2") and descendant == sha("s3")
          end
        })

      assert Coverage.decide(coverage, sha("s3"), ctx) == {:uncovered, :authored_content}
    end

    test "an uncovered local head cannot lend coverage to an ancestor" do
      coverage = [entry(%{head_sha: sha("a")})]

      ctx =
        ctx(%{
          local_head_sha: sha("s2"),
          ancestor?: fn _ancestor, _descendant -> true end
        })

      assert Coverage.decide(coverage, sha("s1"), ctx) == {:uncovered, :authored_content}
    end

    test "head == local head falls through instead of claiming a lag" do
      coverage = [entry(%{head_sha: sha("other")})]

      ctx =
        ctx(%{
          local_head_sha: sha("s2"),
          ancestor?: fn _ancestor, _descendant -> true end
        })

      assert Coverage.decide(coverage, sha("s2"), ctx) == {:uncovered, :authored_content}
    end

    # P4 (bd-df3zlo / #1736), AC4. A probe that is *present* and cannot answer
    # is not the same thing as a probe that answers "no": the first leaves the
    # forge-lag question open, and the rule-3/4 fall-through would then decide a
    # merge on a head whose provenance we could not establish. So an unavailable
    # probe stops at rule 2 with its own `unknown` reason — a pause, never a
    # merge and never a re-review.
    test "an ancestry probe that cannot answer yields unknown, not a fall-through" do
      coverage = [entry(%{head_sha: sha("s2")})]

      for probe <- [
            fn _a, _d -> {:error, :not_a_git_repo} end,
            fn _a, _d -> :error end,
            fn _a, _d -> raise "git exploded" end,
            fn _a, _d -> :yes end
          ] do
        ctx = ctx(%{local_head_sha: sha("s2"), ancestor?: probe})

        assert Coverage.decide(coverage, sha("s1"), ctx) == {:unknown, :ancestry_unavailable}
      end
    end

    test "an unavailable probe never buys a rule-3 `covered`" do
      # The head's net diff matches a reviewed row, so rule 3 would answer
      # `covered` — but rule 2 was asked first and could not answer, and AC4
      # says a probe failure yields `unknown` and never `covered`.
      coverage = [entry(%{head_sha: sha("s2"), net_diff_id: @fp_a})]

      ctx =
        ctx(%{
          local_head_sha: sha("s2"),
          ancestor?: fn _a, _d -> {:error, :timeout} end,
          fetch_diff: fn _base, _head -> {:ok, @diff_a_after_base_merge} end
        })

      assert Coverage.decide_with_record(coverage, sha("s1"), ctx) ==
               {{:unknown, :ancestry_unavailable}, nil}
    end

    test "an absent probe is still an unreachable rule 2, not an unavailable one" do
      # A ctx that supplies no probe at all has declared it cannot ask — the
      # P3 shape, and the one every non-merge caller uses. That falls through
      # to the content rules exactly as before; only a probe that was asked and
      # failed is an `:ancestry_unavailable`.
      coverage = [entry(%{head_sha: sha("s2")})]
      ctx = Map.delete(ctx(%{local_head_sha: sha("s2")}), :ancestor?)

      assert Coverage.decide(coverage, sha("s1"), ctx) == {:uncovered, :authored_content}
    end

    test "an ancestry probe may answer {:ok, boolean}" do
      coverage = [entry(%{head_sha: sha("s2")})]
      ctx = ctx(%{local_head_sha: sha("s2"), ancestor?: fn _a, _d -> {:ok, true} end})

      assert Coverage.decide(coverage, sha("s1"), ctx) == {:unknown, :forge_lagging}
    end

    test "rule 2 records nothing" do
      coverage = [entry(%{head_sha: sha("s2")})]
      ctx = ctx(%{local_head_sha: sha("s2"), ancestor?: fn _a, _d -> true end})

      assert Coverage.decide_with_record(coverage, sha("s1"), ctx) ==
               {{:unknown, :forge_lagging}, nil}
    end
  end

  describe "rule 3 — the net diff is already covered" do
    test "an identical fingerprint at a new head is covered" do
      coverage = [entry(%{head_sha: sha("a"), net_diff_id: @fp_a})]
      ctx = ctx(%{fetch_diff: fn _base, _head -> {:ok, @diff_a_after_base_merge} end})

      assert Coverage.decide(coverage, sha("m"), ctx) == {:covered, sha("m")}
    end

    test "the match returns a :mechanical row to record, and writes nothing" do
      covered = entry(%{head_sha: sha("a"), net_diff_id: @fp_a, round: 2})

      ctx =
        ctx(%{
          fetch_diff: fn _base, _head -> {:ok, @diff_a_after_base_merge} end,
          source: :watchdog
        })

      assert {{:covered, head}, record} = Coverage.decide_with_record([covered], sha("m"), ctx)
      assert head == sha("m")

      assert record == %{
               task_id: covered.task_id,
               mr_ref: covered.mr_ref,
               head_sha: sha("m"),
               base_ref: "main",
               net_diff_id: @fp_a,
               kind: :mechanical,
               source: :watchdog,
               derived_from: covered.id
             }

      # Pure: the caller records it, not us.
      assert Ash.read!(Entry) == []
    end

    test "the returned row is exactly what Coverage.record/1 accepts" do
      # The parent is a real persisted row here, so `derived_from` is a live
      # foreign key rather than a struct this test made up.
      {:ok, covered} =
        Coverage.record(%{
          task_id: "bd-6woz0x",
          mr_ref: "ryanrborn/arbiter#1631",
          head_sha: sha("a"),
          base_ref: "main",
          net_diff_id: @fp_a,
          kind: :reviewed,
          source: :review_gate
        })

      ctx = ctx(%{fetch_diff: fn _base, _head -> {:ok, @diff_a_after_base_merge} end})

      {_decision, record} = Coverage.decide_with_record([covered], sha("m"), ctx)

      assert {:ok, written} = Coverage.record(record)
      assert written.kind == :mechanical
      assert written.derived_from == covered.id
      assert written.head_sha == sha("m")
    end

    test "derived_from names the oldest matching row, so the chain points at the review" do
      original =
        entry(%{
          head_sha: sha("a"),
          net_diff_id: @fp_a,
          # Later day-of-month than `later`, deliberately: a `DateTime`-struct
          # sort key compares map keys alphabetically, so `day` outranks
          # `month` and `year`. These two dates are the minimal fixture that
          # tells real chronology apart from that ordering.
          covered_at: ~U[2026-01-02 00:00:00.000000Z]
        })

      later =
        entry(%{
          head_sha: sha("m1"),
          net_diff_id: @fp_a,
          kind: :mechanical,
          derived_from: original.id,
          covered_at: ~U[2026-02-01 00:00:00.000000Z]
        })

      ctx = ctx(%{fetch_diff: fn _base, _head -> {:ok, @diff_a_after_base_merge} end})

      for coverage <- [[original, later], [later, original]] do
        assert {{:covered, _}, record} = Coverage.decide_with_record(coverage, sha("m2"), ctx)
        assert record.derived_from == original.id
      end
    end

    test "a content-changing push never matches rule 3" do
      coverage = [entry(%{head_sha: sha("a"), net_diff_id: @fp_a})]
      ctx = ctx(%{fetch_diff: fn _base, _head -> {:ok, @diff_b} end})

      assert @fp_a != @fp_b
      assert Coverage.decide(coverage, sha("b"), ctx) == {:uncovered, :authored_content}
    end

    test "a diff that fingerprints to nil is never a match" do
      # NetDiff returns nil for an empty/whitespace diff; nil must not compare
      # equal to a coverage row that also failed to fingerprint.
      coverage = [entry(%{head_sha: sha("a"), net_diff_id: nil})]
      ctx = ctx(%{fetch_diff: fn _base, _head -> {:ok, "   \n\n"} end})

      assert Coverage.decide(coverage, sha("b"), ctx) == {:unknown, :diff_unavailable}
    end

    test "the fetcher may answer with a bare diff string" do
      coverage = [entry(%{head_sha: sha("a"), net_diff_id: @fp_a})]
      ctx = ctx(%{fetch_diff: fn _base, _head -> @diff_a_after_base_merge end})

      assert Coverage.decide(coverage, sha("m"), ctx) == {:covered, sha("m")}
    end

    test "the fetcher is called with the ctx base_ref and the head under test" do
      test_pid = self()
      coverage = [entry(%{head_sha: sha("a"), net_diff_id: @fp_a})]

      ctx =
        ctx(%{
          base_ref: "release/1.0",
          fetch_diff: fn base, head ->
            send(test_pid, {:fetched, base, head})
            {:ok, @diff_a_after_base_merge}
          end
        })

      assert Coverage.decide(coverage, sha("m"), ctx) == {:covered, sha("m")}
      assert_received {:fetched, "release/1.0", head}
      assert head == sha("m")
    end

    test "the recorded row carries the ctx base_ref, not the covered row's" do
      covered = entry(%{head_sha: sha("a"), net_diff_id: @fp_a, base_ref: "main"})

      ctx =
        ctx(%{
          base_ref: "release/1.0",
          fetch_diff: fn _base, _head -> {:ok, @diff_a_after_base_merge} end
        })

      assert {_, record} = Coverage.decide_with_record([covered], sha("m"), ctx)
      assert record.base_ref == "release/1.0"
    end
  end

  describe "rule 4 — we could not tell" do
    test "no base_ref is unknown, not uncovered" do
      coverage = [entry(%{head_sha: sha("a")})]

      for base_ref <- [nil, "", "   "] do
        ctx = ctx(%{base_ref: base_ref})

        assert Coverage.decide(coverage, sha("b"), ctx) == {:unknown, :no_base_ref}
      end
    end

    test "a failed diff fetch is unknown, not uncovered — a forge blip is not a re-review" do
      coverage = [entry(%{head_sha: sha("a")})]

      for fetcher <- [
            fn _b, _h -> {:error, :timeout} end,
            fn _b, _h -> :error end,
            fn _b, _h -> {:ok, nil} end,
            fn _b, _h -> nil end,
            fn _b, _h -> raise "forge exploded" end
          ] do
        ctx = ctx(%{fetch_diff: fetcher})

        assert Coverage.decide(coverage, sha("b"), ctx) == {:unknown, :diff_unavailable}
      end
    end

    test "no fetcher at all is diff_unavailable" do
      coverage = [entry(%{head_sha: sha("a")})]

      assert Coverage.decide(coverage, sha("b"), %{base_ref: "main"}) ==
               {:unknown, :diff_unavailable}
    end

    test "rule 4 records nothing" do
      coverage = [entry(%{head_sha: sha("a")})]

      assert Coverage.decide_with_record(coverage, sha("b"), ctx(%{base_ref: nil})) ==
               {{:unknown, :no_base_ref}, nil}
    end
  end

  describe "rule 5 — no coverage at all" do
    test "an empty coverage set is uncovered for the honest reason" do
      assert Coverage.decide([], sha("b"), ctx()) == {:uncovered, :no_coverage}
    end
  end

  describe "rule 6 — authored content" do
    test "coverage exists, nothing matches => authored_content" do
      coverage = [entry(%{head_sha: sha("a"), net_diff_id: @fp_a})]

      assert Coverage.decide(coverage, sha("b"), ctx()) == {:uncovered, :authored_content}
    end
  end

  describe "rule ordering — first hit wins" do
    test "rule 1 beats rule 3: an exact head match records no :mechanical row" do
      coverage = [
        entry(%{head_sha: sha("m"), net_diff_id: @fp_a}),
        entry(%{head_sha: sha("a"), net_diff_id: @fp_a})
      ]

      ctx = ctx(%{fetch_diff: fn _b, _h -> {:ok, @diff_a_after_base_merge} end})

      assert Coverage.decide_with_record(coverage, sha("m"), ctx) ==
               {{:covered, sha("m")}, nil}
    end

    test "rule 1 beats rule 2: a covered head is covered even while the forge lags" do
      coverage = [entry(%{head_sha: sha("s1")}), entry(%{head_sha: sha("s2")})]
      ctx = ctx(%{local_head_sha: sha("s2"), ancestor?: fn _a, _d -> true end})

      assert Coverage.decide(coverage, sha("s1"), ctx) == {:covered, sha("s1")}
    end

    test "rule 2 beats rule 3: a lagging forge waits rather than minting a :mechanical row" do
      coverage = [entry(%{head_sha: sha("s2"), net_diff_id: @fp_a})]

      ctx =
        ctx(%{
          local_head_sha: sha("s2"),
          ancestor?: fn _a, _d -> true end,
          fetch_diff: fn _b, _h -> {:ok, @diff_a_after_base_merge} end
        })

      assert Coverage.decide_with_record(coverage, sha("s1"), ctx) ==
               {{:unknown, :forge_lagging}, nil}
    end

    test "rule 3 beats rule 6: a fingerprint match wins over an unmatched sha" do
      coverage = [entry(%{head_sha: sha("a"), net_diff_id: @fp_a})]
      ctx = ctx(%{fetch_diff: fn _b, _h -> {:ok, @diff_a_after_base_merge} end})

      assert Coverage.decide(coverage, sha("m"), ctx) == {:covered, sha("m")}
    end

    test "rule 4 beats rule 5: an unfetchable diff pauses even with no coverage" do
      assert Coverage.decide([], sha("b"), ctx(%{base_ref: nil})) == {:unknown, :no_base_ref}

      assert Coverage.decide([], sha("b"), ctx(%{fetch_diff: fn _b, _h -> {:error, :nope} end})) ==
               {:unknown, :diff_unavailable}
    end

    test "rule 5 beats rule 6: empty coverage reports :no_coverage, not :authored_content" do
      assert Coverage.decide([], sha("b"), ctx()) == {:uncovered, :no_coverage}
    end
  end

  describe "properties of the predicate" do
    property "rule 1: a covered head is covered regardless of ctx" do
      check all(
              head <- sha_generator(),
              others <- list_of(sha_generator(), max_length: 4),
              local_head <- one_of([constant(nil), sha_generator()]),
              ancestor? <- boolean(),
              base_ref <- one_of([constant(nil), constant("main")])
            ) do
        coverage = Enum.map([head | others], &entry(%{head_sha: &1}))

        ctx =
          ctx(%{
            local_head_sha: local_head,
            base_ref: base_ref,
            ancestor?: fn _a, _d -> ancestor? end
          })

        assert Coverage.decide(coverage, head, ctx) == {:covered, head}
      end
    end

    property "rules 1-6: the answer is always one of the three documented shapes" do
      check all(
              head <- one_of([constant(nil), sha_generator()]),
              coverage_shas <- list_of(sha_generator(), max_length: 4),
              local_head <- one_of([constant(nil), sha_generator()]),
              ancestor? <- boolean(),
              base_ref <- one_of([constant(nil), constant("main")]),
              diff <- one_of([constant(@diff_a), constant(@diff_b), constant(nil)])
            ) do
        coverage = Enum.map(coverage_shas, &entry(%{head_sha: &1, net_diff_id: @fp_a}))

        ctx =
          ctx(%{
            local_head_sha: local_head,
            base_ref: base_ref,
            ancestor?: fn _a, _d -> ancestor? end,
            fetch_diff: fn _b, _h -> {:ok, diff} end
          })

        assert Coverage.decide(coverage, head, ctx) in valid_answers(head)
      end
    end

    property "rules 3/6: coverage is never claimed for content nobody reviewed" do
      check all(
              head <- sha_generator(),
              coverage_shas <- list_of(sha_generator(), min_length: 1, max_length: 4),
              local_head <- one_of([constant(nil), sha_generator()]),
              ancestor? <- boolean()
            ) do
        # Every covered row is @fp_a; the head under test contributes @fp_b.
        coverage =
          coverage_shas
          |> Enum.reject(&(&1 == head))
          |> Enum.map(&entry(%{head_sha: &1, net_diff_id: @fp_a}))

        ctx =
          ctx(%{
            local_head_sha: local_head,
            ancestor?: fn _a, _d -> ancestor? end,
            fetch_diff: fn _b, _h -> {:ok, @diff_b} end
          })

        refute match?({:covered, _}, Coverage.decide(coverage, head, ctx))
      end
    end

    property "rule 2: forge_lagging requires the local head to be covered" do
      check all(
              head <- sha_generator(),
              local_head <- sha_generator(),
              coverage_shas <- list_of(sha_generator(), max_length: 3)
            ) do
        coverage =
          coverage_shas
          |> Enum.reject(&(&1 in [head, local_head]))
          |> Enum.map(&entry(%{head_sha: &1, net_diff_id: @fp_a}))

        ctx =
          ctx(%{
            local_head_sha: local_head,
            # Ancestry answers yes to everything; only the coverage of the
            # local head is missing.
            ancestor?: fn _a, _d -> true end
          })

        assert Coverage.decide(coverage, head, ctx) != {:unknown, :forge_lagging}
      end
    end

    property "rule 5: an empty coverage set never yields :covered" do
      check all(
              head <- sha_generator(),
              local_head <- one_of([constant(nil), sha_generator()]),
              ancestor? <- boolean(),
              diff <- one_of([constant(@diff_a), constant(@diff_b)])
            ) do
        ctx =
          ctx(%{
            local_head_sha: local_head,
            ancestor?: fn _a, _d -> ancestor? end,
            fetch_diff: fn _b, _h -> {:ok, diff} end
          })

        assert Coverage.decide([], head, ctx) == {:uncovered, :no_coverage}
      end
    end

    property "a :mechanical row is returned exactly when rule 3 decided" do
      check all(
              head <- sha_generator(),
              covered_sha <- sha_generator(),
              same_content? <- boolean()
            ) do
        coverage = [entry(%{head_sha: covered_sha, net_diff_id: @fp_a})]
        diff = if same_content?, do: @diff_a_after_base_merge, else: @diff_b

        ctx = ctx(%{fetch_diff: fn _b, _h -> {:ok, diff} end})

        {decision, record} = Coverage.decide_with_record(coverage, head, ctx)

        rule_three? = same_content? and head != covered_sha

        if rule_three? do
          assert decision == {:covered, head}
          assert record.kind == :mechanical
          assert record.derived_from == List.first(coverage).id
        else
          assert record == nil
        end
      end
    end
  end

  describe "§4 walkthroughs" do
    # Each row: {name, coverage, head, ctx overrides, expected decision}.
    #
    #   §4.1 #1498  — a genuinely unreviewed push must stay blocked.
    #   §4.2 #1585  — five approved PRs blocked by a base merge must merge.
    #   §4.3 #1622  — an approved fix round the forge has not echoed yet.
    #   §4.4 #1594  — the fix-round commit gate's "no new content" question.
    #   §4.5        — a post-approval CI fix_pass must be reviewed.
    #   §4.6        — chain B: a round that never approved covers nothing.
    walkthroughs = [
      {"§4.1 #1498 — reviewer approved A, someone pushed B with real content",
       [%{head_sha: "a", net_diff_id: :fp_a}], "b",
       %{local_head_sha: "a", ancestor?: :never, diff: :diff_b}, {:uncovered, :authored_content}},
      {"§4.2 #1585 — base merge produced M with an identical net diff",
       [%{head_sha: "a", net_diff_id: :fp_a}], "m",
       %{local_head_sha: "m", ancestor?: :never, diff: :diff_a_after_base_merge},
       {:covered, "m"}},
      {"§4.2 #1585 — the next base merge resolves at rule 1 off the :mechanical row",
       [%{head_sha: "a", net_diff_id: :fp_a}, %{head_sha: "m", net_diff_id: :fp_a}], "m",
       %{local_head_sha: "m", ancestor?: :never, diff: :diff_a_after_base_merge},
       {:covered, "m"}},
      {"§4.3 #1622 — round 2 approved S2, the forge still reports S1",
       [%{head_sha: "s2", net_diff_id: :fp_a}], "s1",
       %{local_head_sha: "s2", ancestor?: :s1_before_s2, diff: :diff_a},
       {:unknown, :forge_lagging}},
      {"§4.3 #1622 — the next poll reports S2 and merges at rule 1",
       [%{head_sha: "s2", net_diff_id: :fp_a}], "s2",
       %{local_head_sha: "s2", ancestor?: :s1_before_s2, diff: :diff_a}, {:covered, "s2"}},
      {"§4.3 #1622 — S1 was rejected in round 1, so merging it is impossible",
       [%{head_sha: "s2", net_diff_id: :fp_a}], "s1",
       %{local_head_sha: "s1", ancestor?: :s1_before_s2, diff: :diff_b},
       {:uncovered, :authored_content}},
      {"§4.4 #1594 — a fix round that committed nothing contributes no new content",
       [%{head_sha: "s2", net_diff_id: :fp_a}], "s2",
       %{local_head_sha: "s2", ancestor?: :never, diff: :diff_a}, {:covered, "s2"}},
      {"§4.4 #1594 — an amended head with the same content is mechanically covered",
       [%{head_sha: "s2", net_diff_id: :fp_a}], "s2amend",
       %{local_head_sha: "s2amend", ancestor?: :never, diff: :diff_a_after_base_merge},
       {:covered, "s2amend"}},
      {"§4.5 — a post-approval CI fix_pass pushed S3 with content",
       [%{head_sha: "s2", net_diff_id: :fp_a}], "s3",
       %{local_head_sha: "s3", ancestor?: :s2_before_s3, diff: :diff_b},
       {:uncovered, :authored_content}},
      {"§4.6 — chain B: an inconclusive round wrote no coverage row", [], "s1",
       %{local_head_sha: "s1", ancestor?: :never, diff: :diff_a}, {:uncovered, :no_coverage}}
    ]

    for {name, coverage_specs, head, ctx_spec, expected} <- walkthroughs do
      test name do
        coverage =
          Enum.map(unquote(Macro.escape(coverage_specs)), fn spec ->
            entry(%{head_sha: sha(spec.head_sha), net_diff_id: fixture(spec.net_diff_id)})
          end)

        ctx_spec = unquote(Macro.escape(ctx_spec))

        ctx =
          ctx(%{
            local_head_sha: sha(ctx_spec.local_head_sha),
            ancestor?: ancestry(ctx_spec.ancestor?),
            fetch_diff: fn _base, _head -> {:ok, fixture(ctx_spec.diff)} end
          })

        expected =
          case unquote(Macro.escape(expected)) do
            {:covered, s} -> {:covered, sha(s)}
            other -> other
          end

        assert Coverage.decide(coverage, sha(unquote(head)), ctx) == expected
      end
    end

    test "§4.2 — the base merge's :mechanical row points back at the review" do
      reviewed = entry(%{head_sha: sha("a"), net_diff_id: @fp_a, round: 2})

      ctx =
        ctx(%{
          local_head_sha: sha("m"),
          fetch_diff: fn _b, _h -> {:ok, @diff_a_after_base_merge} end
        })

      assert {{:covered, _}, record} = Coverage.decide_with_record([reviewed], sha("m"), ctx)
      assert record.kind == :mechanical
      assert record.derived_from == reviewed.id
      assert record.net_diff_id == @fp_a
    end
  end

  describe "§4.7 — the five current failure reasons" do
    test ":review_gate_inconclusive — no row was written, so the head is uncovered" do
      assert Coverage.decide([], sha("s1"), ctx()) == {:uncovered, :no_coverage}
    end

    test "{:awaiting_review_timeout, 30} — a review that never landed covers nothing" do
      assert Coverage.decide([], sha("s1"), ctx()) == {:uncovered, :no_coverage}
    end

    test "{:unreviewed_head, sha} — never produced for a lag" do
      coverage = [entry(%{head_sha: sha("s2")})]
      ctx = ctx(%{local_head_sha: sha("s2"), ancestor?: fn _a, _d -> true end})

      assert Coverage.decide(coverage, sha("s1"), ctx) == {:unknown, :forge_lagging}
    end

    test "{:unreviewed_head, sha} — still produced for a genuinely authored push" do
      coverage = [entry(%{head_sha: sha("a"), net_diff_id: @fp_a})]
      ctx = ctx(%{fetch_diff: fn _b, _h -> {:ok, @diff_b} end})

      assert Coverage.decide(coverage, sha("b"), ctx) == {:uncovered, :authored_content}
    end

    test "{:stale_reviewed_sha, ...} — never produced for a base merge" do
      coverage = [entry(%{head_sha: sha("a"), net_diff_id: @fp_a})]
      ctx = ctx(%{fetch_diff: fn _b, _h -> {:ok, @diff_a_after_base_merge} end})

      assert Coverage.decide(coverage, sha("m"), ctx) == {:covered, sha("m")}
    end

    test "review_not_started — an empty coverage set is a decision, not a crash" do
      assert Coverage.decide([], nil, %{}) == {:unknown, :no_head}
      # An empty ctx cannot even name a base to compare against, so rule 4
      # answers before rule 5 does — a pause, not a crash and not a verdict.
      assert Coverage.decide([], sha("s1"), %{}) == {:unknown, :no_base_ref}
    end
  end

  defp sha_generator do
    map(string(?a..?f, length: 8), &String.pad_leading(&1, 40, "0"))
  end

  defp valid_answers(nil), do: [{:unknown, :no_head}]

  defp valid_answers(head) do
    [
      {:covered, head},
      {:uncovered, :authored_content},
      {:uncovered, :no_coverage},
      {:unknown, :forge_lagging},
      {:unknown, :diff_unavailable},
      {:unknown, :no_base_ref},
      {:unknown, :no_head}
    ]
  end

  defp fixture(:fp_a), do: @fp_a
  defp fixture(:diff_a), do: @diff_a
  defp fixture(:diff_a_after_base_merge), do: @diff_a_after_base_merge
  defp fixture(:diff_b), do: @diff_b

  defp ancestry(:never), do: fn _ancestor, _descendant -> false end

  defp ancestry(:s1_before_s2),
    do: fn ancestor, descendant -> {ancestor, descendant} == {sha("s1"), sha("s2")} end

  defp ancestry(:s2_before_s3),
    do: fn ancestor, descendant -> {ancestor, descendant} == {sha("s2"), sha("s3")} end
end
