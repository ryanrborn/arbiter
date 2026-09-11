defmodule Arbiter.Workflows.ReviewPatrol.ThreadMemoryTest do
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.ReviewPatrol.ThreadMemory

  defp thread(id, path, line, comments, opts \\ []) do
    %{
      id: id,
      resolved: Keyword.get(opts, :resolved, false),
      path: path,
      line: line,
      author: comments |> List.first() |> elem(0),
      body: comments |> List.first() |> elem(1),
      comments:
        Enum.map(comments, fn {author, body} ->
          %{id: System.unique_integer([:positive]), author: author, body: body}
        end)
    }
  end

  describe "settle/4 — author refuted with cited evidence" do
    test "a reply citing file:line settles the thread" do
      threads = [
        thread("RT1", "lib/a.ex", 12, [
          {"botreviewer", "{:error, :unauthorized} returns 500 here"},
          {"prauthor", "no — FallbackController maps it at lib/fallback.ex:41"}
        ])
      ]

      assert [entry] = ThreadMemory.settle(threads, "botreviewer", "prauthor", "sha1")
      assert entry["thread_id"] == "RT1"
      assert entry["file"] == "lib/a.ex"
      assert entry["line"] == 12
      assert entry["reason"] == "author_refuted"
      assert entry["settled_sha"] == "sha1"
      assert entry["finding"] =~ "returns 500"
      assert entry["author_reply"] =~ "FallbackController"
    end

    test "a bare disagreement with no citation does NOT settle the thread" do
      threads = [
        thread("RT1", "lib/a.ex", 12, [
          {"botreviewer", "this looks wrong"},
          {"prauthor", "why? seems fine to me"}
        ])
      ]

      assert ThreadMemory.settle(threads, "botreviewer", "prauthor", "sha1") == []
    end

    test "a citation from someone who is not the PR author does not settle" do
      threads = [
        thread("RT1", "lib/a.ex", 12, [
          {"botreviewer", "this looks wrong"},
          {"drive-by", "see lib/other.ex:9"}
        ])
      ]

      assert ThreadMemory.settle(threads, "botreviewer", "prauthor", "sha1") == []
    end

    test "a thread we never participated in is ignored" do
      threads = [
        thread("RT1", "lib/a.ex", 12, [
          {"someone-else", "this looks wrong"},
          {"prauthor", "no — see lib/fallback.ex:41"}
        ])
      ]

      assert ThreadMemory.settle(threads, "botreviewer", "prauthor", "sha1") == []
    end
  end

  describe "settle/4 — we conceded" do
    test "our own conceding reply settles the thread, and outranks refutation" do
      threads = [
        thread("RT2", "lib/b.ex", 7, [
          {"botreviewer", "with_app_env is scoped wrong"},
          {"prauthor", "it is scoped per-test"},
          {"botreviewer", "You're right — my comment was wrong. Resolving."}
        ])
      ]

      assert [entry] = ThreadMemory.settle(threads, "botreviewer", "prauthor", "sha1")
      assert entry["reason"] == "we_conceded"
    end

    test "a non-conceding reply from us leaves an uncited thread unsettled" do
      threads = [
        thread("RT2", "lib/b.ex", 7, [
          {"botreviewer", "with_app_env is scoped wrong"},
          {"prauthor", "it is scoped per-test"},
          {"botreviewer", "I still think this is a problem."}
        ])
      ]

      assert ThreadMemory.settle(threads, "botreviewer", "prauthor", "sha1") == []
    end
  end

  describe "settle/4 — resolved threads" do
    test "a resolved thread we own is settled" do
      threads = [
        thread(
          "RT3",
          "lib/c.ex",
          3,
          [{"botreviewer", "unused alias"}, {"prauthor", "removed"}],
          resolved: true
        )
      ]

      assert [entry] = ThreadMemory.settle(threads, "botreviewer", "prauthor", "sha1")
      assert entry["reason"] == "resolved"
    end
  end

  describe "merge/2" do
    test "dedupes by thread id, newest entry wins, and preserves order" do
      old = [
        %{"thread_id" => "RT1", "file" => "a.ex", "line" => 1, "reason" => "author_refuted"},
        %{"thread_id" => "RT2", "file" => "b.ex", "line" => 2, "reason" => "author_refuted"}
      ]

      new = [
        %{"thread_id" => "RT2", "file" => "b.ex", "line" => 2, "reason" => "we_conceded"},
        %{"thread_id" => "RT3", "file" => "c.ex", "line" => 3, "reason" => "resolved"}
      ]

      merged = ThreadMemory.merge(old, new)

      assert Enum.map(merged, & &1["thread_id"]) == ["RT1", "RT2", "RT3"]
      assert Enum.find(merged, &(&1["thread_id"] == "RT2"))["reason"] == "we_conceded"
    end
  end

  describe "filter_findings/3" do
    # A diff whose new-file side changes only line 40 of lib/a.ex.
    defp diff_touching_line_40 do
      """
      diff --git a/lib/a.ex b/lib/a.ex
      --- a/lib/a.ex
      +++ b/lib/a.ex
      @@ -38,3 +38,4 @@
       keep
       keep
      +touched
       keep
      """
    end

    defp settled(file, line),
      do: %{"thread_id" => "RT1", "file" => file, "line" => line, "reason" => "author_refuted"}

    test "drops a finding re-raised on a settled thread's untouched lines" do
      findings = [%{severity: :error, file: "lib/a.ex", line: 12, message: "returns 500"}]

      assert ThreadMemory.filter_findings(
               findings,
               [settled("lib/a.ex", 12)],
               diff_touching_line_40()
             ) ==
               []
    end

    test "drops a re-raise whose line drifted slightly from the anchor" do
      findings = [%{severity: :error, file: "lib/a.ex", line: 14, message: "returns 500"}]

      assert ThreadMemory.filter_findings(
               findings,
               [settled("lib/a.ex", 12)],
               diff_touching_line_40()
             ) ==
               []
    end

    test "keeps a finding when the new commits touch the settled thread's lines" do
      findings = [%{severity: :error, file: "lib/a.ex", line: 40, message: "still broken"}]
      settled = [settled("lib/a.ex", 40)]

      assert ThreadMemory.filter_findings(findings, settled, diff_touching_line_40()) == findings
    end

    test "keeps findings elsewhere in the same file" do
      findings = [%{severity: :error, file: "lib/a.ex", line: 90, message: "new bug"}]

      assert ThreadMemory.filter_findings(
               findings,
               [settled("lib/a.ex", 12)],
               diff_touching_line_40()
             ) ==
               findings
    end

    test "keeps findings in other files" do
      findings = [%{severity: :error, file: "lib/z.ex", line: 12, message: "new bug"}]

      assert ThreadMemory.filter_findings(
               findings,
               [settled("lib/a.ex", 12)],
               diff_touching_line_40()
             ) ==
               findings
    end

    test "a file-level settled thread (no line) suppresses nothing" do
      findings = [%{severity: :error, file: "lib/a.ex", line: 12, message: "returns 500"}]
      settled = [settled("lib/a.ex", nil)]

      assert ThreadMemory.filter_findings(findings, settled, diff_touching_line_40()) == findings
    end

    test "no settled threads → findings pass through untouched" do
      findings = [%{severity: :error, file: "lib/a.ex", line: 12, message: "x"}]
      assert ThreadMemory.filter_findings(findings, [], diff_touching_line_40()) == findings
      assert ThreadMemory.filter_findings(findings, nil, diff_touching_line_40()) == findings
    end
  end

  describe "prompt_section/1" do
    test "renders each settled thread with its finding, reply and re-raise rule" do
      settled = [
        %{
          "thread_id" => "RT1",
          "file" => "lib/a.ex",
          "line" => 12,
          "finding" => "{:error, :unauthorized} returns 500",
          "reason" => "author_refuted",
          "author_reply" => "FallbackController maps it at lib/fallback.ex:41"
        },
        %{
          "thread_id" => "RT2",
          "file" => "lib/b.ex",
          "line" => 7,
          "finding" => "with_app_env is scoped wrong",
          "reason" => "we_conceded",
          "author_reply" => nil
        }
      ]

      section = ThreadMemory.prompt_section(settled)

      assert section =~ "SETTLED REVIEW THREADS"
      assert section =~ "lib/a.ex:12"
      assert section =~ "{:error, :unauthorized} returns 500"
      assert section =~ "FallbackController maps it at lib/fallback.ex:41"
      assert section =~ "lib/b.ex:7"
      assert section =~ "we conceded"
      assert section =~ "the author refuted it with cited evidence"
      # The re-raise rule the reviewer must follow.
      assert section =~ "name what changed"
    end

    test "empty / nil settled state renders nothing" do
      assert ThreadMemory.prompt_section([]) == ""
      assert ThreadMemory.prompt_section(nil) == ""
    end
  end

  describe "concession?/1" do
    test "recognises the concession phrasings our reply handler emits" do
      assert ThreadMemory.concession?("my comment was wrong. Resolving.")
      assert ThreadMemory.concession?("You're right, this is handled already.")
      assert ThreadMemory.concession?("I was wrong about the encoding here.")
      assert ThreadMemory.concession?("Withdrawing this finding.")
      assert ThreadMemory.concession?("My mistake — not an issue.")
      assert ThreadMemory.concession?("Retracting: false positive on my part.")
    end

    test "does not fire on pushback or on a neutral reply" do
      refute ThreadMemory.concession?("I still think this is a problem.")
      refute ThreadMemory.concession?("Thanks — please also add a test.")
      refute ThreadMemory.concession?("")
      refute ThreadMemory.concession?(nil)
    end
  end
end
