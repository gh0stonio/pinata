# SSH connections

Piñata can register a Git repository that lives on an SSH host. Connections store only a display name and an existing SSH alias. Credentials, keys, host verification, and configuration remain owned by OpenSSH.

## Setup

1. Add a host alias to `~/.ssh/config` and verify it with `ssh <alias>`.
2. In Settings → Connections, Piñata groups configured aliases into remote hosts and hides Git-only transport entries. Enable the host you want to use. Enabled hosts show a live `Connected`, `Checking`, or `Disconnected` status from a non-interactive SSH probe.
3. Open the enabled host, choose **Browse remote folders**, then register the Git repository from its root folder.

Piñata uses `ssh -o BatchMode=yes`. Interactive password prompts are deliberately unsupported. Configure an SSH agent or key authentication first.

## Repository lifecycle

```mermaid
flowchart LR
  C[Saved SSH alias] --> R[Remote registered repository]
  R --> F[Fetch remote base branch]
  F --> B[Create configured-prefix branch]
  B --> W[Create remote worktree]
  W --> T[SSH-backed terminal]
```

Worktrees use the same configured global or repository-specific base path. `~/` remains a remote path and is expanded by the remote shell, never by the Mac.

Removing an attached remote repository removes its verified Piñata worktree and task branch on that same host, using the configured task branch prefix. Piñata will not remove an unverified remote path.

## Durable terminals

An SSH terminal attaches directly to `zmx` on the remote host: `ssh -tt <alias> zmx attach <pane-id>`. Closing Piñata disconnects the SSH client, while zmx retains the remote shell and terminal state. Reopening Piñata attaches to the same session. A dropped SSH connection is retried automatically against that same session.

If the Mac restarts, remote zmx sessions remain available. If the remote host restarts, no terminal process can be recovered exactly. Piñata restores the pane and starts a fresh remote session.

## Remote file browsing

The right Files panel browses an SSH-backed worktree through the same saved OpenSSH alias. It loads folders on demand and prefetches a bounded two-level neighborhood instead of enumerating the repository. The connection settings browser warms the home-folder listing, keeps a short-lived in-memory cache, and reuses an SSH control connection for nearby folder requests.

When the Files panel, application, and window are visible, Piñata checks lightweight signatures for the root and visible expanded folders every two seconds. It requests a new listing only for changed directories. Closing the panel, switching tabs, minimizing the window, or changing workspace stops this work.

Listings use NUL-delimited records so tabs and newlines in remote filenames remain valid. Folder type comes from the remote filesystem and does not depend on the entry name. A transient SSH failure is retried on the next polling interval.

Cached descendants are exposed only after the current remote root is validated. A connection or folder-read failure hides cached children and shows an error with Retry, so stale data is never presented as current remote state.

## Limits

Piñata bundles zmx locally. Before opening a remote terminal, it checks the host for zmx and offers to install pinned zmx `0.7.0` in `~/.local/bin`. The installer supports macOS and Linux on arm64 and x86_64, requires `curl`, and verifies the archive checksum. Piñata supports existing SSH aliases, remote Git inspection, file browsing, worktree provisioning and cleanup, and durable SSH terminal panes. Connection editing, interactive SSH authentication, and port forwarding are intentionally out of scope.
