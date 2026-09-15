#!/usr/bin/env node
//
// bd-3ymdvi, acceptance criterion 8 — the post-merge, coordinator-owned check
// that a terminal client survives `systemctl --user restart arbiter` with no
// lost and no duplicated output. Also bd-c76fu9 (phase 5) criterion 3, which
// asks the same question of the *browser* terminal.
//
// Criterion 8 cannot be a merge gate: it needs a *running* arbiter to restart.
// This is the headless client. Since phase 5 it is not merely shaped like the
// browser's — it **is** the browser's: the resume protocol here is
// `apps/arbiter_web/assets/js/session_stream.mjs`, the same module the
// LiveView hook drives xterm with. What this script proves about resume is
// therefore what the browser gets, rather than what a second implementation of
// the same protocol happens to do.
//
//   node scripts/verify_session_transport.mjs --session <session-id>
//
// Then, in another shell:
//
//   systemctl --user restart arbiter
//
// A working result is the final line:
//
//   RESULT: PASS — frames=… bytes=… reconnects=1 gaps=0 duplicates=0
//
// `gaps=0` is the criterion: every byte the pane produced while arbiter was
// down was still delivered, in order, exactly once. `reconnects >= 1` is
// checked too, so a run where the restart never happened FAILS loudly rather
// than passing vacuously.
//
// No npm install, deliberately: Node 22+ has a built-in `WebSocket`, and
// `phoenix.mjs` is already on disk as a Mix dependency (RFC §6.1 — this repo
// has no npm and is not getting one).

import { Socket } from "../deps/phoenix/priv/static/phoenix.mjs"

import { SessionStream } from "../apps/arbiter_web/assets/js/session_stream.mjs"

function usage(message) {
  console.error(`${message}

Usage:
  node scripts/verify_session_transport.mjs --session <id> [options]

Options:
  --session <id>     Session row id to attach to (required). See \`arb session list\`
  --url <ws-url>     Socket mount point, default ws://127.0.0.1:4848/session
                     (phoenix.js appends /websocket itself)
  --token <token>    Scope token; only needed off-loopback (§10.4)
  --seconds <n>      Stop and report after n seconds (default: run until ^C)
  --until-bytes <n>  Stop and report once n terminal bytes have been counted
  --cols <n>         Join width, default 80
  --rows <n>         Join height, default 24
  --echo             Write the terminal bytes to stdout, not just the tally
`)
  process.exit(2)
}

const argv = process.argv.slice(2)
const opts = { url: "ws://127.0.0.1:4848/session", cols: "80", rows: "24" }

for (let i = 0; i < argv.length; i++) {
  const arg = argv[i]
  if (!arg.startsWith("--")) usage(`unexpected argument: ${arg}`)

  const name = arg.slice(2)
  if (name === "echo") {
    opts.echo = true
  } else {
    const value = argv[++i]
    if (value === undefined) usage(`--${name} needs a value`)
    opts[name] = value
  }
}

if (!opts.session) usage("--session is required")

const state = {
  frames: 0,
  bytes: 0,
  gaps: 0,
  gapBytes: 0,
  duplicates: 0,
  repaints: 0,
  errors: [],
  preJoinSocketErrors: 0,
  done: false
}

// How many failed connection attempts to tolerate *before the first successful
// join*. After a join, a failing socket is the expected middle of the run (the
// server is restarting) and is tolerated indefinitely. Before one, it is a bad
// --url, a refused upgrade or a rejected --token, and there is nothing to
// resume — so the script says so rather than retrying until the operator
// notices. At the socket's backoff this is a little under four seconds.
const MAX_PRE_JOIN_SOCKET_ERRORS = 5

function note(line) {
  // Everything diagnostic goes to stderr so `--echo` keeps stdout a clean
  // copy of the terminal stream.
  console.error(line)
}

// An ErrorEvent stringifies to "[object ErrorEvent]", which says nothing; the
// cause is on `.error`, and for a connect failure that is where the
// ECONNREFUSED / 403 actually lives.
function describe(err) {
  if (!err) return "unknown"
  const cause = err.error || err
  return cause.message || cause.code || cause.reason || String(err)
}

const socket = new Socket(opts.url, {
  transport: WebSocket,
  params: opts.token ? { token: opts.token } : {},
  // Reconnect briskly — the point is to be back before the operator is.
  reconnectAfterMs: (tries) => [100, 250, 500, 1000][tries - 1] || 1000
})

