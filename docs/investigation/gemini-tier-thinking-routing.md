# Investigation: Gemini tier+thinking combined model routing

**Bead:** bd-7apx5e  
**Feature branch:** `feature/gemini-tier-thinking-combined-model-routing`

## Summary

Unstaged changes found in main worktree (`apps/arbiter/lib/arbiter/agents/gemini.ex` and
`apps/arbiter/lib/arbiter/agents/gemini/config.ex`, last modified 2026-06-05) were packaged
into the feature branch above. All 23 existing Gemini tests pass.

## What the change does

agy (the Gemini CLI wrapper) encodes both model tier and thinking level in a single model-name
string (e.g. `"Gemini 3.1 Pro (High)"`), unlike Claude which separates model flag from
`--thinking-budget`. Before this change, `resolve_model/1` ignored thinking level when both
`:model_tier` and `:thinking` opts were set. The change adds a `cond`-based fallback chain:
combined lookup → tier-only → active model.

### config.ex additions

- `@default_combined_models` — 18-entry map: `"tier/thinking"` → agy model string, covering
  `economy | standard | premium` × `none | low | medium | high | xhigh | max`
- `model_for_tier_and_thinking/2` — lookup with per-workspace override via `combined_models` key
- Extended `thinking_env/1` to cover `xhigh`/`max` levels

## What's complete

- Core logic and fallback chain
- Default model map (all tier × thinking combos)
- Workspace override path
- Existing tests all passing

## What's missing before PR

1. Tests for `model_for_tier_and_thinking/2` in `config_test.exs`
2. Integration test in `gemini_test.exs` for combined path (including `xhigh`/`max` capping)
3. `by_difficulty` routing table only maps up to `"high"` — `xhigh`/`max` entries missing or document as intentional
4. `validate_config.ex` does not document `combined_models` as a valid workspace key
5. Verify agy model name strings against current agy model list (may have changed since 2026-06-05)
6. Document intentional `economy`/`standard` collapse to same Flash model strings

## Verdict

Logic is sound, fallback chain is correct. Primary blockers before PR: tests (1, 2) and agy
model name verification (5). Items 3, 4, 6 are polish.
