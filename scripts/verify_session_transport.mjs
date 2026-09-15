#!/usr/bin/env node
//
// bd-3ymdvi, acceptance criterion 8 — the post-merge, coordinator-owned check
// that a terminal client survives `systemctl --user restart arbiter` with no
// lost and no duplicated output.
//
// Criterion 8 cannot be a merge gate: it needs a *running* arbiter to restart,
// and phase 5 (the browser terminal) does not exist yet, so there is no UI to
// attach with. This is the stand-in client. It speaks the same channel the
// browser will, over the same `phoenix.js` the dashboard already ships, so
// what it proves about resume is what the browser will get.
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

const MAGIC = "ARB1"
const HEADER_SIZE = 12

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
  const flag = argv[i]
  if (flag === "--echo") {
    opts.echo = true
  } else if (flag.startsWith("--")) {
    const value = argv[++i]
    if (value === undefined) usage(`${flag} needs a value`)
    opts[flag.slice(2)] = value
  } else {
    usage(`unexpected argument ${flag}`)
  }
}

if (!opts.session) usage("--session is required")

// `seq` is the byte offset of the LAST byte in the frame, so a frame of L
// bytes ending at S covers [S-L+1, S] and the previous frame must have ended
// at exactly S-L. Anything higher is a gap (bytes nobody delivered); anything
// lower is a duplicate (bytes delivered twice). That arithmetic — not a
// heuristic over the content — is what makes this check mean something.
const state = {
  seq: null,
  frames: 0,
  bytes: 0,
  gaps: 0,
  gapBytes: 0,
  duplicates: 0,
  joins: 0,
  reconnects: 0,
  snapshots: 0,
  repaints: 0,
  errors: [],
  done: false
}

function note(line) {
  // Everything diagnostic goes to stderr so `--echo` keeps stdout a clean
  // copy of the terminal stream.
  console.error(line)
}

function onStdout(buffer) {
  const view = Buffer.from(buffer)

  if (view.length < HEADER_SIZE || view.subarray(0, 4).toString("latin1") !== MAGIC) {
    state.errors.push(`unframed binary push (${view.length} bytes)`)
    return
  }

  const seq = Number(view.readBigUInt64BE(4))
  const payload = view.subarray(HEADER_SIZE)
  const start = seq - payload.length

  if (state.seq !== null) {
    if (start > state.seq) {
      state.gaps++
      state.gapBytes += start - state.seq
      note(`GAP: ${start - state.seq} byte(s) missing between seq ${state.seq} and ${start}`)
    } else if (start < state.seq) {
      state.duplicates++
      note(`DUPLICATE: frame ending at ${seq} re-sends bytes at or before seq ${state.seq}`)
    }
  }

  state.seq = seq
  state.frames++
  state.bytes += payload.length
  if (opts.echo) process.stdout.write(payload)

  if (opts["until-bytes"] && state.bytes >= Number(opts["until-bytes"])) finish()
}

const socket = new Socket(opts.url, {
  transport: WebSocket,
  params: opts.token ? { token: opts.token } : {},
  // Reconnect briskly — the point is to be back before the operator is.
  reconnectAfterMs: (tries) => [100, 250, 500, 1000][tries - 1] || 1000
})

// An ErrorEvent stringifies to "[object ErrorEvent]", which says nothing;
// the cause is on `.error`, and for a connect failure that is where the
// ECONNREFUSED / 403 actually lives.
function describe(err) {
  if (!err) return "unknown"
  const cause = err.error || err
  return cause.message || cause.code || cause.reason || String(err)
}

