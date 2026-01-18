#!/bin/bash
# Verify agentsh installation on Sprites.dev
# https://github.com/canyonroad/agentsh-sprites
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}!${NC} $1"; }

echo "=== agentsh Sprites Installation Verification ==="
echo ""

# 1. Check agentsh binary
echo -n "Checking agentsh binary... "
if command -v agentsh &> /dev/null; then
    VERSION=$(agentsh --version 2>/dev/null || echo "unknown")
    pass "installed (${VERSION})"
else
    fail "agentsh binary not found"
fi

# 2. Check shell shim
echo -n "Checking shell shim... "
if [[ -L /bin/bash ]] || file /bin/bash 2>/dev/null | grep -q "agentsh"; then
    pass "installed"
elif agentsh shim status &>/dev/null; then
    pass "installed (via status check)"
else
    warn "shim status unclear - may still work"
fi

# 3. Check config file
echo -n "Checking config file... "
if [[ -f /etc/agentsh/config.yaml ]]; then
    pass "/etc/agentsh/config.yaml"
else
    fail "config file not found"
fi

# 4. Check policy file
echo -n "Checking policy file... "
if [[ -f /etc/agentsh/policies/default.yaml ]]; then
    pass "/etc/agentsh/policies/default.yaml"
else
    fail "policy file not found"
fi

# 5. Check directories
echo -n "Checking directories... "
DIRS_OK=true
for dir in /var/lib/agentsh/sessions /var/lib/agentsh/quarantine /var/log/agentsh; do
    if [[ ! -d "$dir" ]]; then
        DIRS_OK=false
        break
    fi
done
if $DIRS_OK; then
    pass "all directories exist"
else
    fail "missing directories"
fi

# 6. Check environment
echo -n "Checking environment... "
if [[ -f /etc/profile.d/agentsh.sh ]]; then
    pass "environment configured"
else
    warn "environment file missing (optional)"
fi

# 7. Check server status
echo -n "Checking agentsh server... "
if curl -s http://127.0.0.1:18080/health 2>/dev/null | grep -q "ok"; then
    pass "running"
else
    warn "server may not be running - start with: cd /etc/agentsh && nohup agentsh server &"
fi

# 8. Test basic execution
echo -n "Testing policy enforcement... "
# Create a session and test
SESSION=$(agentsh session create --workspace /home/sprite --json 2>/dev/null | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
if [[ -n "$SESSION" ]]; then
    if AGENTSH_SESSION_ID="$SESSION" agentsh exec -- /bin/echo "test" &>/dev/null; then
        pass "working"
    else
        warn "exec test failed"
    fi
else
    warn "could not create session - server may need to be started"
fi

echo ""
echo "=== Verification Complete ==="
echo ""
echo "If all checks passed, checkpoint your Sprite to persist this setup:"
echo ""
echo "  sprite checkpoint <your-sprite-name>"
echo ""
echo "To test policy enforcement:"
echo ""
echo "  agentsh exec -- ls /            # Should work"
echo "  agentsh exec -- sudo su         # Should be blocked"
echo "  agentsh exec -- sprite login    # Should be blocked"
echo ""
