#!/bin/bash
# agentsh installation script for Sprites.dev
# https://github.com/canyonroad/agentsh-sprites
set -euo pipefail

AGENTSH_VERSION="${AGENTSH_VERSION:-0.8.10}"
AGENTSH_REPO="https://github.com/canyonroad/agentsh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "Must run as root (try: sudo ./install.sh)"
    exit 1
fi

# Detect if running via curl pipe or from cloned repo
if [[ -f "${SCRIPT_DIR}/config.yaml" ]]; then
    CONFIG_SOURCE="local"
    log_info "Installing from local repository"
else
    CONFIG_SOURCE="remote"
    log_info "Installing from remote (curl pipe mode)"
    REMOTE_BASE="https://raw.githubusercontent.com/canyonroad/agentsh-sprites/main"
fi

log_info "Installing agentsh v${AGENTSH_VERSION} for Sprites.dev"

# Step 1: Install dependencies
log_info "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq curl libseccomp2 > /dev/null

# Step 2: Download and install agentsh
log_info "Downloading agentsh v${AGENTSH_VERSION}..."
DEB_URL="${AGENTSH_REPO}/releases/download/v${AGENTSH_VERSION}/agentsh_${AGENTSH_VERSION}_linux_amd64.deb"
curl -sSL "${DEB_URL}" -o /tmp/agentsh.deb

log_info "Installing agentsh..."
dpkg -i /tmp/agentsh.deb > /dev/null
rm /tmp/agentsh.deb

# Step 3: Create directory structure
log_info "Creating directory structure..."
mkdir -p /etc/agentsh/policies
mkdir -p /var/lib/agentsh/sessions
mkdir -p /var/lib/agentsh/quarantine
mkdir -p /var/log/agentsh

# Step 4: Copy configuration files
log_info "Installing configuration files..."
if [[ "${CONFIG_SOURCE}" == "local" ]]; then
    cp "${SCRIPT_DIR}/config.yaml" /etc/agentsh/config.yaml
    cp "${SCRIPT_DIR}/policies/default.yaml" /etc/agentsh/policies/default.yaml
else
    curl -sSL "${REMOTE_BASE}/config.yaml" -o /etc/agentsh/config.yaml
    curl -sSL "${REMOTE_BASE}/policies/default.yaml" -o /etc/agentsh/policies/default.yaml
fi

# Step 5: Set correct permissions
log_info "Setting permissions..."
chmod 644 /etc/agentsh/config.yaml
chmod 644 /etc/agentsh/policies/default.yaml
chmod 755 /var/lib/agentsh/sessions
chmod 755 /var/lib/agentsh/quarantine
chmod 755 /var/log/agentsh

# Step 6: Install shell shim
log_info "Installing shell shim..."
agentsh shim install-shell \
    --shim /usr/bin/agentsh-shell-shim \
    --bash \
    --i-understand-this-modifies-the-host

# Step 7: Set up environment
log_info "Configuring environment..."

# Step 8: Start agentsh server
log_info "Starting agentsh server..."
cd /etc/agentsh
nohup agentsh server > /var/log/agentsh/server.log 2>&1 &
sleep 2

# Verify server is running
if curl -s http://127.0.0.1:18080/health > /dev/null 2>&1; then
    log_info "Server started successfully"
else
    log_warn "Server may not have started - check /var/log/agentsh/server.log"
fi

# Step 9: Detect platform capabilities
log_info "Detecting platform capabilities..."
agentsh detect 2>&1 | tee /var/log/agentsh/detect.log || log_warn "Detect command failed"

# Step 10: Create a persistent session
log_info "Creating persistent session..."
SESSION_JSON=$(agentsh session create --workspace /home/sprite --json 2>/dev/null)
SESSION_ID=$(echo "$SESSION_JSON" | grep -o '"id": *"[^"]*"' | head -1 | sed 's/"id": *"//' | sed 's/"$//')

if [[ -n "$SESSION_ID" ]]; then
    log_info "Session created: $SESSION_ID"
    # Export session ID in environment for all users
    cat > /etc/profile.d/agentsh.sh << EOF
export AGENTSH_SERVER="http://127.0.0.1:18080"
export AGENTSH_SESSION_ID="$SESSION_ID"
EOF
    chmod 644 /etc/profile.d/agentsh.sh
else
    log_warn "Could not create session - shim will create sessions on demand"
    cat > /etc/profile.d/agentsh.sh << 'EOF'
export AGENTSH_SERVER="http://127.0.0.1:18080"
EOF
    chmod 644 /etc/profile.d/agentsh.sh
fi

echo ""
log_info "============================================"
log_info "agentsh installation complete!"
log_info "============================================"
echo ""
echo "Next steps:"
echo "  1. Verify installation:  ./scripts/verify.sh"
echo "     (or if installed via curl: agentsh --version)"
echo ""
echo "  2. Checkpoint your Sprite to persist this setup:"
echo "     sprite checkpoint <your-sprite-name>"
echo ""
echo "  3. Test policy enforcement:"
echo "     agentsh exec -- ls /     # Should work"
echo "     agentsh exec -- sudo su  # Should be blocked"
echo ""

exit 0