socket.onError((err) => note(`socket error: ${describe(err)}`))
socket.onClose((event) => {
  if (state.done) return

  const code = event && event.code
  note(`socket closed at seq ${state.seq} (code ${code}) — will resume`)

  // phoenix.js deliberately does NOT reconnect after a 1000 (normal closure),
  // and a graceful `systemctl --user restart arbiter` produces exactly that:
  // Bandit's shutdown closes every WebSocket with 1000 before the BEAM exits.
  // For a terminal client that is the wrong reading — the session outlives the
  // server by design (RFC §4.3), so a clean server close means "back shortly",
  // not "stop watching". Phase 5's hook needs this same line.
  if (code === 1000) socket.reconnectTimer.scheduleTimeout()
})

// Params as a FUNCTION, not an object: phoenix.js re-evaluates the join
// payload on every rejoin, so the reconnect after the restart carries the
// newest `last_seq` rather than replaying the one we first connected with.
// An object here would silently resume from the start of the run.
const channel = socket.channel(`session:${opts.session}`, () => ({
  last_seq: state.seq,
  cols: Number(opts.cols),
  rows: Number(opts.rows)
}))

channel.on("stdout", onStdout)

channel.on("snapshot", ({ seq, data }) => {
  state.snapshots++
  // A snapshot is a repaint: the byte stream restarts at `seq`, so the
  // continuity arithmetic restarts with it rather than reporting a false gap.
  // A repaint on a *re*join is not a pass — criterion 8 asks for gapless
  // resume, and a repaint means the ring and the pipe file both failed to
  // cover the outage.
  if (state.joins > 1) {
    state.repaints++
    note(`REPAINT: resumed with a snapshot at seq ${seq} instead of a replay`)
  }
  state.seq = seq
  if (opts.echo) process.stdout.write(data)
})

channel.on("meta", (meta) => note(`meta: ${JSON.stringify(meta)}`))

channel.on("error", (err) => {
  state.errors.push(JSON.stringify(err))
  note(`error event: ${JSON.stringify(err)}`)
})

channel.on("exit", (payload) => {
  note(`exit: ${JSON.stringify(payload)} — the session ended, so the run stops here`)
  finish()
})

channel.onError(() => {
  // Channel-level errors are the rejoin path, not a failure: the socket is
  // down and phoenix.js will re-run the params closure when it comes back.
})

channel
  .join()
  .receive("ok", (reply) => {
    state.joins++
    if (state.joins > 1) state.reconnects++
    note(`joined (#${state.joins}): ${JSON.stringify(reply)}`)
  })
  .receive("error", (err) => {
    state.errors.push(`join refused: ${JSON.stringify(err)}`)
    note(`join refused: ${JSON.stringify(err)}`)
    finish()
  })

socket.connect()

function finish() {
  if (state.done) return
  state.done = true

  const failures = []
  if (state.gaps > 0) failures.push(`${state.gaps} gap(s), ${state.gapBytes} byte(s) lost`)
  if (state.duplicates > 0) failures.push(`${state.duplicates} duplicate frame(s)`)
  if (state.repaints > 0) failures.push(`${state.repaints} repaint(s) — resume fell back to a snapshot`)
  if (state.errors.length > 0) failures.push(`errors: ${state.errors.join("; ")}`)
  if (state.reconnects === 0) {
    failures.push("no reconnect happened — nothing was restarted, so nothing was proven")
  }

  const tally =
    `frames=${state.frames} bytes=${state.bytes} seq=${state.seq} ` +
    `reconnects=${state.reconnects} gaps=${state.gaps} duplicates=${state.duplicates}`

  if (failures.length === 0) {
    note(`RESULT: PASS — ${tally}`)
  } else {
    note(`RESULT: FAIL — ${tally}\n  ${failures.join("\n  ")}`)
  }

  socket.disconnect()
  process.exit(failures.length === 0 ? 0 : 1)
}

process.on("SIGINT", finish)
process.on("SIGTERM", finish)

if (opts.seconds) setTimeout(finish, Number(opts.seconds) * 1000)

// Hold the event loop open. A run with no `--seconds` waits for ^C; one with
// it still needs the loop alive between frames.
setInterval(() => {}, 1 << 30)
