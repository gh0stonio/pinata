# SSH connections

Piñata can register a Git repository that lives on an SSH host. Connections store only a display name and an existing SSH alias. Credentials, keys, host verification, and configuration remain owned by OpenSSH.

## Setup

1. Add a host alias to `~/.ssh/config` and verify it with `ssh <alias>`.
2. In Settings → Connections, Piñata groups configured aliases into remote hosts and hides Git-only transport entries. Enable the host you want to use.
3. Open the enabled host, choose **Browse remote folders**, then register the Git repository from its root folder.

Piñata uses `ssh -o BatchMode=yes`. Interactive password prompts are deliberately unsupported. Configure an SSH agent or key authentication first.

## Repository lifecycle

```mermaid
flowchart LR
  C[Saved SSH alias] --> R[Remote registered repository]
  R --> F[Fetch remote base branch]
  F --> B[Create pinata branch]
  B --> W[Create remote worktree]
  W --> T[SSH-backed terminal]
```

Worktrees use the same configured global or repository-specific base path. `~/` remains a remote path and is expanded by the remote shell, never by the Mac.

Removing an attached remote repository removes its verified `pinata/` worktree and branch on that same host. Piñata will not remove an unverified remote path.

## Durable terminals

An SSH terminal attaches directly to `zmx` on the remote host: `ssh -tt <alias> zmx attach <pane-id>`. Closing Piñata disconnects the SSH client, while zmx retains the remote shell and terminal state. Reopening Piñata attaches to the same session.

If the Mac restarts, remote zmx sessions remain available. If the remote host restarts, no terminal process can be recovered exactly. Piñata restores the pane and starts a fresh remote session.

## Limits

Piñata bundles zmx locally. Before opening a remote terminal, it checks the host for zmx and offers to install pinned zmx `0.7.0` in `~/.local/bin`. The installer supports macOS and Linux on arm64 and x86_64, requires `curl`, and verifies the archive checksum. It supports existing SSH aliases, remote Git inspection, worktree provisioning and cleanup, and durable SSH terminal panes. Connection editing, interactive SSH authentication, port forwarding, and remote-host process recovery are intentionally out of scope.
