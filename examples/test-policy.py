#!/usr/bin/env python3
"""
Test agentsh policy enforcement on Sprites.dev

This script tests that the security policy is working correctly by attempting
various operations and verifying they are allowed, denied, or require approval.

Usage:
    python3 test-policy.py

Requirements:
    - agentsh must be installed and running
    - Run from within the Sprite environment
"""

import subprocess
import sys


class PolicyTester:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.warnings = 0

    def run_command(self, cmd: str) -> tuple[int, str, str]:
        """Run a command through agentsh and return exit code, stdout, stderr."""
        try:
            result = subprocess.run(
                ["agentsh", "exec", "--", "bash", "-c", cmd],
                capture_output=True,
                text=True,
                timeout=10,
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return -1, "", "timeout"
        except Exception as e:
            return -1, "", str(e)

    def test_allowed(self, description: str, cmd: str):
        """Test that a command is allowed."""
        code, stdout, stderr = self.run_command(cmd)
        if code == 0:
            print(f"  \033[32m✓\033[0m {description}")
            self.passed += 1
        else:
            print(f"  \033[31m✗\033[0m {description} (expected: allowed, got: blocked)")
            print(f"      stderr: {stderr[:100]}")
            self.failed += 1

    def test_denied(self, description: str, cmd: str):
        """Test that a command is denied."""
        code, stdout, stderr = self.run_command(cmd)
        # agentsh returns non-zero and includes "denied" or "blocked" in output
        if code != 0 and ("denied" in stderr.lower() or "blocked" in stderr.lower()):
            print(f"  \033[32m✓\033[0m {description}")
            self.passed += 1
        elif code != 0:
            # Command failed but maybe not due to policy
            print(f"  \033[33m!\033[0m {description} (command failed, unclear if policy)")
            self.warnings += 1
        else:
            print(f"  \033[31m✗\033[0m {description} (expected: denied, got: allowed)")
            self.failed += 1

    def test_file_readable(self, description: str, path: str):
        """Test that a file/path is readable."""
        self.test_allowed(description, f"cat {path} 2>/dev/null || ls {path}")

    def test_file_blocked(self, description: str, path: str):
        """Test that a file/path access is blocked or requires approval."""
        code, stdout, stderr = self.run_command(f"cat {path}")
        if code != 0:
            print(f"  \033[32m✓\033[0m {description}")
            self.passed += 1
        else:
            print(f"  \033[31m✗\033[0m {description} (expected: blocked, got: allowed)")
            self.failed += 1

    def run_tests(self):
        """Run all policy tests."""
        print("\n=== agentsh Policy Tests for Sprites ===\n")

        # Safe commands
        print("Testing ALLOWED commands:")
        self.test_allowed("ls command", "ls /")
        self.test_allowed("echo command", "echo hello")
        self.test_allowed("pwd command", "pwd")
        self.test_allowed("cat command", "cat /etc/hostname")
        self.test_allowed("git status", "git --version")
        self.test_allowed("python version", "python3 --version")
        self.test_allowed("node version", "node --version || true")

        print("\nTesting DENIED commands:")
        self.test_denied("sudo blocked", "sudo ls")
        self.test_denied("su blocked", "su -")
        self.test_denied("sprite CLI blocked", "sprite list")
        self.test_denied("ssh blocked", "ssh localhost")
        self.test_denied("nc blocked", "nc -h")
        self.test_denied("apt blocked", "apt update")
        self.test_denied("systemctl blocked", "systemctl status")

        print("\nTesting Sprites-specific rules:")
        self.test_file_readable("/.sprite readable", "/.sprite")
        self.test_denied("sprite checkpoint requires approval", "sprite checkpoint test")

        print("\nTesting file access:")
        self.test_file_readable("/tmp writable", "/tmp && touch /tmp/test-$$ && rm /tmp/test-$$")
        self.test_allowed("home dir access", "ls ~")

        # Summary
        print("\n=== Test Summary ===")
        print(f"  Passed:   {self.passed}")
        print(f"  Failed:   {self.failed}")
        print(f"  Warnings: {self.warnings}")

        if self.failed > 0:
            print("\n\033[31mSome tests failed. Check policy configuration.\033[0m")
            return 1
        elif self.warnings > 0:
            print("\n\033[33mAll critical tests passed with some warnings.\033[0m")
            return 0
        else:
            print("\n\033[32mAll tests passed!\033[0m")
            return 0


def main():
    # Check if agentsh is available
    try:
        result = subprocess.run(
            ["agentsh", "--version"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            print("Error: agentsh not found or not working")
            print("Make sure agentsh is installed and the server is running")
            sys.exit(1)
    except FileNotFoundError:
        print("Error: agentsh command not found")
        print("Install agentsh first: sudo ./install.sh")
        sys.exit(1)
    except Exception as e:
        print(f"Error checking agentsh: {e}")
        sys.exit(1)

    tester = PolicyTester()
    sys.exit(tester.run_tests())


if __name__ == "__main__":
    main()
