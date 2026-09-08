#!/bin/sh
# Fixture: a reviewer that emits its VERDICT and then keeps producing findings
# for far longer than either in-memory line cap (ClaudeSession's 1000, the
# persisted run row's 500). bd-6dxit2's acceptance case: the sentinel must still
# be found, so the review lands as REQUEST_CHANGES with its findings intact
# rather than being discarded as INCONCLUSIVE.
i=1
while [ "$i" -le 40 ]; do
  echo "reviewing hunk $i..."
  i=$((i + 1))
done
echo "VERDICT: REQUEST_CHANGES"
echo "Findings follow."
i=1
while [ "$i" -le 1200 ]; do
  echo "- [MEDIUM] finding $i: file_$i.ex:$i needs a bounds check"
  i=$((i + 1))
done
echo "arb done"
