#!/bin/bash
# Demo agentsh policy enforcement on Sprites
# Creates a sprite, installs agentsh, runs policy tests, then cleans up
# https://github.com/canyonroad/agentsh-sprites
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_test() { echo -e "${CYAN}[TEST]${NC} $1"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Demo agentsh policy enforcement on Sprites.

This script will:
  1. Create a temporary sprite
  2. Install agentsh with the shell shim
  3. Run policy enforcement tests
  4. Display results
  5. Optionally destroy the sprite

Options:
  -o, --org ORG         Organization name
  -n, --name NAME       Sprite name (default: agentsh-demo-TIMESTAMP)
  -k, --keep            Keep the sprite after demo (don't destroy)
  -s, --skip-setup      Skip setup, use existing sprite with agentsh
  -h, --help            Show this help message

Examples:
  # Run full demo
  $(basename "$0")

  # Run demo with specific org
  $(basename "$0") -o my-org

  # Keep sprite after demo for manual testing
  $(basename "$0") --keep
EOF
    exit 0
}

# Defaults
ORG=""
SPRITE_NAME=""
KEEP=false
SKIP_SETUP=false
TIMESTAMP=$(date +%s)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--org)
            ORG="$2"
            shift 2
            ;;
        -n|--name)
            SPRITE_NAME="$2"
            shift 2
            ;;
        -k|--keep)
            KEEP=true
            shift
            ;;
        -s|--skip-setup)
            SKIP_SETUP=true
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
            shift
            ;;
    esac
done

# Set default sprite name
if [[ -z "$SPRITE_NAME" ]]; then
    SPRITE_NAME="agentsh-demo-$TIMESTAMP"
fi

# Build sprite CLI args
SPRITE_ARGS=""
if [[ -n "$ORG" ]]; then
    SPRITE_ARGS="-o $ORG"
fi

# Cleanup function
cleanup() {
    if ! $KEEP && [[ -n "$SPRITE_NAME" ]]; then
        echo ""
        log_step "Cleaning up: destroying sprite $SPRITE_NAME"
        sprite $SPRITE_ARGS destroy -s "$SPRITE_NAME" --force 2>/dev/null || true
    fi
}

# Set trap for cleanup on exit
trap cleanup EXIT

echo ""
echo -e "${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           agentsh Policy Enforcement Demo                  ║${NC}"
echo -e "${BOLD}║                   on Sprites.dev                           ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Setup sprite
if ! $SKIP_SETUP; then
    log_step "Setting up sprite: $SPRITE_NAME"

    SETUP_ARGS=""
    if [[ -n "$ORG" ]]; then
        SETUP_ARGS="-o $ORG"
    fi

    "$SCRIPT_DIR/setup-sprite.sh" $SETUP_ARGS --create "$SPRITE_NAME"
    echo ""
fi

# Helper to run raw commands on sprite (bypassing shim)
run_on_sprite_raw() {
    sprite $SPRITE_ARGS exec -s "$SPRITE_NAME" -- bash.real -c "$1" 2>&1
}

# Verify agentsh server is running
log_step "Verifying agentsh server..."
if run_on_sprite_raw "curl -s http://127.0.0.1:18080/health 2>/dev/null | grep -q ok"; then
    log_info "Server is running"
else
    log_warn "Server not running, attempting to start..."
    run_on_sprite_raw "cd /etc/agentsh && nohup agentsh server > /var/log/agentsh/server.log 2>&1 &"
    sleep 3
    if run_on_sprite_raw "curl -s http://127.0.0.1:18080/health 2>/dev/null | grep -q ok"; then
        log_info "Server started"
    else
        log_error "Failed to start server"
        exit 1
    fi
fi

# Create test script to run all tests in batch
log_step "Creating test script on sprite..."

# Create a temporary file with the test script
# Uses #!/bin/bash.real with agentsh exec for policy enforcement
TEMP_SCRIPT=$(mktemp)
cat > "$TEMP_SCRIPT" << 'TESTSCRIPT'
#!/bin/bash.real

# Source session ID
source /etc/profile.d/agentsh.sh 2>/dev/null || true

run_test() {
    local name="$1"
    local cmd="$2"
    local expected="$3"

    local exit_code=0
    # Use agentsh exec for policy enforcement on each command
    agentsh exec -- $cmd >/dev/null 2>&1 || exit_code=$?

    local result
    if [[ $exit_code -eq 0 ]]; then
        result="allowed"
    else
        result="denied"
    fi

    echo "TEST:$name:$cmd:$expected:$result"
}

# Safe commands (should be allowed)
run_test "List files" "/bin/ls /" "allowed"
run_test "Echo command" "/bin/echo hello" "allowed"
run_test "Show current directory" "/bin/pwd" "allowed"
run_test "Date command" "/bin/date" "allowed"
run_test "Hostname command" "/bin/hostname" "allowed"

