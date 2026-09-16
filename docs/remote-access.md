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
