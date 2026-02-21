# agentsh-sprites

Runtime security for AI agents on [Sprites.dev](https://sprites.dev).

This repository provides installation scripts and security policies to run [agentsh](https://github.com/canyonroad/agentsh) on Sprites.dev, enabling secure sandbox environments for AI coding agents like Claude Code, Codex, and Gemini CLI.

## Why agentsh on Sprites?

Sprites.dev provides excellent VM-level isolation via Firecracker microVMs. agentsh adds **application-level policy enforcement** on top, preventing AI agents from doing dangerous things *within* the sandbox.

### What Sprites Provides (VM Isolation)

| Protection | Description |
|------------|-------------|
| Process isolation | Each sprite runs in a separate Firecracker microVM |
| Filesystem isolation | VM has its own filesystem |
| Network isolation | VM-level networking boundaries |
| Full Linux capabilities | seccomp, cgroups, eBPF, FUSE all available |

### What agentsh Adds (Policy Enforcement)

| Protection | Sprites Alone | Sprites + agentsh |
|------------|---------------|-------------------|
| Privilege escalation | Agent can run `sudo` if available | `sudo`, `su`, `chroot` **blocked** |
| Network tools | Agent can `ssh` to other hosts | `ssh`, `nc`, `telnet` **blocked** |
| Cloud metadata | Agent can access `169.254.169.254` | Metadata endpoint **blocked** |
| Destructive commands | Agent can `rm -rf /` | Recursive delete **blocked** |
| Secret exfiltration | Secrets visible in output | Secrets **redacted** (DLP) |
| Sprites CLI escape | Agent can run `sprite` commands | Sprites CLI **blocked** |
| Audit trail | No command logging | **Full audit trail** |
| Private networks | Agent can reach `10.x`, `192.168.x` | Internal networks **blocked** |

### Key Protections

**Command Blocking:**
- Privilege escalation: `sudo`, `su`, `chroot`, `nsenter`, `unshare`
- Network tools: `ssh`, `nc`, `telnet`, `scp`, `rsync`
- System control: `systemctl`, `shutdown`, `kill`, `mount`
- Destructive operations: `rm -rf` (recursive delete)
- Sprites CLI: `sprite list`, `sprite console` blocked; `sprite checkpoint` requires approval

**Network Filtering:**
- Allow: localhost, package registries (npm, PyPI, crates.io), GitHub
- Block: cloud metadata (`169.254.169.254`), private networks, Fly.io internal (`*.internal`)

**Data Loss Prevention (DLP):**
- Automatically redacts API keys, private keys, JWT tokens, and PII before output reaches AI models

**Audit & Compliance:**
- Full command audit trail with session tracking

## Quick Start

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

### Option B: Automated Setup Script

Use the setup script to create and configure a sprite in one command:

```bash
# Clone the repo first
git clone https://github.com/canyonroad/agentsh-sprites.git
cd agentsh-sprites

# Create and setup a new sprite
./scripts/setup-sprite.sh --create my-agent-env

# Or setup an existing sprite
./scripts/setup-sprite.sh my-existing-sprite
```

### Demo: See Policy Enforcement in Action

Run the demo script to see agentsh blocking dangerous commands:

```bash
# Run full demo (creates sprite, tests policies, cleans up)
./scripts/demo.sh

# Keep the sprite after demo for manual testing
./scripts/demo.sh --keep
```

## How It Works

agentsh provides runtime security by intercepting commands and enforcing policies before execution.

### Architecture

```
┌─────────────────────────────────────────┐
│           AI Agent (Claude, etc.)       │
├─────────────────────────────────────────┤
│           Shell Shim (bash-only)        │
│  /bin/bash → shim    /bin/sh → untouched│
│  TTY: enforce policy  non-TTY: bypass   │
├─────────────────────────────────────────┤
│           agentsh Server                │
│    ┌─────────────────────────────┐      │
│    │  Policy Engine              │      │
│    │  allow | deny | approve     │      │
│    └─────────────────────────────┘      │
├─────────────────────────────────────────┤
│        Sprites.dev (Firecracker VM)     │
│    Files    Network    Processes        │
└─────────────────────────────────────────┘
```

### Components

1. **Shell Shim**: Replaces `/bin/bash` to intercept shell invocations (`--bash-only`; `/bin/sh` is left untouched)
2. **agentsh Server**: Runs locally on port 18080, evaluates policies and executes commands
3. **Policy Engine**: YAML-based rules for commands, files, and network access
4. **Session Management**: Tracks agent sessions for audit and context

### Non-PTY / Non-Interactive Behavior

The shell shim (v0.10.1+) automatically detects when stdin is not a terminal and bypasses policy enforcement, executing the real shell directly. This means:

- **`sprite exec` commands** from operators work without shim interference
- **Binary data piped** through shell invocations is preserved byte-for-byte
- **System scripts** using `#!/bin/sh` are unaffected (`--bash-only` leaves `/bin/sh` untouched)

For sandbox platforms that execute commands non-interactively but still need policy enforcement (e.g., HTTP APIs), set `AGENTSH_SHIM_FORCE=1` to override the non-TTY bypass.

## What's Protected

### Commands

| Category | Examples | Action |
|----------|----------|--------|
| Safe utilities | `ls`, `cat`, `grep`, `find` | Allow |
| Dev tools | `git`, `python`, `node`, `cargo` | Allow |
| Privilege escalation | `sudo`, `su`, `pkexec`, `chroot` | Block |
| Network tools | `ssh`, `nc`, `telnet` | Block |
| System control | `systemctl`, `shutdown`, `kill` | Block |
| Sprites CLI | `sprite checkpoint` | Require approval |
| Sprites CLI | `sprite *` (other) | Block |

### Files

| Path | Access |
|------|--------|
| `/home/**` | Read-write |
| `/.sprite/**` | Read-only (agents can learn from skills) |
| `/tmp/**` | Read-write |
| `/usr/**`, `/lib/**` | Read-only |
| `~/.ssh/**`, `~/.aws/**` | Require approval |
| `**/.env*` | Require approval |

### Network

| Destination | Action |
|-------------|--------|
| `localhost` | Allow |
| Package registries (npm, PyPI, crates.io) | Allow |
| GitHub | Allow |
| Cloud metadata (`169.254.169.254`) | Block |
| Fly.io internal (`*.internal`) | Block |
| Private networks (`10.x`, `192.168.x`) | Block |

### Data Loss Prevention

Sensitive data is automatically redacted before reaching AI models:
- API keys (OpenAI, Anthropic, AWS, GitHub)
- Private keys
- JWT tokens
- Credit cards, SSNs, emails, phone numbers

## Usage

After installation, use `agentsh exec` to run commands with policy enforcement:

```bash
# Run a command through policy enforcement
agentsh exec -- ls /

# Should be blocked
agentsh exec -- sudo ls

# Run Claude Code in the sandbox
agentsh run -- claude
```

### Detecting Capabilities

Run `agentsh detect` to check which features are available on your platform:

```bash
agentsh detect
```

**Example output on Sprites.dev (February 2026):**

```
Platform: linux
Security Mode: full
Protection Score: 100%

CAPABILITIES
----------------------------------------
  capabilities_drop        ✓
  cgroups_v2               ✓
  ebpf                     ✓
  fuse                     ✓
  landlock                 -
  landlock_abi             ✓ (v0)
  landlock_network         -
  pid_namespace            -
  seccomp                  ✓
  seccomp_basic            ✓
  seccomp_user_notify      ✓

TIPS
----------------------------------------
  landlock_network: Kernel-level network restrictions disabled
    -> Requires kernel 6.7+ (Landlock ABI v4). Use proxy-based network control.
```

The detection output is also logged to `/var/log/agentsh/detect.log` during installation.

## Configuration

### Main Config: `/etc/agentsh/config.yaml`

Key settings for Sprites environment:

```yaml
server:
  http:
    addr: "127.0.0.1:18080"

sandbox:
  enabled: true
  allow_degraded: true

  # Environment injection (optional, commented out by default)
  # The bundled bash_startup.sh uses 'enable' builtin which may not
  # work in all environments. Seccomp provides equivalent protection.
  # env_inject:
  #   BASH_ENV: "/usr/lib/agentsh/bash_startup.sh"

  fuse:
    enabled: true
    deferred: true

  seccomp:
    enabled: true

  cgroups:
    enabled: false
```

### Environment Variables

These are set in `/etc/profile.d/agentsh.sh` during installation:

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENTSH_SERVER` | `http://127.0.0.1:18080` | Server address |
| `AGENTSH_SESSION_ID` | Auto-created | Session ID for policy enforcement |
| `AGENTSH_CLIENT_TIMEOUT` | `5m` | HTTP client timeout for `agentsh exec` API calls |
| `AGENTSH_SHIM_FORCE` | Unset | Set to `1` to enforce policy for non-interactive commands |
| `AGENTSH_SHIM_DEBUG` | Unset | Set to `1` for shim debug output to stderr |

### Environment Variable Policy

The policy controls which environment variables are passed to commands:

```yaml
env_policy:
  # Allowed variables (wildcards supported)
  allow:
    - "PATH"
    - "HOME"
    - "NODE_*"
    - "npm_*"
    - "CARGO_*"
    - "PYTHON*"

  # Blocked variables (overrides allow)
  deny:
    - "AWS_*"
    - "ANTHROPIC_API_KEY"
    - "OPENAI_API_KEY"
    - "*_SECRET*"
    - "*_KEY"
    - "*_PASSWORD"
    - "*_TOKEN"

  # Size limits
  max_bytes: 1000000
  max_keys: 100

  # Block env enumeration (disabled - requires env_shim_path)
  block_iteration: false
```

### Policy: `/etc/agentsh/policies/default.yaml`

Customize rules by editing the policy file:

```yaml
command_rules:
  # Allow a specific command
  - name: allow-my-tool
    commands:
      - my-custom-tool
    decision: allow

  # Block a command
  - name: block-dangerous
    commands:
      - dangerous-command
    decision: deny
```

After editing, restart the server:

```bash
pkill -f "agentsh server"
cd /etc/agentsh && nohup agentsh server > /var/log/agentsh/server.log 2>&1 &
```

## Sprites.dev Platform Capabilities

Sprites.dev runs on Firecracker microVMs. As of February 2026 (agentsh v0.10.4), the following capabilities are available:

### Available Capabilities (100% Protection Score)

| Capability | Status | Description |
|------------|--------|-------------|
| `seccomp` | ✓ | Syscall filtering via seccomp-bpf |
| `seccomp_user_notify` | ✓ | User-space syscall handling |
| `cgroups_v2` | ✓ | Resource limits and accounting |
| `fuse` | ✓ | Filesystem interception |
| `ebpf` | ✓ | Extended BPF programs |
| `capabilities_drop` | ✓ | Linux capability restrictions |
| `landlock_abi` | ✓ (v0) | Landlock security module (basic) |

### Not Available

| Capability | Reason |
|------------|--------|
| `landlock_network` | Requires kernel 6.7+ (Landlock ABI v4) |
| `pid_namespace` | VM-level isolation used instead |

### Configuration Notes

The default configuration enables FUSE and seccomp with graceful degradation:

```yaml
sandbox:
  fuse:
    enabled: true    # File operation interception in workspace
    deferred: true   # Mount on first session use
  seccomp:
    enabled: true    # Syscall filtering
  cgroups:
    enabled: false   # Available but disabled for simplicity
```

FUSE and seccomp enable file policy evaluation for operations like blocking writes to system paths and protecting sensitive files. With `allow_degraded: true`, agentsh gracefully degrades when FUSE prerequisites (fuse3) are not available. Command-level and network-level enforcement works independently.

v0.10.4 includes latency optimizations for sandboxed environments: parallel DNS resolution, parallel capability detection, and reduced mount probe timeouts. These significantly reduce first-load latency when agentsh starts after a sprite checkpoint restore.

## Files

```
agentsh-sprites/
├── install.sh              # Main installation script
├── config.yaml             # agentsh server configuration
├── policies/
│   └── default.yaml        # Security policy (Sprites-optimized)
├── scripts/
│   ├── setup-sprite.sh     # Automated sprite setup
│   ├── demo.sh             # Policy enforcement demo
│   ├── verify.sh           # Post-install verification
│   └── uninstall.sh        # Cleanup script
└── examples/
    └── test-policy.py      # Policy test suite
```

## Troubleshooting

### Server not running

```bash
# Check status
curl -s http://127.0.0.1:18080/health

# Start the server
cd /etc/agentsh && nohup agentsh server > /var/log/agentsh/server.log 2>&1 &

# View logs
tail -f /var/log/agentsh/server.log
```

### Commands timing out

The default HTTP client timeout is set to 5m via `AGENTSH_CLIENT_TIMEOUT` in `/etc/profile.d/agentsh.sh`. If commands still timeout, increase it:

```bash
# Increase timeout for very long operations
export AGENTSH_CLIENT_TIMEOUT=10m

# Or per-command
AGENTSH_CLIENT_TIMEOUT=10m agentsh exec -- npm install
```

If commands through the shim timeout, also check the server logs and verify `allow_degraded` is enabled:

```bash
tail -20 /var/log/agentsh/server.log
grep allow_degraded /etc/agentsh/config.yaml
# Should show: allow_degraded: true
```

### Non-interactive commands bypassing policy

The shell shim (v0.10.1+) automatically bypasses policy for non-interactive (non-TTY) commands. This is by design - operator commands via `sprite exec` should not be subject to agent policies.

If you need policy enforcement for non-interactive commands (e.g., HTTP API-driven sandbox execution):

```bash
export AGENTSH_SHIM_FORCE=1
```

### Policy not enforcing

```bash
# Test directly with agentsh exec
agentsh exec -- sudo ls
# Should show: command denied by policy
```

## Uninstalling

```bash
sudo ./scripts/uninstall.sh
```

This removes agentsh and restores the original shell. Create a new checkpoint afterward to persist the change.

## Related Projects

- [agentsh](https://github.com/canyonroad/agentsh) - The core runtime security tool
- [Sprites.dev](https://sprites.dev) - Stateful sandboxes from Fly.io

## License

MIT - see [LICENSE](LICENSE)
