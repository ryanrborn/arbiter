# Build summary: feature/gte-005-rest-api

**Bead:** gte-005
**Builder:** Agent (worktree session, 2026-05-19)
**Branch:** feature/gte-005-rest-api
**Commit:** 5deb1dc

## What I built

A JSON-only Phoenix REST API in the `gt_elixir_web` app that exposes the bead-ledger resources (Workspace, Issue, Dependency, Convoy) over the existing `:api` pipeline. The bd2 CLI (gte-006) will speak to this over a localhost HTTP socket. No auth — that's a later bead.

### Files added/changed

```
apps/gt_elixir_web/lib/gt_elixir_web/router.ex                                  (M) adds /api scope with 16 routes
apps/gt_elixir_web/lib/gt_elixir_web/controllers/api/issue_controller.ex        (+) Issue CRUD + close/reopen/ready
apps/gt_elixir_web/lib/gt_elixir_web/controllers/api/dependency_controller.ex   (+) Dependency create/delete
apps/gt_elixir_web/lib/gt_elixir_web/controllers/api/convoy_controller.ex       (+) Convoy create/show/close
apps/gt_elixir_web/lib/gt_elixir_web/controllers/api/workspace_controller.ex    (+) Workspace create/show/list
apps/gt_elixir_web/lib/gt_elixir_web/controllers/api/issue_json.ex              (+) Issue render
apps/gt_elixir_web/lib/gt_elixir_web/controllers/api/dependency_json.ex         (+) Dependency render
apps/gt_elixir_web/lib/gt_elixir_web/controllers/api/convoy_json.ex             (+) Convoy render (member_ids + aggregates)
apps/gt_elixir_web/lib/gt_elixir_web/controllers/api/workspace_json.ex          (+) Workspace render
apps/gt_elixir_web/lib/gt_elixir_web/controllers/api/fallback_controller.ex     (+) {:error,_} → JSON error
apps/gt_elixir_web/test/gt_elixir_web/controllers/api/issue_controller_test.exs        (+) 15 tests
apps/gt_elixir_web/test/gt_elixir_web/controllers/api/dependency_controller_test.exs   (+) 5 tests
apps/gt_elixir_web/test/gt_elixir_web/controllers/api/convoy_controller_test.exs       (+) 4 tests
apps/gt_elixir_web/test/gt_elixir_web/controllers/api/workspace_controller_test.exs    (+) 5 tests (uuid 404 + 4 happy/422)
```

No domain or Ash-resource changes — the web layer just consumes the existing `Ash.create / Ash.get / Ash.read / Ash.update` API.

## Endpoints delivered (all spec'd routes)

| Method | Path | Action |
|---|---|---|
| POST | /api/issues | Create issue |
| GET | /api/issues | List + filters: `status`, `priority`, `issue_type`, `assignee`, `workspace_id` |
| GET | /api/issues/ready | `Issue.ready/0` results |
| GET | /api/issues/:id | Show (404 on missing) |
| PATCH | /api/issues/:id | Update (`workspace_id` filtered out — immutable) |
| POST | /api/issues/:id/close | Close (optional body `reason`) |
| POST | /api/issues/:id/reopen | Reopen |
| POST | /api/dependencies | Create edge |
| DELETE | /api/dependencies/:from/:to[?type=…] | Delete edge(s) |
| POST | /api/convoys | Create convoy |
| GET | /api/convoys/:id | Show with `member_ids`, `total_issues`, `closed_issues` |
| POST | /api/convoys/:id/close | Close convoy |
| POST | /api/workspaces | Create |
| GET | /api/workspaces | List |
| GET | /api/workspaces/:id | Show |

PUT is also accepted for `/api/issues/:id` as a convenience (curl-friendly), aliasing the PATCH route. Spec says PATCH; PUT is a superset.

## Response shapes

- **Success show:** bare resource JSON (e.g. `{"id":"api-3o8abc","title":"…",...}`).
- **Success list:** `{"data":[...]}` wrapper (leaves room for pagination meta later).
- **Success create:** 201 + bare resource JSON.
- **Success delete:** 204 No Content (empty body).
- **Errors:** `{"error":{"type":"...","message":"...","details":{...}}}`. Status codes:
  - `validation_error` → 422
  - `not_found` → 404
  - `invalid_request` → 400
  - `forbidden` → 403
  - `internal_error` → 500

