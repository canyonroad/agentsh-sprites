# agentsh-sprites Design Document

**Date:** 2026-01-16
**Status:** Approved
**Purpose:** Installation scripts and policy for running agentsh on Sprites.dev

## Overview

This project provides installation scripts and security policies to run agentsh on Sprites.dev, enabling secure AI agent sandbox environments. Unlike the Daytona integration (which uses Dockerfiles), Sprites requires a runtime installation approach with checkpoint/restore for persistence.

## Use Case

AI agent sandbox with high-security containment for running untrusted AI agent code (Claude Code, Codex, Gemini CLI, etc.) with policy enforcement.

## Repository Structure

```
agentsh-sprites/
├── README.md              # Documentation with both install methods
├── install.sh             # Main installation script
├── config.yaml            # agentsh server configuration
├── policies/
│   └── default.yaml       # Sprites-optimized security policy
├── scripts/
│   ├── verify.sh          # Post-install verification
│   └── uninstall.sh       # Cleanup script
└── examples/
    └── test-policy.py     # Python script to test policy enforcement
```

## Installation Flow

1. User creates a fresh Sprite: `sprite create my-agent-env`
2. Connects: `sprite console -s my-agent-env`
3. Runs install script (curl or git clone method)
4. Script installs agentsh, copies config/policies, installs shell shim
5. User runs `verify.sh` to confirm everything works
6. User checkpoints the Sprite: `sprite checkpoint my-agent-env`
7. Future sessions restore from checkpoint with agentsh ready

### Install Methods

**Option A - Single curl command:**
```bash
curl -sSL https://raw.githubusercontent.com/canyonroad/agentsh-sprites/main/install.sh | sudo bash
```

**Option B - Git clone:**
```bash
git clone https://github.com/canyonroad/agentsh-sprites.git
cd agentsh-sprites
sudo ./install.sh
```

## Install Script (`install.sh`)

```bash
#!/bin/bash
set -euo pipefail

AGENTSH_VERSION="${AGENTSH_VERSION:-0.7.3}"
REPO_URL="https://github.com/canyonroad/agentsh"

# 1. Check we're running as root (required for shim)
if [[ $EUID -ne 0 ]]; then
    echo "Error: Must run as root (try: sudo ./install.sh)"
    exit 1
fi

# 2. Install dependencies
apt-get update && apt-get install -y curl libseccomp2

# 3. Download and install agentsh
curl -sSL "${REPO_URL}/releases/download/v${AGENTSH_VERSION}/agentsh_${AGENTSH_VERSION}_linux_amd64.deb" \
    -o /tmp/agentsh.deb
dpkg -i /tmp/agentsh.deb
rm /tmp/agentsh.deb

# 4. Create directory structure
mkdir -p /etc/agentsh/policies
mkdir -p /var/lib/agentsh/{sessions,quarantine}
mkdir -p /var/log/agentsh

# 5. Copy configuration files
cp config.yaml /etc/agentsh/config.yaml
cp policies/default.yaml /etc/agentsh/policies/default.yaml

# 6. Install shell shim (intercepts bash/sh)
agentsh shim install-shell

# 7. Set environment for agentsh
echo 'export AGENTSH_SERVER="http://127.0.0.1:8080"' >> /etc/profile.d/agentsh.sh

echo "✓ agentsh installed. Run ./scripts/verify.sh then checkpoint your Sprite."
```

## Sprites-Optimized Policy (`policies/default.yaml`)

### Sprites-Specific Rules

| Feature | Access Level | Rationale |
|---------|--------------|-----------|
| `/.sprite/**` | Read-only | Agents can learn from skills but not modify |
| `sprite checkpoint` | Require approval | Stateful operation, user should confirm |
| `sprite *` (other CLI) | Block | Could escape sandbox or affect billing |
| Fly.io metadata (`169.254.169.254`, `*.internal`) | Block | Security - prevent credential theft |

### File Access

```yaml
files:
  # Workspace - full access with soft-delete protection
  - path: "/home/**/workspace/**"
    access: read-write
    soft_delete: true

  # Sprites skills folder - read-only for agents to learn
  - path: "/.sprite/**"
    access: read-only

  # Temp directories
  - path: "/tmp/**"
    access: read-write

  # System paths - read-only
  - path: "/usr/**"
    access: read-only

  # Credentials - require approval
  - path: "**/.ssh/**"
    access: approve
  - path: "**/.aws/**"
    access: approve
  - path: "**/.env*"
    access: approve
```

### Command Rules

```yaml
commands:
  # Sprite CLI - checkpoint needs approval, others blocked
  - pattern: "sprite checkpoint*"
    action: approve
    reason: "Checkpointing saves state - confirm this is intentional"

  - pattern: "sprite *"
    action: deny
    reason: "Sprite CLI access restricted in sandbox"

  # Block privilege escalation
  - pattern: "sudo *"
    action: deny
  - pattern: "su *"
    action: deny

  # Allow safe utilities
  - pattern: "ls *"
    action: allow
  - pattern: "cat *"
    action: allow
  - pattern: "grep *"
    action: allow
  - pattern: "find *"
    action: allow

  # Allow dev tools
  - pattern: "git *"
    action: allow
  - pattern: "node *"
    action: allow
  - pattern: "python *"
    action: allow
  - pattern: "npm *"
    action: approve
  - pattern: "pip *"
    action: approve

  # Block dangerous commands
  - pattern: "rm -rf /*"
    action: deny
  - pattern: "nc *"
    action: deny
  - pattern: "ssh *"
    action: deny
```

