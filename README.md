# agentsh + Sprites

Runtime security governance for AI agents using [agentsh](https://github.com/canyonroad/agentsh) v0.10.4 with [Sprites.dev](https://sprites.dev) sandboxes.

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
| VM-level process isolation | Command blocking (seccomp) |
| Firecracker filesystem isolation | File I/O policy (FUSE) |
| VM networking boundaries | Domain allowlist/blocklist |
| Full Linux capabilities | Cloud metadata blocking |
| | Environment variable filtering |
| | Secret detection and redaction (DLP) |
| | Sprites CLI escape prevention |
| | LLM request auditing |
| | Complete audit logging |

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
# Full demo (creates sprite, runs 115 tests, cleans up)
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

**Non-interactive bypass:** The shim automatically detects non-TTY stdin and bypasses policy. This means `sprite exec` operator commands work without interference, and binary data piped through the shell is preserved byte-for-byte. Set `AGENTSH_SHIM_FORCE=1` to override this for sandbox APIs that need policy enforcement on non-interactive commands.

## Configuration

Security policy is defined in two files:

- **`config.yaml`** — Server configuration: network interception, DLP patterns, LLM proxy, FUSE settings, seccomp
- **`policies/default.yaml`** — Policy rules: command rules, network rules, file rules, environment policy

Key environment variables (set in `/etc/profile.d/agentsh.sh`):

| Variable | Default | Description |
|----------|---------|-------------|
| `AGENTSH_CLIENT_TIMEOUT` | `5m` | HTTP client timeout for `agentsh exec` |
| `AGENTSH_SHIM_FORCE` | Unset | Set `1` to enforce policy for non-interactive commands |
| `AGENTSH_SHIM_DEBUG` | Unset | Set `1` for shim debug output to stderr |

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
│   ├── demo.sh             # Policy enforcement demo (115 tests)
│   ├── verify.sh           # Post-install verification
│   └── uninstall.sh        # Cleanup script
└── examples/
    └── test-policy.py      # Policy test suite
```

## Testing

```bash
./scripts/demo.sh              # Full demo (115 tests, creates + destroys sprite)
./scripts/demo.sh --keep       # Keep sprite after demo for manual testing
./scripts/demo.sh --skip-setup # Run tests on existing sprite with agentsh
./scripts/verify.sh            # Post-install verification (run inside sprite)
```

## Related Projects

- [agentsh](https://github.com/canyonroad/agentsh) — Runtime security for AI agents
- [Sprites.dev](https://sprites.dev) — Stateful sandboxes from Fly.io

## License

MIT
