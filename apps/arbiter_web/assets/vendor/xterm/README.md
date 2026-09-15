# Vendored xterm.js

`docs/browser-hosted-coordinator-sessions.md` §6.1: **this repo has no npm.**
`apps/arbiter_web/assets` has no `package.json` and no `node_modules`;
`config/config.exs` runs esbuild straight over `js/app.js`, and third-party JS
lives here as source (`../topbar.js`, `../daisyui.js`, …). Adding a package
manager for one dependency would put an `npm install` step on every CI run and
on every one of the fleet's constantly recreated worktrees. So: vendored,
pinned by construction, upgraded by hand.

## What is here

| File | Upstream | Version |
|---|---|---|
| `xterm.js` | `@xterm/xterm` | `@xterm/xterm@5.5.0` |
| `addon-canvas.js` | `@xterm/addon-canvas` | `@xterm/addon-canvas@0.7.0` |
| `addon-fit.js` | `@xterm/addon-fit` | `@xterm/addon-fit@0.10.0` |
| `../../css/xterm.css` | `@xterm/xterm` (`css/xterm.css`) | `@xterm/xterm@5.5.0` |

Each file is the upstream published build verbatim, with a header comment
prepended and the trailing `sourceMappingURL` comment removed (we do not vendor
the `.map` files, and a dangling reference is a 404 in every devtools session).

Tarball digests, as published on `registry.npmjs.org`:

```
sha256  bd954fa721872170188cc5d7e83e88db3c83c9a18a4e8d24c2783d26491f59d2  xterm-5.5.0.tgz
sha256  f8004a9c444289c686ac9b58df98505f3e027fcfea411b6845f9279cc281a774  addon-canvas-0.7.0.tgz
sha256  917ac44972453d5eed52edc1e50260c76398ce48cf2290c2e60671102bba0b33  addon-fit-0.10.0.tgz
```

## Why the 5.x line, and why these are UMD rather than ESM builds

§6.2 requires the **canvas** renderer, not WebGL — the dashboard is a
multi-panel app the operator keeps open across tabs, browsers cap live WebGL
contexts at roughly 8–16, and a lost context renders as a *blank terminal* on
the primary interface.

`@xterm/addon-canvas` was **not carried forward to xterm 6**. Upstream shipped
`@xterm/xterm@6.0.0` on 2025-12-22 together with new `addon-webgl`,
`addon-search`, `addon-web-links` and `addon-fit` releases — and no new
`addon-canvas`; its last release is still `0.7.0` (2024-04-05), declaring
`peerDependencies: {"@xterm/xterm": "^5.0.0"}`. The canvas addon reaches deep
into `terminal._core` (`_renderService`, `_charSizeService`,
`_characterJoinerService`, …), so running it against a major version it was
never built for risks throwing out of `loadAddon` and leaving no terminal at
all. **The renderer decision pins the terminal version**, so this is the 5.x
line: `@xterm/xterm@5.5.0` with its contemporaneous `addon-fit@0.10.0`.

The 5.x line publishes only the UMD/CJS build (`lib/xterm.js`); the `.mjs`
bundles first appear in 6.0.0 and in 5.6.0 *betas*, and a beta is not something
to pin a primary interface to. esbuild consumes the UMD bundles natively and
emits ESM into `priv/static/assets/js/app.js`, so nothing downstream can tell
the difference — `assets/js/session_terminal.mjs` imports them with ordinary
`import { Terminal } from "@/vendor/xterm/xterm.js"` syntax.

Revisit when upstream ships a canvas addon for the 6.x line.

## Upgrading

```sh
cd "$(mktemp -d)"
curl -sSLO https://registry.npmjs.org/@xterm/xterm/-/xterm-<version>.tgz
sha256sum xterm-<version>.tgz          # record it in the table above
tar xzf xterm-<version>.tgz
# copy package/lib/xterm.js and package/css/xterm.css into place, keep the
# header comment, drop the sourceMappingURL line, bump the versions in this
# README and in apps/arbiter_web/test/arbiter_web/assets/terminal_assets_test.exs
```

`ArbiterWeb.TerminalAssetsTest` fails if the version in a header comment and
the version in this README drift apart, or if a `package.json` appears.