Atoms always serialize as plain strings (`"open"`, not `":open"`). Timestamps as ISO8601.

## Design choices worth flagging

- **Fallback controller** (`GtElixirWeb.Api.FallbackController`) is wired via `action_fallback` on every API controller. It pattern-matches on `Ash.Error.Invalid`, `Ash.Error.Query.NotFound`, `Ash.Error.Forbidden`, `Ash.Error.Unknown`, plus a `{:invalid_request, msg}` sentinel for our own param-validation errors. Crucially, **`Ash.get/2` returns `%Ash.Error.Invalid{}` wrapping a `%Ash.Error.Query.NotFound{}`** rather than the bare NotFound — the fallback unwraps that case and emits a 404 instead of a 422.
- **Atom coercion uses `String.to_existing_atom/1`** for `status`, `issue_type`, `tracker_type`, `lifecycle`, and dependency `type`. Bare `String.to_atom` would leak memory under hostile load. Unknown values fall through to Ash, which rejects them as a validation error — or, on the index filter path, we short-circuit with a 400 `invalid_request` so the user sees a clear "invalid status: zzz" message.
- **Filtering `GET /api/issues`** uses `Ash.Query.do_filter/2` with a keyword list (Ash 3.x supports `[status: :open, workspace_id: "..."]` as a filter shorthand for top-level attribute equality). Multi-value query strings (`?status=open&status=in_progress`) are NOT specially handled — Plug parses the last value. If the CLI needs OR filtering, that's a future tweak.
- **`PATCH /api/issues/:id`** explicitly drops `workspace_id` from params before passing them to `Ash.update`. The `:update` action doesn't accept `workspace_id` anyway, but I'd rather silently ignore than 422 — the field is conceptually immutable.
- **`POST /api/issues/:id/close`** translates a JSON body `{"reason": "..."}` into the Ash action argument `reason` (the action defines `argument :reason, :string`). Empty body works too — argument is optional in the action.
- **`POST /api/convoys/:id/close`** likewise threads `reason` through to the Convoy `:close` action (which has the same argument).
- **`GET /api/convoys/:id`** explicitly loads `[:memberships, :total_issues, :closed_issues]` so the JSON includes `member_ids`, `total_issues`, `closed_issues`. `Convoy` after creation also gets the same load so `POST /api/convoys` returns a consistent shape (empty list, 0/0).
- **`DELETE /api/dependencies/:from/:to`** without a `?type=` query removes ALL edges between the pair. With `?type=blocks` it removes only the matching edge. A 404 is returned if no rows match — distinct from "request was OK but nothing to do". Errs on the side of telling the caller their delete didn't do anything.
- **Filter helper `coerce_filter_value/2`** validates `status` and `issue_type` as known atoms BEFORE Ash sees them so the user gets a 400 `invalid_request` ("invalid status: zzz") instead of a 500 from Postgres choking on an unknown enum.
- **No pagination yet.** `GET /api/issues` returns all issues. At our current scale (low hundreds of issues per workspace) this is fine; pagination is a flag I'd add later via `?limit=&after=` once the CLI starts seeing real datasets.
- **Verb choice for actions** — `/close` and `/reopen` are POSTs (not PATCHes) to make them feel like RPC verbs in the CLI. The spec lists POST; I matched.

## Spec deviations

None of consequence. Two minor additions:

1. **PUT alias** on `/api/issues/:id` in addition to PATCH. Optional, doesn't change semantics.
2. **`forbidden` error type** added to the fallback controller for `%Ash.Error.Forbidden{}` even though no current resource is policy-protected. Cheap future-proofing for when auth lands.

## Tests

```
$ mix test
1 doctest, 1 test (gt_elixir_cli)         — 0 failures
72 tests          (gt_elixir)             — 0 failures
36 tests          (gt_elixir_web)         — 0 failures
                                            ⤷ includes 31 new API tests in 4 files

Total: 110 tests (gte-001..004 baseline + 31 new), 0 failures
```

