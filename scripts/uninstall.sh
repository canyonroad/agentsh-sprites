#!/bin/bash
# Uninstall agentsh from Sprites.dev
# https://github.com/canyonroad/agentsh-sprites
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "Must run as root (try: sudo ./uninstall.sh)"
    exit 1
fi

echo "=== agentsh Uninstaller for Sprites ==="
echo ""
log_warn "This will remove agentsh and restore the original shell."
echo ""
read -p "Are you sure you want to continue? [y/N] " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "Aborted."
    exit 0
fi

# Step 1: Stop the server
log_info "Stopping agentsh server..."
pkill -f "agentsh server" 2>/dev/null || true

# Step 2: Remove shell shim
log_info "Removing shell shim..."
agentsh shim uninstall-shell --bash --i-understand-this-modifies-the-host 2>/dev/null || true

# Step 3: Remove agentsh package
log_info "Removing agentsh package..."
dpkg --remove agentsh 2>/dev/null || apt-get remove -y agentsh 2>/dev/null || true

# Step 4: Remove configuration
log_info "Removing configuration files..."
rm -rf /etc/agentsh

# Step 5: Optionally remove data (ask user)
echo ""
read -p "Remove session data and logs? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log_info "Removing data directories..."
    rm -rf /var/lib/agentsh
    rm -rf /var/log/agentsh
else
    log_info "Keeping data directories."
fi

# Step 6: Remove environment
log_info "Removing environment configuration..."
rm -f /etc/profile.d/agentsh.sh

echo ""
log_info "=== Uninstall complete ==="
echo ""
echo "agentsh has been removed. You may want to:"
echo "  1. Create a new checkpoint without agentsh"
echo "  2. Or restore from a previous checkpoint"
echo ""
