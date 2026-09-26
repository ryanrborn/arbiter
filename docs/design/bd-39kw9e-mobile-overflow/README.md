# bd-39kw9e — mobile overflow/wrapping screenshots

Real captures from `scripts/verify_mobile_overflow.mjs --screenshots`, driving a
real Bandit listener with headless Chromium at 375px, 414px and 1280px, in
both themes.

- `before/` — captured against commit `ad5f2707` (the parent of this branch's
  first fix commit), i.e. the pre-fix state.
- `after/` — captured against this branch's HEAD.

Filenames: `<page>_<width>px_<theme>.png`. `tasks-*` is the Issue detail page
(the workspace/task slug in the filename varies per run since the seed
fixture creates a fresh workspace each time).

Known `before` failures this branch fixes (see `RESULT: FAIL` runs used to
produce these captures):
- Usage: the range-toggle segmented control overflows the viewport at
  375/414px (`usage-range-toggle-stays-inside-viewport-*` FAIL).
- Audit: the Detail column collapses to 0 width at 375/414px
  (`audit-detail-column-is-readable-*` FAIL, `detailWidth=0`).

1280px screenshots (both before and after) demonstrate no desktop regression.
