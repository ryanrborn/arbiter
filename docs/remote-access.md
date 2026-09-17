# Remote access to the Arbiter dashboard and browser sessions

The Arbiter dashboard and browser-based session terminal are **loopback-only** by design — they bind to `127.0.0.1:4848` and do not accept off-network connections. To use the dashboard and terminal from another device (e.g., accessing an Arbiter instance on an AWS dev box from a laptop), forward the port over SSH.

SSH provides both authentication (implicit) and encryption, and the forwarded connection appears to Arbiter as loopback traffic, so all existing security properties hold.

## Quick start: one-off SSH tunnel

Forward port 4848 from the remote machine to your local machine:

```sh
ssh -L 4848:127.0.0.1:4848 user@remote-host
```

Then visit `http://127.0.0.1:4848` on your local machine. The tunnel stays open while the SSH session is active.

## Persistent SSH configuration

To avoid typing the tunnel command every time, add a `LocalForward` directive to your SSH config (`~/.ssh/config`):

```
Host arbiter-dev
  HostName remote-host
  User user
  LocalForward 4848 127.0.0.1:4848
```

Then connect with:

```sh
ssh arbiter-dev
```

The port forward is set up automatically each time you connect.

## Automatic reconnection with autossh

If your SSH session disconnects frequently, use `autossh` to maintain the tunnel automatically:

```sh
autossh -M 20000 -L 4848:127.0.0.1:4848 user@remote-host
```

Replace `20000` with an unused port for health checks. `autossh` monitors the connection and reconnects if it drops.

## VS Code Remote-SSH

If you use [VS Code Remote-SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh), port forwarding is set up automatically when you open a remote folder. Once connected, you can access `http://127.0.0.1:4848` from your local browser.

## Closing the port after tunneling

Once you're done accessing the dashboard and terminal, close port 4848 on the remote machine's firewall or security group to prevent unintended access:

- **Cloud security group (AWS, GCP, etc.):** Remove or disable the ingress rule for port 4848
- **Host firewall (ufw, firewalld, etc.):** Ensure `iptables` rules or firewall rules do not expose 4848
- By default, Arbiter binds to loopback only, so it is not exposed without explicit firewall configuration

## Alternative: Remote Control (mode B)

For persistent, multi-session access with full browser support and auditing, consider [Remote Control mode](/docs/browser-hosted-coordinator-sessions.md#8-remote-control-sessions-research-task-4) (launched with `--remote-control`). SSH tunneling is simpler for temporary or single-machine access.

## Trust assumption: loopback means the same Unix user (bd-5b5hq7)

"Loopback" here is a **convenience boundary, not a sandbox**. `ArbiterWeb.Plugs.ApiAuth` lets any request from `127.0.0.1` (or `::1`) reach the `/api` pipeline without a bearer token specifically so the local `arb` CLI and an `arb init` checkout's `.mcp.json` work with zero setup — no token to mint, copy, or rotate before the very first command.

That convenience is only as safe as "loopback = trusted" actually holds, and on this host it holds because every process that can reach `127.0.0.1:4848` — the operator's own shell, `arb`, and every Arbiter session (including a browser-hosted one) — runs as the **same Unix user**. There is no sandbox, container, or separate user boundary between a browser session and the operator's own tooling; a session can read anything the operator's user can read, including `/proc/<pid>/environ` of sibling processes and any dotfile on disk. A real boundary would need a separate Unix user or a sandbox, and that is out of scope here.

Given that, unauthenticated loopback minting (`POST /api/mcp/tokens` with no `Authorization` header, still returning a full-power coordinator token) is a **deliberate, retained trust assumption**, not an oversight — closing it would mean requiring an operator credential file even for same-user, same-box calls, which adds setup for the CLI and every non-Arbiter Claude Code session without producing a real boundary (the file is just as readable as anything else on that Unix user's account). What *is* addressed (bd-5b5hq7) is **casual or accidental** escalation from inside a session:

  * a request that *does* present a bearer token — including a session's own `arb` calling over loopback with its own token — can never mint a token more powerful than itself (`ArbiterWeb.Api.McpController.mint_token/2` inherits the caller's `session_id`, workspace binding, and `can_dispatch` ceiling);
  * inside a session, `arb` always authenticates with the session's own token rather than riding the anonymous-loopback path (`ArbiterCli.Client`, env var `ARB_SESSION_ID`);
  * the session's generated `settings.json` denies `Bash(arb mcp token mint:*)` outright.

None of this stops a session that goes out of its way to curl the API directly with no `Authorization` header — that path is unauthenticated by design, for the reason above. The guardrail is at the same level as the session's own `CLAUDE.md` rules: it stops the *accidental* path (following the `arb init` runbook, or reaching for `arb mcp token mint` out of habit), not a determined one. If Arbiter sessions ever run as a separate Unix user from the operator, this trust assumption should be revisited — at that point unauthenticated loopback access would cross an actual user boundary, not just a convenience one.