Test breakdown for this bead:
- `issue_controller_test.exs` — 15 tests: create happy/422, show happy/404, index list, 3 filter variants (status, workspace_id, invalid status → 400), patch happy/immutable workspace_id/404, close happy/already-closed 422, reopen happy/already-open 422, ready filtering with a real dep
- `dependency_controller_test.exs` — 5 tests: create happy, create self-ref 422, delete-all-by-pair, delete-by-type filter, delete with no matches 404
- `convoy_controller_test.exs` — 4 tests: create happy/422, show with members and aggregates, show 404, close with reason
- `workspace_controller_test.exs` — 5 tests: create happy, create invalid prefix 422, show happy, show 404, list

## What I punted on (with reasons)

1. **Pagination** — call it gte-005a if the CLI hits a wall. Not blocking for the bd2 demo.
2. **Bulk endpoints** (`POST /api/issues:bulk_create`, `POST /api/convoy/:id/issues` for batch membership) — not in spec, easy to add later.
3. **GET /api/dependencies** (list/filter edges) — not in spec; the CLI doesn't need it for gte-006.
4. **GET /api/convoys** (list convoys) — not in spec; only show was required.
5. **Per-page Ash policy auth** — explicitly out of scope for this bead.
6. **Strict JSON content-type enforcement on POST/PATCH bodies** — Plug parses any media type given the `:api` pipeline `accepts: ["json"]`; if someone POSTs `text/plain` Phoenix will reject with a 415 before the controller. Not adding extra plug here.

## What I noticed worth improving separately

- **The `Ash.Error.Invalid` → 404 detection** in the fallback iterates `err.errors` looking for a `NotFound`. If a single Ash response ever contains BOTH a NotFound and a validation error, the current logic would 404, hiding the validation. In practice this doesn't happen (NotFound short-circuits the action) but the assumption is fragile. A cleaner fix is to have controllers branch on `Ash.get` themselves and only let true validation errors flow into the fallback. I went with the centralized approach because it's less boilerplate; happy to refactor if you'd rather.
- **No request logging tag.** When the CLI is debugging "why did the API say 422?" we have no correlation ID in the response. Could add a `details: %{request_id: conn.assigns.request_id}` to error responses cheaply.
- **`Ash.read(Issue)`'s lack of stable ordering** — `GET /api/issues` returns in insertion order today (Postgres default), which is fine for now. If the CLI starts asserting on order, add `Ash.Query.sort(query, created_at: :desc)` to the index action.
- **`coerce_filter_value/2` lives inline in `IssueController`.** If we add more resource controllers with filtering, this helper should move to a shared module (`GtElixirWeb.Api.ParamCoercion` or similar).

## How to verify

```sh
cd ~/dev/gt-elixir-wt-005
mix compile --warnings-as-errors  # clean
mix format --check-formatted      # clean
mix test                          # 110 tests, 0 failures

# Smoke via curl (start the server first: `mix phx.server`)
WS=$(curl -s -X POST localhost:4000/api/workspaces -H 'content-type: application/json' \
       -d '{"name":"smoke","prefix":"smk"}' | jq -r .id)

curl -s -X POST localhost:4000/api/issues -H 'content-type: application/json' \
     -d "{\"title\":\"first\",\"workspace_id\":\"$WS\"}" | jq

curl -s localhost:4000/api/issues | jq
curl -s localhost:4000/api/issues/ready | jq
```

## Reviewer should pay attention to

1. **`fallback_controller.ex` — the NotFound-inside-Invalid unwrap.** Is the centralized approach right, or would you rather controllers handle NotFound explicitly (extra boilerplate, less surprising)?
2. **JSON shape**: bare object for show, `{data: [...]}` for list. Acceptable seed for pagination later?
3. **PUT alias on `/api/issues/:id`** — should I remove it to stay strictly to spec, or keep it?
4. **`String.to_existing_atom/1` placement.** Used in 5 places (issue controller, dependency controller, convoy controller). Worth pulling into a tiny `safe_atom` helper module before gte-006 adds more atom-typed fields?
5. **Workspace ID is a UUID** but Issue/Convoy IDs are short prefixed strings — the path matcher accepts both transparently, but if you want stricter route validation for the prefixed IDs we'd need a constraint plug.

## Verdict requested

Ready for merge. After merge, unblocked: **gte-006 (bd2 CLI)** can start consuming this API immediately.
