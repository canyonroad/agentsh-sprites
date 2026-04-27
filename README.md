# agentsh + Sprites

Runtime security governance for AI agents using [agentsh](https://github.com/canyonroad/agentsh) v0.18.3 with [Sprites.dev](https://sprites.dev) sandboxes.

## Why agentsh + Sprites?

**Sprites provides isolation. agentsh provides governance.**

Sprites.dev sandboxes give AI agents a secure, isolated Firecracker microVM. But isolation alone doesn't prevent an agent from:

- **Exfiltrating data** to unauthorized endpoints
- **Accessing cloud metadata** (AWS/GCP/Azure credentials at `169.254.169.254`)
- **Leaking secrets** in outputs (API keys, tokens, PII)
- **Running dangerous commands** (`sudo`, `ssh`, `kill`, `nc`)
- **Reaching internal networks** (`10.x`, `172.16.x`, `192.168.x`)
- **Escaping via Sprites CLI** (`sprite console`, `sprite list`)

agentsh adds the governance layer that controls what agents can do inside the sandbox, providing defense-in-depth:

```
┌─────────────────────────────────────────────────────────┐
│  Sprites.dev Sandbox (Firecracker VM Isolation)         │
│  ┌───────────────────────────────────────────────────┐  │
│  │  agentsh (Governance)                             │  │
│  │  ┌─────────────────────────────────────────────┐  │  │
│  │  │  AI Agent                                   │  │  │
│  │  │  - Commands are policy-checked              │  │  │
│  │  │  - Network requests are filtered            │  │  │
│  │  │  - Secrets are redacted from output         │  │  │
│  │  │  - All actions are audited                  │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## What agentsh Adds

| Sprites Provides | agentsh Adds |
|---|---|
| VM-level process isolation | Command blocking (ptrace execve) |
| Firecracker filesystem isolation | File I/O policy (FUSE + ptrace file) |
| VM networking boundaries | Domain allowlist/blocklist (TCP proxy + ptrace network) |
| Full Linux capabilities | Cloud metadata blocking |
| | Environment variable filtering |
| | Secret detection and redaction (DLP) |
| | Sprites CLI escape prevention |
| | Deep process tree interception (ptrace) |
| | Non-interactive policy enforcement (shim.conf) |
| | LLM request auditing |
| | Complete audit logging |

## Security Architecture

agentsh on Sprites uses multiple enforcement layers:

```
Command Execution Flow
─────────────────────
  Agent runs command
        │
        ▼
  ┌─────────────┐     ┌──────────────┐
  │ Shell Shim   │────▶│ Command      │── blocked ──▶ exit 126
  │ /bin/bash    │     │ Policy       │
  └─────────────┘     └──────┬───────┘
                             │ allowed
                             ▼
                      ┌──────────────┐
                      │ ptrace       │── blocked ──▶ EPERM
                      │ (execve,     │
                      │  file, net,  │
                      │  signal)     │
                      └──────┬───────┘
                             │ allowed
                      ┌──────┴───────┐
                      │              │
                ┌─────▼──────┐ ┌────▼─────┐
                │ Network    │ │ FUSE     │
                │ Intercept  │ │ (workspace│
                │ (all TCP)  │ │  only)   │
                └────────────┘ └──────────┘
```

### Enforcement Layers

| Layer | Mechanism | What It Protects |
|---|---|---|
| **Command Policy** | Shell shim + `agentsh exec` | Blocks `sudo`, `ssh`, `kill`, `nc`, `sprite`, etc. |
| **Ptrace (execve)** | ptrace syscall tracer | Intercepts child process execution across the entire process tree — `env sudo`, `python -c subprocess.run(["sudo"])`, `find -exec sudo` are all caught |
| **Ptrace (network)** | ptrace connect/bind/sendto | Kernel-level network enforcement with DNS redirect and SNI rewrite, complementing the TCP intercept proxy |
| **Ptrace (file)** | ptrace openat/unlinkat | Syscall-level file access interception alongside FUSE and seccomp file_monitor |
| **Network** | TCP intercept proxy | Domain allowlist/blocklist, cloud metadata blocking, private network blocking |
| **FUSE** | Workspace FUSE mount | File I/O policy on workspace directory (read/write/soft-delete) |
| **Seccomp (file_monitor)** | seccomp-bpf user-notify | Intercepts file syscalls (openat, mkdirat, unlinkat) to enforce file_rules on system paths outside FUSE mounts |
| **DLP** | Pattern matching on output | Redacts API keys, tokens, PII, credentials from command output |
| **Env Filtering** | Variable allowlist/denylist | Blocks `AWS_*`, `*_SECRET*`, `*_TOKEN`, `DATABASE_URL`, etc. |

### Known Limitations

**System path file I/O:** agentsh v0.18.3 enables seccomp `file_monitor` with `enforce_without_fuse: true`, which intercepts file syscalls (openat, mkdirat, unlinkat, and legacy non-at variants on x86_64) and enforces `file_rules` on system paths. The v0.18.3 release also restores file-monitor configuration parity for `agentsh wrap`, while this integration continues to exercise enforcement through `agentsh exec` and the shell shim. The policy includes rules for common system files needed by commands (ld.so.cache, nsswitch.conf, etc.). Some edge cases may still hit limitations — the file I/O tests use `run_limit_test` to document these gracefully.

## Quick Start

### Prerequisites

- Sprites CLI installed and authenticated (`sprite list`)

### Option A: One-line Install

```bash
# Create a Sprite
sprite create my-agent-env
sprite console -s my-agent-env

# Install agentsh (inside the sprite)
curl -sSL https://raw.githubusercontent.com/canyonroad/agentsh-sprites/main/install.sh | sudo bash

# Checkpoint to persist the setup
exit
sprite checkpoint create -s my-agent-env
```

### Option B: Automated Setup

```bash
git clone https://github.com/canyonroad/agentsh-sprites.git
cd agentsh-sprites

# Create and setup a new sprite
./scripts/setup-sprite.sh --create my-agent-env

# Or setup an existing sprite
./scripts/setup-sprite.sh my-existing-sprite
```

### Run the Demo

```bash
# Full demo (creates sprite, runs 100 tests, cleans up)
./scripts/demo.sh

# Keep the sprite after demo for manual testing
./scripts/demo.sh --keep
```

## How It Works

agentsh replaces `/bin/bash` with a shell shim (`--bash-only`; `/bin/sh` is left untouched) that routes every interactive command through the policy engine:

```
AI agent runs:  bash -c "sudo whoami"
                  │
                  ▼
           ┌──────────────┐
           │  Shell Shim   │  /bin/bash → agentsh-shell-shim
           │  (intercepts) │  /bin/sh  → untouched
           └──────┬───────┘
                  │
          ┌───────┴───────┐
          │  TTY stdin?   │
          └───┬───────┬───┘
            yes       no
              │         │
              ▼         ▼
      ┌──────────┐  ┌──────────────┐
      │ agentsh  │  │ Real shell   │
      │ exec     │  │ (bypass)     │
      │ (policy) │  │ No policy.   │
      └────┬─────┘  │ Binary-safe. │
           │        └──────────────┘
     ┌─────┴─────┐
     ▼           ▼
 ┌────────┐ ┌────────┐
 │ ALLOW  │ │ BLOCK  │
 │ exit: 0│ │ exit:126│
 └────────┘ └────────┘
```

**Non-interactive bypass:** The shim automatically detects non-TTY stdin and bypasses policy. This means `sprite exec` operator commands work without interference, and binary data piped through the shell is preserved byte-for-byte. Set `AGENTSH_SHIM_FORCE=1` or use `/etc/agentsh/shim.conf` to override this for sandbox APIs that need policy enforcement on non-interactive commands.

## Platform Capabilities

The install script runs `agentsh detect` to probe the Sprites environment. Current results (Protection Score: **85/100**):

| Capability | Status | Notes |
|---|---|---|
| seccomp | ✓ | Full seccomp-bpf with user-notify (execve + file_monitor) |
| ptrace | ✓ | **Active backend** — execve, file, network, signal tracing |
| FUSE | ✓ | Workspace file I/O interception (fusermount3) |
| eBPF | ✓ | `cgroup_sock_addr` network monitoring (available since v0.18.0 probe fix) |
| capabilities drop | ✓ | 25/41 dropped (permitted + bounding) |
| cgroups v2 | - | Unavailable — Firecracker VM cannot write `cgroup.subtree_control` |
| Landlock | - | Requires kernel 6.7+ for network ABI |
| PID namespace | - | Agent runs in host namespace inside the sprite |

## Configuration

Security policy is defined in two files:

- **`config.yaml`** — Server configuration: network interception, DLP patterns, LLM proxy, FUSE settings, ptrace, seccomp
- **`policies/default.yaml`** — Policy rules: command rules, network rules, file rules, environment policy

Key environment variables (set in `/etc/profile.d/agentsh.sh`):

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENTSH_CLIENT_TIMEOUT` | `5m` | HTTP client timeout for `agentsh exec` |
| `AGENTSH_SHIM_FORCE` | Unset | Set `1` to enforce policy for non-interactive commands |
| `AGENTSH_SHIM_DEBUG` | Unset | Set `1` for shim debug output to stderr |

**Non-interactive enforcement:** v0.18.3 supports `/etc/agentsh/shim.conf` as a file-based alternative to `AGENTSH_SHIM_FORCE`. This is useful for sandbox APIs that execute commands without a PTY and need policy enforcement without relying on environment variables.

See the [agentsh documentation](https://github.com/canyonroad/agentsh) for the full policy reference.

## Project Structure

```
agentsh-sprites/
├── install.sh              # Main installation script
├── config.yaml             # agentsh server configuration
├── policies/
│   └── default.yaml        # Security policy (Sprites-optimized)
├── scripts/
│   ├── setup-sprite.sh     # Automated sprite setup
│   ├── demo.sh             # Policy enforcement demo (100 tests)
│   ├── verify.sh           # Post-install verification
│   └── uninstall.sh        # Cleanup script
└── examples/
    └── test-policy.py      # Policy test suite
```

## Testing

```bash
./scripts/demo.sh              # Full demo (100 tests, creates + destroys sprite)
./scripts/demo.sh --keep       # Keep sprite after demo for manual testing
./scripts/demo.sh --skip-setup # Run tests on existing sprite with agentsh
./scripts/verify.sh            # Post-install verification (run inside sprite)
```

### Test Categories

| Category | Tests | Description |
|---|---|---|
| Safe Commands | 5 | `ls`, `echo`, `pwd`, `date`, `hostname` allowed |
| Privilege Escalation | 5 | `sudo`, `su`, `chroot`, `nsenter`, `unshare` blocked |
| Sprites CLI | 2 | `sprite list`, `sprite console` blocked |
| Network Tools | 5 | `nc`, `ssh`, `telnet`, `scp`, `rsync` blocked |
| System Commands | 8 | `systemctl`, `kill`, `shutdown`, `mount`, `dd`, etc. blocked |
| File Operations | 3 | `ls /`, `cat /etc/hosts` allowed, `touch /tmp` allowed |
| Recursive Delete | 3 | `rm -rf`, `rm -r`, `rm --recursive` blocked |
| Single File Delete | 1 | `rm -f /tmp/file` allowed |
| Package Install | 2 | `npm install`, `pip install` require approval (denied without) |
| File Policy | 31 | Policy engine queries for paths, operations, credentials |
| Non-PTY Shim | 7 | `--bash-only` verification, non-interactive bypass, `SHIM_FORCE` |
| Binary Passthrough | 1 | Binary data preserved through `/bin/sh` (unshimmed) |
| Env Filtering | 7 | Allowed vars visible, secret vars filtered |
| Network Policy | 6 | Localhost allowed, metadata/private blocked, registries allowed |
| Multi-Context | 8 | Deep process tree: `env sudo`, `python subprocess`, `find -exec` |
| File I/O | 6 | System path write blocking via seccomp file_monitor |

## Related Projects

- [agentsh](https://github.com/canyonroad/agentsh) — Runtime security for AI agents
- [Sprites.dev](https://sprites.dev) — Stateful sandboxes from Fly.io

## License

MIT