### Network Rules

```yaml
network:
  # Allow localhost
  - host: "127.0.0.1"
    action: allow
  - host: "localhost"
    action: allow

  # Allow package registries
  - host: "registry.npmjs.org"
    action: allow
  - host: "pypi.org"
    action: allow
  - host: "files.pythonhosted.org"
    action: allow
  - host: "crates.io"
    action: allow

  # Block cloud metadata (including Fly.io)
  - host: "169.254.169.254"
    action: deny
    reason: "Cloud metadata access blocked"
  - host: "*.internal"
    action: deny
    reason: "Fly.io internal network blocked"

  # Block private networks
  - host: "10.0.0.0/8"
    action: deny
  - host: "192.168.0.0/16"
    action: deny
  - host: "172.16.0.0/12"
    action: deny

  # Unknown HTTPS - require approval
  - port: 443
    action: approve
  - port: 80
    action: approve
```

### Resource Limits

```yaml
resources:
  memory_limit_mb: 2048
  cpu_percent: 50
  max_processes: 100
  command_timeout: 5m
  session_timeout: 1h
```

## Server Configuration (`config.yaml`)

```yaml
server:
  http:
    address: "127.0.0.1:8080"
    read_timeout: 30s
    write_timeout: 60s
  grpc:
    enabled: true
    address: "127.0.0.1:9090"
  auth:
    enabled: false

sessions:
  directory: "/var/lib/agentsh/sessions"
  max_concurrent: 50
  default_timeout: 1h
  idle_timeout: 15m
  cleanup_interval: 5m

policies:
  directory: "/etc/agentsh/policies"
  default: "default.yaml"

sandbox:
  enabled: true
  memory_limit_mb: 4096
  cpu_percent: 100
  seccomp: true
  cgroups: false

quarantine:
  directory: "/var/lib/agentsh/quarantine"
  retention: 7d

audit:
  enabled: true
  backend: sqlite
  path: "/var/log/agentsh/audit.db"
  retention: 90d

dlp:
  enabled: true
  mode: redact
  patterns:
    - name: openai_key
      regex: "sk-[a-zA-Z0-9]{48}"
    - name: anthropic_key
      regex: "sk-ant-[a-zA-Z0-9-]{95}"
    - name: aws_key
      regex: "AKIA[0-9A-Z]{16}"
    - name: github_token
      regex: "gh[ps]_[a-zA-Z0-9]{36}"
    - name: private_key
      regex: "-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----"
    - name: jwt
      regex: "eyJ[a-zA-Z0-9_-]*\\.eyJ[a-zA-Z0-9_-]*\\.[a-zA-Z0-9_-]*"

metrics:
  enabled: true
  address: "127.0.0.1:9091"

health:
  enabled: true
  address: "127.0.0.1:8081"
```

## Verification Script (`scripts/verify.sh`)

```bash
#!/bin/bash
set -e

echo "=== agentsh Sprites Installation Verification ==="

# 1. Check agentsh binary
echo -n "agentsh binary: "
agentsh --version && echo "✓"

# 2. Check shim installed
echo -n "Shell shim: "
if file /bin/bash | grep -q "agentsh"; then
    echo "✓ installed"
else
    echo "✗ not installed"
    exit 1
fi

# 3. Check config exists
echo -n "Config file: "
[[ -f /etc/agentsh/config.yaml ]] && echo "✓" || exit 1

# 4. Check policy exists
echo -n "Policy file: "
[[ -f /etc/agentsh/policies/default.yaml ]] && echo "✓" || exit 1

# 5. Test policy enforcement
echo -n "Policy enforcement: "
if agentsh exec -- echo "test" >/dev/null 2>&1; then
    echo "✓ working"
else
    echo "✗ failed"
    exit 1
fi

echo ""
echo "=== All checks passed ==="
echo "Now checkpoint your Sprite:"
echo "  sprite checkpoint <your-sprite-name>"
```

## Differences from agentsh-daytona

| Aspect | Daytona | Sprites |
|--------|---------|---------|
| Image creation | Dockerfile | Install script + checkpoint |
| Persistence | Container rebuild | Checkpoint/restore |
| Max sessions | 100 (multi-tenant) | 50 (single-user) |
| Seccomp | Disabled (Docker constraints) | Enabled (real VM) |
| Sprites-specific rules | N/A | `/.sprite` read-only, sprite CLI blocked |
| Metadata blocking | AWS/GCP/Azure | Fly.io (`*.internal`) |

## Implementation Plan

1. Create repository structure
2. Write `install.sh` with curl-pipe support
3. Write `config.yaml`
4. Write `policies/default.yaml` with Sprites-specific rules
5. Write `scripts/verify.sh`
6. Write `scripts/uninstall.sh`
7. Write `examples/test-policy.py`
8. Write `README.md` with both install methods
9. Test on a real Sprite