const stream = new SessionStream({
  socket,
  sessionId: opts.session,
  geometry: () => ({ cols: Number(opts.cols), rows: Number(opts.rows) }),
  sink: {
    // `payload` is already trimmed of anything at or below the last rendered
    // byte — the same suppression the browser applies before handing bytes to
    // xterm — so this tally is a tally of what a *terminal* would have drawn.
    write(payload, info) {
      if (info.gap > 0) {
        state.gaps++
        state.gapBytes += info.gap
        note(`GAP: ${info.gap} byte(s) missing before seq ${info.start}`)
      }

      if (info.skipped > 0) {
        state.duplicates++
        note(`DUPLICATE: frame ending at ${info.seq} re-sent ${info.skipped} byte(s)`)
      }

      state.frames++
      state.bytes += payload.length
      if (opts.echo) process.stdout.write(Buffer.from(payload))

      if (opts["until-bytes"] && state.bytes >= Number(opts["until-bytes"])) finish()
    },

    repaint(seq, data, info) {
      // A snapshot is a repaint: the byte stream restarts at `seq`, so the
      // continuity arithmetic restarts with it rather than reporting a false
      // gap. A repaint on a *re*join is not a pass — criterion 8 asks for
      // gapless resume, and a repaint means the ring and the pipe file both
      // failed to cover the outage.
      if (info.rejoin) {
        state.repaints++
        note(`REPAINT: resumed with a snapshot at seq ${seq} instead of a replay`)
      }
      if (opts.echo) process.stdout.write(data)
    },

    joined(reply) {
      note(`joined (#${stream.joins}): ${JSON.stringify(reply)}`)
    },

    status(value) {
      if (value === "reconnecting") note(`socket dropped at seq ${stream.lastSeq} — will resume`)
    },

    meta(meta) {
      note(`meta: ${JSON.stringify(meta)}`)
    },

    exit(payload) {
      note(`exit: ${JSON.stringify(payload)} — the session ended, so the run stops here`)
      finish()
    },

    error(err) {
      // Socket-level errors are expected while the server is down: every
      // reconnect attempt against a stopped listener is one. Once we have
      // joined at least once they are noted and never counted — that is
      // criterion 8's whole middle section. Before the first join they mean
      // we never got in at all, and retrying forever would hang.
      if (err && err.code === "socket_error") {
        note(`socket error: ${describe(err.detail)}`)

        if (stream.joins === 0 && ++state.preJoinSocketErrors >= MAX_PRE_JOIN_SOCKET_ERRORS) {
          state.errors.push(
            `could not connect to ${opts.url} after ${state.preJoinSocketErrors} attempts` +
              ` (last: ${describe(err.detail)})`
          )
          finish()
        }

        return
      }

      state.errors.push(JSON.stringify(err))
      note(`error event: ${JSON.stringify(err)}`)

      // A refused join is terminal: phoenix.js re-joins on its own timer
      // forever, so a bad --session, an already-ended session or a token the
      // channel will not take would otherwise leave this script spinning
      // silently. It is the instrument criterion 8 is measured with, and a
      // hang is the worst way for an instrument to fail.
      if (err && err.join_refused) {
        note("the channel refused the join — retrying cannot fix that, so the run stops here")
        finish()
      }
    }
  }
})

stream.connect()

function finish() {
  if (state.done) return
  state.done = true

  const failures = []
  if (state.gaps > 0) failures.push(`${state.gaps} gap(s), ${state.gapBytes} byte(s) lost`)
  if (state.duplicates > 0) failures.push(`${state.duplicates} duplicate frame(s)`)
  if (state.repaints > 0)
    failures.push(`${state.repaints} repaint(s) — resume fell back to a snapshot`)
  if (state.errors.length > 0) failures.push(`errors: ${state.errors.join("; ")}`)
  if (stream.reconnects === 0) {
    failures.push("no reconnect happened — nothing was restarted, so nothing was proven")
  }

  const tally =
    `frames=${state.frames} bytes=${state.bytes} seq=${stream.lastSeq} ` +
    `reconnects=${stream.reconnects} gaps=${state.gaps} duplicates=${state.duplicates}`

  if (failures.length === 0) {
    note(`RESULT: PASS — ${tally}`)
  } else {
    note(`RESULT: FAIL — ${tally}\n  ${failures.join("\n  ")}`)
  }

  stream.dispose()
  process.exit(failures.length === 0 ? 0 : 1)
}

process.on("SIGINT", finish)
process.on("SIGTERM", finish)

if (opts.seconds) setTimeout(finish, Number(opts.seconds) * 1000)

// Hold the event loop open. A run with no `--seconds` waits for ^C; one with
// it still needs the loop alive between frames.
setInterval(() => {}, 1 << 30)