# Privilege escalation (should be denied)
run_test "sudo command" "sudo ls" "denied"
run_test "su command" "su -" "denied"
run_test "chroot command" "chroot /" "denied"

# Sprites CLI (should be denied)
run_test "sprite list" "sprite list" "denied"
run_test "sprite console" "sprite console" "denied"

# Network tools (should be denied)
run_test "netcat" "nc -h" "denied"
run_test "ssh" "ssh localhost" "denied"

# System commands (should be denied)
run_test "systemctl" "systemctl status" "denied"
run_test "kill" "kill -0 1" "denied"

# File operations via allowed commands (tests command rules, not file rules)
# Note: File-level rules (read-only, sensitive files) require FUSE which needs additional config
run_test "List directory" "/bin/ls /" "allowed"
run_test "Read file" "/bin/cat /etc/hosts" "allowed"
run_test "Create file" "/usr/bin/touch /tmp/agentsh-test-file" "allowed"

# rm -rf is blocked by command rule (recursive delete protection)
run_test "rm -rf blocked" "rm -rf /tmp/test-dir" "denied"

# Cleanup
rm -f /tmp/agentsh-test-file 2>/dev/null || true

echo "TESTS_COMPLETE"
TESTSCRIPT

# Upload test script via base64
ENCODED_SCRIPT=$(base64 -w0 "$TEMP_SCRIPT")
run_on_sprite_raw "echo '$ENCODED_SCRIPT' | base64 -d > /tmp/run-tests.sh && chmod +x /tmp/run-tests.sh"
rm -f "$TEMP_SCRIPT"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                    Running Policy Tests                        ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"

# Run all tests
log_step "Running tests (this may take a moment)..."
TEST_OUTPUT=$(run_on_sprite_raw "/tmp/run-tests.sh" 2>&1)

# Check if tests completed
if ! echo "$TEST_OUTPUT" | grep -q "TESTS_COMPLETE"; then
    log_warn "Tests may not have completed. Raw output:"
    echo "$TEST_OUTPUT" | head -20
fi

# Parse and display results
PASSED=0
FAILED=0

# Current category tracking
CURRENT_CATEGORY=""

display_category() {
    local test_name="$1"
    local new_cat=""

    case "$test_name" in
        "List files"|"Echo command"|"Show current directory"|"Date command"|"Hostname command")
            new_cat="Safe Commands (should be ALLOWED)"
            ;;
        "sudo command"|"su command"|"chroot command")
            new_cat="Privilege Escalation (should be DENIED)"
            ;;
        "sprite list"|"sprite console")
            new_cat="Sprites CLI (should be DENIED)"
            ;;
        "netcat"|"ssh")
            new_cat="Network Tools (should be DENIED)"
            ;;
        "systemctl"|"kill")
            new_cat="System Commands (should be DENIED)"
            ;;
        "List directory"|"Read file"|"Create file")
            new_cat="File Operations via Commands (should be ALLOWED)"
            ;;
        "rm -rf blocked")
            new_cat="Dangerous File Operations (should be DENIED)"
            ;;
    esac

    if [[ "$new_cat" != "$CURRENT_CATEGORY" ]]; then
        echo ""
        echo -e "${BOLD}▸ $new_cat${NC}"
        CURRENT_CATEGORY="$new_cat"
    fi
}

while IFS= read -r line; do
    if [[ "$line" == TEST:* ]]; then
        # Parse: TEST:name:cmd:expected:result
        line="${line#TEST:}"
        name="${line%%:*}"
        line="${line#*:}"
        cmd="${line%%:*}"
        line="${line#*:}"
        expected="${line%%:*}"
        result="${line##*:}"

        display_category "$name"

        echo ""
        log_test "$name"
        echo -e "  Command: ${CYAN}$cmd${NC}"

        if [[ "$result" == "$expected" ]]; then
            echo -e "  Result: ${GREEN}✓ $result (expected)${NC}"
            PASSED=$((PASSED + 1))
        else
            echo -e "  Result: ${RED}✗ $result (expected: $expected)${NC}"
            FAILED=$((FAILED + 1))
        fi
    fi
done <<< "$TEST_OUTPUT"

# Summary
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}                         Test Summary                           ${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${GREEN}Passed:${NC} $PASSED"
echo -e "  ${RED}Failed:${NC} $FAILED"
echo -e "  ${BLUE}Total:${NC}  $((PASSED + FAILED))"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All tests passed!${NC}"
else
    echo -e "${YELLOW}${BOLD}Some tests failed. Check policy configuration.${NC}"
fi

echo ""

if $KEEP; then
    echo -e "${BOLD}Sprite kept for manual testing:${NC}"
    echo "  Connect: sprite $SPRITE_ARGS console -s $SPRITE_NAME"
    echo "  Destroy: sprite $SPRITE_ARGS destroy -s $SPRITE_NAME"
else
    echo -e "${BOLD}Sprite will be destroyed on exit.${NC}"
    echo "Use --keep to preserve the sprite for manual testing."
fi

echo ""
