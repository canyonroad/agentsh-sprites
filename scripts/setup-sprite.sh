#!/bin/bash
# Setup a Sprite with agentsh installed
# https://github.com/canyonroad/agentsh-sprites
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <sprite-name>

Setup a Sprite with agentsh installed.

Arguments:
  sprite-name       Name of the sprite to setup

Options:
  -o, --org ORG     Organization name (default: auto-detect from sprite CLI)
  -c, --create      Create the sprite if it doesn't exist
  -f, --force       Force reinstall even if agentsh is already installed
  -h, --help        Show this help message

Examples:
  # Setup existing sprite
  $(basename "$0") my-sprite

  # Create and setup new sprite
  $(basename "$0") --create my-new-sprite

  # Specify organization
  $(basename "$0") -o my-org --create my-sprite
EOF
    exit 0
}

# Defaults
ORG=""
CREATE=false
FORCE=false
SPRITE_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--org)
            ORG="$2"
            shift 2
            ;;
        -c|--create)
            CREATE=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            ;;
        *)
            SPRITE_NAME="$1"
            shift
            ;;
    esac
done

# Validate
if [[ -z "$SPRITE_NAME" ]]; then
    log_error "Sprite name is required"
    usage
fi

# Check sprite CLI
if ! command -v sprite &> /dev/null; then
    log_error "sprite CLI not found. Install with: curl -sSL https://sprites.dev/install.sh | bash"
    exit 1
fi

# Auto-detect org if not provided
if [[ -z "$ORG" ]]; then
    log_info "Auto-detecting organization..."
    # Try to get org from sprite list output or config
    ORG=$(sprite list 2>/dev/null | head -1 | grep -oP '(?<=org=)[^ ]+' || true)
    if [[ -z "$ORG" ]]; then
        log_warn "Could not auto-detect org. Using default."
    else
        log_info "Using organization: $ORG"
    fi
fi

# Build sprite CLI args
SPRITE_ARGS=""
if [[ -n "$ORG" ]]; then
    SPRITE_ARGS="-o $ORG"
fi

# Create sprite if requested
if $CREATE; then
    log_step "Creating sprite: $SPRITE_NAME"
    if sprite $SPRITE_ARGS create "$SPRITE_NAME" 2>/dev/null; then
        log_info "Sprite created successfully"
    else
        log_warn "Sprite may already exist, continuing..."
    fi
fi

# Verify sprite exists
log_step "Verifying sprite exists..."
if ! sprite $SPRITE_ARGS exec -s "$SPRITE_NAME" -- echo "ok" &>/dev/null; then
    log_error "Cannot connect to sprite: $SPRITE_NAME"
    log_error "Make sure the sprite exists or use --create to create it"
    exit 1
fi
log_info "Connected to sprite: $SPRITE_NAME"

# Helper to run commands on sprite.
# Uses sh which is untouched by the shim (--bash-only only shims /bin/bash).
# Non-interactive commands via sprite exec also auto-bypass the bash shim
# since v0.10.1+ detects non-TTY stdin.
run_on_sprite() {
    sprite $SPRITE_ARGS exec -s "$SPRITE_NAME" -- sh -c "$1"
}

# Check if agentsh is already installed
if ! $FORCE; then
    if run_on_sprite "command -v agentsh" &>/dev/null; then
        log_info "agentsh is already installed"
        if run_on_sprite "curl -s http://127.0.0.1:18080/health 2>/dev/null | grep -q ok"; then
            log_info "agentsh server is running"
            log_info "Use --force to reinstall"
            exit 0
        fi
    fi
fi

# Create directories on sprite
log_step "Creating directories..."
run_on_sprite "mkdir -p /tmp/agentsh-sprites/policies /tmp/agentsh-sprites/scripts"

# Upload files
log_step "Uploading configuration files..."

upload_file() {
    local src="$1"
    local dst="$2"
    local encoded
    encoded=$(base64 -w0 "$src")
    run_on_sprite "echo '$encoded' | base64 -d > '$dst'"
}

upload_file "$REPO_DIR/install.sh" "/tmp/agentsh-sprites/install.sh"
upload_file "$REPO_DIR/config.yaml" "/tmp/agentsh-sprites/config.yaml"
upload_file "$REPO_DIR/policies/default.yaml" "/tmp/agentsh-sprites/policies/default.yaml"
upload_file "$REPO_DIR/scripts/verify.sh" "/tmp/agentsh-sprites/scripts/verify.sh"

run_on_sprite "chmod +x /tmp/agentsh-sprites/install.sh /tmp/agentsh-sprites/scripts/verify.sh"

log_info "Files uploaded"

# Run installation
log_step "Running agentsh installation..."
run_on_sprite "cd /tmp/agentsh-sprites && sudo ./install.sh" || {
    log_error "Installation failed"
    exit 1
}

# Verify installation
log_step "Verifying installation..."
sleep 2

if run_on_sprite "curl -s http://127.0.0.1:18080/health 2>/dev/null | grep -q ok"; then
    log_info "agentsh server is running"
else
    log_warn "Server health check failed - may need manual start"
fi

echo ""
log_info "============================================"
log_info "Setup complete for sprite: $SPRITE_NAME"
log_info "============================================"
echo ""
echo "To checkpoint this sprite (persist the setup):"
echo "  sprite $SPRITE_ARGS checkpoint create -s $SPRITE_NAME"
echo ""
echo "To connect and use:"
echo "  sprite $SPRITE_ARGS console -s $SPRITE_NAME"
echo ""
