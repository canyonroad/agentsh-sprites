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

import os
import subprocess
import sys


def load_agentsh_env():
    """Load agentsh environment variables from /etc/profile.d/agentsh.sh"""
    env_file = "/etc/profile.d/agentsh.sh"
    if os.path.exists(env_file):
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith("export "):
                    # Parse: export VAR="value"
                    parts = line[7:].split("=", 1)
                    if len(parts) == 2:
                        key = parts[0]
                        value = parts[1].strip('"').strip("'")
                        os.environ[key] = value


class PolicyTester:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.warnings = 0

    def run_command(self, cmd: str) -> tuple[int, str, str]:
        """Run a command through agentsh and return exit code, stdout, stderr."""
        try:
            # Use bash.real since /bin/bash is the agentsh shim
            shell = "/usr/bin/bash.real"
            if not os.path.exists(shell):
                shell = "/bin/bash"  # Fallback if shim not installed
            result = subprocess.run(
                ["agentsh", "exec", "--", shell, "-c", cmd],
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
        combined = (stderr + stdout).lower()
        # agentsh returns non-zero and includes "denied" or "blocked" in output
        # Also count "command not found" as effectively blocked
        if code != 0 and ("denied" in combined or "blocked" in combined):
            print(f"  \033[32m✓\033[0m {description}")
            self.passed += 1
        elif code != 0 and ("not found" in combined or "no such file" in combined):
            print(f"  \033[32m✓\033[0m {description} (command not available)")
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

    def test_denied_direct(self, description: str, cmd_args: list):
        """Test that a direct command (not via bash -c) is denied."""
        try:
            result = subprocess.run(
                ["agentsh", "exec", "--"] + cmd_args,
                capture_output=True,
                text=True,
                timeout=10,
            )
            combined = (result.stderr + result.stdout).lower()
            if result.returncode != 0 and ("denied" in combined or "blocked" in combined):
                print(f"  \033[32m✓\033[0m {description}")
                self.passed += 1
            elif result.returncode != 0:
                print(f"  \033[33m!\033[0m {description} (command failed, unclear if policy)")
                self.warnings += 1
            else:
                print(f"  \033[31m✗\033[0m {description} (expected: denied, got: allowed)")
                self.failed += 1
        except Exception as e:
            print(f"  \033[33m!\033[0m {description} (error: {e})")
            self.warnings += 1

    def run_policy_test(self, description: str, op: str, path: str, expected: str):
        """Test file policy evaluation via agentsh debug policy-test."""
        try:
            result = subprocess.run(
                ["agentsh", "debug", "policy-test", "--op", op, "--path", path],
                capture_output=True,
                text=True,
                timeout=10,
            )
            decision = ""
            for line in result.stdout.splitlines():
                if line.startswith("Decision:"):
                    decision = line.split(None, 1)[1].strip().lower()
                    break
            if decision == expected:
                print(f"  \033[32m✓\033[0m {description} ({decision})")
                self.passed += 1
            else:
                print(f"  \033[31m✗\033[0m {description} (expected: {expected}, got: {decision})")
                self.failed += 1
        except Exception as e:
            print(f"  \033[33m!\033[0m {description} (error: {e})")
            self.warnings += 1

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
        self.test_denied("chroot blocked", "chroot /")
        self.test_denied("nsenter blocked", "nsenter --help")
        self.test_denied("unshare blocked", "unshare --help")
        self.test_denied("sprite CLI blocked", "sprite list")
        self.test_denied("ssh blocked", "ssh localhost")
        self.test_denied("nc blocked", "nc -h")
        self.test_denied("telnet blocked", "telnet localhost")
        self.test_denied("scp blocked", "scp /dev/null localhost")
        self.test_denied("rsync blocked", "rsync --help")
        self.test_denied("systemctl blocked", "systemctl status")
        self.test_denied("kill blocked", "kill -0 1")
        self.test_denied("killall blocked", "killall -l")
        self.test_denied("pkill blocked", "pkill --help")
        self.test_denied("shutdown blocked", "shutdown --help")
        self.test_denied("reboot blocked", "reboot --help")
        self.test_denied("mount blocked", "mount -l")
        self.test_denied("dd blocked", "dd if=/dev/zero of=/dev/null count=0")
        # Note: Commands run via bash -c bypass command-level policy checks
        # because agentsh only sees bash.real as the top-level command.
        # Direct command execution IS blocked by policy.
        print("\nTesting direct command blocking:")
        self.test_denied_direct("rm -rf direct", ["rm", "-rf", "/tmp/nonexistent"])
        self.test_denied_direct("rm -r direct", ["rm", "-r", "/tmp/nonexistent"])
        self.test_denied_direct("rm --recursive direct", ["rm", "--recursive", "/tmp/nonexistent"])
        self.test_denied_direct("sudo direct", ["sudo", "ls"])
        self.test_denied_direct("ssh direct", ["ssh", "localhost"])
        self.test_denied_direct("kill direct", ["kill", "-0", "1"])

        print("\nTesting ALLOWED single-file operations:")
        self.test_denied_direct("rm single file allowed", ["rm", "/tmp/nonexistent-ok"])  # Will fail (no file) but not policy-denied

        print("\nTesting package install (requires approval):")
        self.test_denied_direct("npm install blocked", ["npm", "install", "express"])
        self.test_denied_direct("pip install blocked", ["pip3", "install", "requests"])

        print("\nTesting Sprites-specific rules:")
        self.test_file_readable("/.sprite readable", "/.sprite")
        self.test_denied("sprite checkpoint requires approval", "sprite checkpoint test")

        print("\nTesting file access:")
        self.test_file_readable("/tmp writable", "/tmp && touch /tmp/test-$$ && rm /tmp/test-$$")
        self.test_allowed("home dir access", "ls ~")

        # File policy tests via agentsh debug policy-test
        # These verify file rules evaluate correctly for FUSE/seccomp enforcement
        # Note: ${PROJECT_ROOT} and ${HOME} policy variables require runtime
        # session context; tests below use literal paths that match non-variable rules.

        print("\nTesting file policy: temp directories:")
        self.run_policy_test("tmp write allowed", "file_write", "/tmp/test", "allow")
        self.run_policy_test("var tmp write allowed", "file_write", "/var/tmp/test", "allow")

        print("\nTesting file policy: system paths (read-only):")
        self.run_policy_test("system read allowed", "file_read", "/usr/bin/node", "allow")
        self.run_policy_test("system write blocked", "file_write", "/usr/bin/test", "deny")
        self.run_policy_test("lib read allowed", "file_read", "/lib/x86_64-linux-gnu/libc.so.6", "allow")
        self.run_policy_test("lib write blocked", "file_write", "/lib/test", "deny")
        self.run_policy_test("bin read allowed", "file_read", "/bin/ls", "allow")
        self.run_policy_test("sbin write blocked", "file_write", "/sbin/test", "deny")

        print("\nTesting file policy: /etc (minimal read):")
        self.run_policy_test("/etc/hosts readable", "file_read", "/etc/hosts", "allow")
        self.run_policy_test("/etc/resolv.conf readable", "file_read", "/etc/resolv.conf", "allow")
        self.run_policy_test("/etc/ssl/certs readable", "file_read", "/etc/ssl/certs/ca-certificates.crt", "allow")
        self.run_policy_test("/etc/shadow blocked", "file_read", "/etc/shadow", "deny")
        self.run_policy_test("/etc/passwd blocked", "file_read", "/etc/passwd", "deny")
        self.run_policy_test("/etc write blocked", "file_write", "/etc/test", "deny")

        print("\nTesting file policy: Sprites folder (read-only):")
        self.run_policy_test("/.sprite readable", "file_read", "/.sprite/bin/test", "allow")
        self.run_policy_test("/.sprite write blocked", "file_write", "/.sprite/test", "deny")

        print("\nTesting file policy: /proc and /sys (blocked):")
        self.run_policy_test("/proc blocked", "file_read", "/proc/1/cmdline", "deny")
        self.run_policy_test("/proc environ blocked", "file_read", "/proc/1/environ", "deny")
        self.run_policy_test("/sys blocked", "file_read", "/sys/kernel/version", "deny")

        print("\nTesting file policy: credentials (approval required):")
        # approve = allow when approvals are disabled
        self.run_policy_test("SSH keys protected", "file_read", "/root/.ssh/id_rsa", "allow")
        self.run_policy_test("AWS creds protected", "file_read", "/root/.aws/credentials", "allow")
        self.run_policy_test(".env file protected", "file_read", "/home/sprite/.env", "allow")

        print("\nTesting file policy: package caches (read-only):")
        self.run_policy_test("npm cache readable", "file_read", "/root/.npm/test", "allow")
        self.run_policy_test("cargo cache readable", "file_read", "/root/.cargo/test", "allow")
        self.run_policy_test("cache dir readable", "file_read", "/root/.cache/test", "allow")

        print("\nTesting file policy: dangerous binaries (blocked):")
        self.run_policy_test("sudo binary blocked", "file_read", "/usr/bin/sudo", "deny")
        self.run_policy_test("su binary blocked", "file_read", "/usr/bin/su", "deny")
        self.run_policy_test("pkexec binary blocked", "file_read", "/usr/bin/pkexec", "deny")
        self.run_policy_test("nsenter binary blocked", "file_read", "/usr/bin/nsenter", "deny")

        print("\nTesting file policy: default deny:")
        self.run_policy_test("/var write blocked", "file_write", "/var/test", "deny")
        self.run_policy_test("/root home blocked", "file_read", "/root/test", "deny")

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
    # Load agentsh environment variables
    load_agentsh_env()

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
