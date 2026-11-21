#!/usr/bin/env python3
"""Isolated local tests: no SSH server, network, real keys, or user rc writes.

Optionally pass --ghostty /path/to/ghostty to also exercise the built +ssh CLI
with a fake SSH executable and a local pseudo-terminal.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import signal
import stat
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "src/cli/ssh_directory.sh"
REPORT = (SCRIPT.parent / "ssh_directory_report.sh").read_bytes()
PAYLOAD = SCRIPT.read_bytes().replace(b"# GHOSTTYCN_DIRECTORY_REPORT", REPORT)
ENTRY = ('if command -v base64 >/dev/null 2>&1; then '
         'script=$(printf %s "$1" | base64 -d 2>/dev/null) && '
         'case "$script" in "# GhosttyCN remote directory integration v1."*) exec sh -c "$script";; esac; fi; '
         'exec "${SHELL:-/bin/sh}" -l')
COMMAND = "sh -c '" + ENTRY + "' ghosttycn-cwd-v1 " + base64.b64encode(PAYLOAD).decode()
PARSER = argparse.ArgumentParser()
PARSER.add_argument("--ghostty", type=Path)
PARSER.add_argument("--bash", type=Path, default=Path("/bin/bash"))
OPTIONS, UNITTEST_ARGS = PARSER.parse_known_args()
if OPTIONS.ghostty and not OPTIONS.ghostty.is_file():
    PARSER.error("--ghostty must name an existing application executable")
BASH_MAJOR = int(subprocess.check_output([str(OPTIONS.bash), "--noprofile", "--norc", "-c", "printf %s \"${BASH_VERSINFO[0]}\""]))


def run_process(argv, *, env, cwd, commands=None, tty=False):
    master = slave = None
    if tty:
        master, slave = pty.openpty()
    process = subprocess.Popen(
        argv, env=env, cwd=cwd, start_new_session=True,
        stdin=slave if tty else subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if slave is not None:
        os.close(slave)
    try:
        stdout, stderr = process.communicate(commands, timeout=15)
        return process.returncode, stdout, stderr
    except subprocess.TimeoutExpired:
        # This test owns the newly created session/process group.
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate(timeout=5)
        raise
    finally:
        if master is not None:
            os.close(master)


class BootstrapTests(unittest.TestCase):
    def supported_shells(self):
        shells = []
        if BASH_MAJOR >= 4:
            shells.append(("bash", str(OPTIONS.bash)))
        if Path("/bin/zsh").exists():
            shells.append(("zsh", "/bin/zsh"))
        return shells

    def test_creation_mask_matches_native_login_and_profile_overrides(self):
        for shell, executable in self.supported_shells():
            for initial, override in [(0o002, None), (0o022, None), (0o027, None), (0o077, None),
                                      (0o022, 0o027), (0o077, 0o002)]:
                with self.subTest(shell=shell, initial=oct(initial), override=override), \
                        tempfile.TemporaryDirectory(prefix="ghosttycn-mask-parity-") as directory:
                    root = Path(directory)
                    home = root / "home"
                    home.mkdir()
                    scratch = root / "scratch"
                    scratch.mkdir()
                    profile = home / (".bash_profile" if shell == "bash" else ".zprofile")
                    profile.write_text(
                        "printf 'PROFILE_MASK:%s\\n' \"$(umask)\"\n"
                        + (f"umask {override:03o}\n" if override is not None else "")
                    )
                    env = {"HOME": str(home), "SHELL": executable, "TMPDIR": str(scratch),
                           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"}
                    observations = []
                    for command in ['exec "$SHELL" -il', COMMAND]:
                        status, output, errors = run_process(
                            ["/bin/sh", "-c", f"umask {initial:03o}; " + command], env=env, cwd=home,
                            commands=b'printf "FINAL_MASK:%s\\n" "$(umask)"\n: > "$HOME/probe-file"\n'
                                     b'ls -ld "$TMPDIR"/ghosttycn-ssh-* 2>/dev/null\n'
                                     b'ls -lA "$TMPDIR"/ghosttycn-ssh-* 2>/dev/null\nexit 0\n')
                        self.assertEqual(status, 0, errors.decode(errors="replace"))
                        masks = re.findall(rb"(?:PROFILE|FINAL)_MASK:([0-7]+)", output)
                        self.assertEqual(len(masks), 2, output)
                        observations.append((masks, stat.S_IMODE((home / "probe-file").stat().st_mode)))
                        # Each run must create its own file, not reuse the native probe.
                        (home / "probe-file").unlink()
                        if command == COMMAND:
                            self.assertRegex(output, rb"drwx------[^\n]*ghosttycn-ssh-")
                            private_files = set()
                            for line in output.splitlines():
                                if line.endswith((b" report", b" bash-env", b" .zshenv")):
                                    self.assertTrue(line.startswith(b"-rw-------"), line)
                                    private_files.add(line.rsplit(maxsplit=1)[-1])
                            self.assertEqual(private_files, {b"report", b"bash-env", b".zshenv"})
                            self.assertEqual(list(scratch.iterdir()), [])
                    self.assertEqual(observations[0], observations[1])

    def test_setup_failure_keeps_native_creation_mask(self):
        for shell, executable in self.supported_shells():
            for failure in ["mktemp", "cat"]:
                with self.subTest(shell=shell, failure=failure), \
                        tempfile.TemporaryDirectory(prefix="ghosttycn-setup-fallback-") as directory:
                    root = Path(directory)
                    bindir = root / "bin"
                    bindir.mkdir()
                    scratch = root / "scratch"
                    scratch.mkdir()
                    tool = bindir / failure
                    tool.write_text("#!/bin/sh\nexit 1\n")
                    tool.chmod(0o700)
                    env = {"HOME": directory, "SHELL": executable, "TMPDIR": str(scratch),
                           "PATH": str(bindir) + ":/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"}
                    masks = []
                    for command in ['exec "$SHELL" -il', COMMAND]:
                        status, output, _ = run_process(
                            ["/bin/sh", "-c", "umask 027; " + command], env=env, cwd=root,
                            commands=b'printf "FINAL_MASK:%s\\n" "$(umask)"\nexit 6\n')
                        self.assertEqual(status, 6)
                        masks.append(re.findall(rb"FINAL_MASK:([0-7]+)", output))
                        self.assertNotIn(b"\x1b]7;", output)
                        self.assertEqual(list(scratch.iterdir()), [])
                    self.assertTrue(masks[0])
                    self.assertEqual(masks[0], masks[1])

    @unittest.skipUnless(Path("/bin/zsh").exists(), "zsh is not installed")
    def test_system_compinit_uses_real_zdotdir_and_leaves_no_temporary_cache(self):
        if not any(Path(path).is_file() for path in ["/etc/zshrc", "/etc/zsh/zshrc"]):
            self.skipTest("A system zshrc is needed to exercise the real startup boundary")
        for mode in ["home", "from-zshenv", "inherited"]:
            with self.subTest(zdotdir=mode), \
                    tempfile.TemporaryDirectory(prefix="ghosttycn-system-compinit-") as directory:
                root = Path(directory).resolve()
                home = root / "home"
                config = home if mode == "home" else home / "custom-rc"
                config.mkdir(parents=True)
                scratch = root / "scratch"
                scratch.mkdir()
                # Instrument the actual system-startup boundary rather than
                # editing /etc/zshrc. This reproduces Ubuntu's global compinit
                # even on macOS, before the user's .zshrc is loaded.
                (config / ".zshenv").write_text('''TRAPDEBUG() {
  if [[ ${funcfiletrace[1]-} == /etc/zshrc:* || ${funcfiletrace[1]-} == /etc/zsh/zshrc:* ]] &&
     [[ -z ${GCN_SYSTEM_CHECK-} ]]; then
    GCN_SYSTEM_CHECK=1
    printf 'SYSTEM_ZDOTDIR:%s\\n' "${ZDOTDIR-$HOME}"
    autoload -Uz compinit
    compinit -i
    printf 'SYSTEM_COMPDUMP:%s\\n' "$_comp_dumpfile"
  fi
}
''')
                # For a custom directory the home .zshenv must load the probe
                # itself, just like an actual user configuration would.
                if mode == "from-zshenv":
                    (home / ".zshenv").write_text(
                        'export ZDOTDIR="$HOME/custom-rc"\nsource "$ZDOTDIR/.zshenv"\n')
                (config / ".zprofile").write_text('printf "profile\\n" >> "$HOME/startup-order"\n')
                (config / ".zshrc").write_text('printf "rc\\n" >> "$HOME/startup-order"\nprecmd_functions=(\':\')\n')
                (config / ".zlogin").write_text('printf "login\\n" >> "$HOME/startup-order"\n')
                (config / ".zlogout").write_text('printf logout > "$HOME/logout-marker"\n')
                files = [path for path in home.rglob(".z*") if path.is_file()]
                before = {path: path.read_bytes() for path in files}
                env = {"HOME": str(home), "SHELL": "/bin/zsh", "TMPDIR": str(scratch),
                       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color"}
                if mode == "inherited":
                    env["ZDOTDIR"] = str(config)
                output_by_mode = []
                for command in ['exec "$SHELL" -il', COMMAND]:
                    status, output, errors = run_process(["/bin/sh", "-c", command], env=env, cwd=home,
                        commands=b'printf "FINAL_ZDOTDIR:%s\\n" "${ZDOTDIR-$HOME}"\n'
                                 b'printf "FINAL_HISTORY:%s\\n" "${HISTFILE-}"\n'
                                 b'printf "PROMPT_HOOKS:%s\\n" "${precmd_functions[*]}"\nexit 0\n')
                    self.assertEqual(status, 0, errors.decode(errors="replace"))
                    self.assertIn(f"SYSTEM_ZDOTDIR:{config}".encode(), output)
                    self.assertIn(f"SYSTEM_COMPDUMP:{config}/.zcompdump".encode(), output)
                    self.assertIn(f"FINAL_ZDOTDIR:{config}".encode(), output)
                    self.assertTrue((config / ".zcompdump").is_file())
                    self.assertEqual((home / "logout-marker").read_text(), "logout")
                    self.assertEqual(list(scratch.iterdir()), [])
                    self.assertEqual((home / "startup-order").read_text(), "profile\nrc\nlogin\n")
                    (home / "startup-order").unlink()
                    output_by_mode.append(output)
                self.assertIn(b"_ghosttycn_report_pwd", output_by_mode[1])
                self.assertNotIn(b"_ghosttycn_directory_init", output_by_mode[1])
                histories = [re.search(rb"FINAL_HISTORY:([^\n]*)", output).group(1) for output in output_by_mode]
                self.assertEqual(histories[0], histories[1])
                self.assertNotIn(str(scratch).encode(), histories[1])
                for path, content in before.items():
                    self.assertEqual(path.read_bytes(), content)

    def test_payload_transport_is_fixed_readable_and_compact(self):
        self.assertNotIn("eval", COMMAND)
        self.assertLess(len(COMMAND), len(PAYLOAD) * 2)
        self.assertEqual(PAYLOAD.count(b"_ghosttycn_report_pwd()"), 1)
        self.assertNotIn(b"# GHOSTTYCN_DIRECTORY_REPORT", PAYLOAD)

    def test_decoder_failure_preserves_login_and_stdin(self):
        with tempfile.TemporaryDirectory(prefix="ghosttycn-decoder-fallback-") as directory:
            root = Path(directory)
            decoder = root / "base64"
            decoder.write_text("#!/bin/sh\nexit 1\n")
            decoder.chmod(0o700)
            env = {"HOME": directory, "TMPDIR": directory, "SHELL": "/bin/sh",
                   "PATH": str(root) + ":/usr/bin:/bin"}
            status, output, _ = run_process(["/bin/sh", "-c", COMMAND], env=env, cwd=root,
                                             commands=b"printf FALLBACK_STDIN_OK; exit 9\n")
            self.assertEqual(status, 9)
            self.assertIn(b"FALLBACK_STDIN_OK", output)
            self.assertNotIn(b"\x1b]7;", output)
            self.assertEqual(list(root.glob("ghosttycn-ssh-*")), [])

    def test_missing_decoder_preserves_login(self):
        with tempfile.TemporaryDirectory(prefix="ghosttycn-no-decoder-") as directory:
            root = Path(directory)
            (root / "sh").symlink_to("/bin/sh")
            env = {"HOME": directory, "SHELL": "/bin/sh", "PATH": directory}
            status, output, _ = run_process(["/bin/sh", "-c", COMMAND], env=env, cwd=root,
                                             commands=b"printf NO_DECODER_LOGIN_OK; exit 5\n")
            self.assertEqual(status, 5)
            self.assertIn(b"NO_DECODER_LOGIN_OK", output)
            self.assertNotIn(b"\x1b]7;", output)

    def test_invalid_payload_preserves_login(self):
        with tempfile.TemporaryDirectory(prefix="ghosttycn-invalid-payload-") as directory:
            env = {"HOME": directory, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"}
            command = "sh -c '" + ENTRY + "' ghosttycn-cwd-v1 invalid!"
            status, output, _ = run_process(["/bin/sh", "-c", command], env=env, cwd=directory,
                                             commands=b"printf FALLBACK_OK; exit 8\n")
            self.assertEqual(status, 8)
            self.assertIn(b"FALLBACK_OK", output)

    def test_outer_login_shell_preserves_payload_quoting(self):
        for outer in ["/bin/bash", "/bin/zsh"]:
            if not Path(outer).exists():
                continue
            with self.subTest(outer=outer), tempfile.TemporaryDirectory(prefix="ghosttycn-outer-shell-") as directory:
                env = {"HOME": directory, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"}
                status, output, _ = run_process([outer, "-c", COMMAND], env=env, cwd=directory,
                                                 commands=b"printf OUTER_QUOTING_OK; exit 4\n")
                self.assertEqual(status, 4)
                self.assertIn(b"OUTER_QUOTING_OK", output)

    def exercise_shell(self, shell, array=False):
        with tempfile.TemporaryDirectory(prefix="ghosttycn-auto-cwd-") as directory:
            root = Path(directory).resolve()
            home = root / "home"
            scratch = root / "scratch"
            child = home / "中文 spaces ' % #"
            child.mkdir(parents=True)
            scratch.mkdir()
            env = {
                "HOME": str(home), "SHELL": str(OPTIONS.bash) if shell == "bash" else "/bin/zsh",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
                "TMPDIR": str(scratch), "GHOSTTYCN_TEST_CWD": str(child),
                "ENV": "original-env-value",
            }
            if shell == "bash":
                profile = home / ".bash_profile"
                profile.write_text('export GCN_PROFILE=loaded\n. "$HOME/.bashrc"\n')
                rc = home / ".bashrc"
                rc.write_text(
                    "PS1='gcn-test> '\n"
                    + ("declare -ax PROMPT_COMMAND=(':')\n" if array else "PROMPT_COMMAND=':;'\n")
                    + "gcn_user_function() { printf USER_FUNCTION_OK; }\n"
                )
                checks = (
                    "shopt -q login_shell && printf 'LOGIN_OK\\n'\n"
                    "printf 'PROFILE:%s\\nENV:%s\\n' \"$GCN_PROFILE\" \"$ENV\"\n"
                    "gcn_user_function\n"
                )
                files = [profile, rc]
            else:
                config = home / "custom-rc"
                config.mkdir()
                zenv = home / ".zshenv"
                zenv.write_text('export ZDOTDIR="$HOME/custom-rc"\n')
                profile = config / ".zprofile"
                profile.write_text("export GCN_PROFILE=loaded\n")
                rc = config / ".zshrc"
                rc.write_text("PS1='gcn-test> '\ngcn_user_function() { printf USER_FUNCTION_OK; }\nprecmd_functions=(gcn_user_function)\n")
                login = config / ".zlogin"
                login.write_text("export GCN_LOGIN=loaded\n")
                logout = config / ".zlogout"
                logout.write_text('printf logout > "$HOME/logout-marker"\n')
                checks = (
                    "[[ -o login ]] && printf 'LOGIN_OK\\n'\n"
                    "printf 'PROFILE:%s\\nZLOGIN:%s\\nZDOTDIR:%s\\n' \"$GCN_PROFILE\" \"$GCN_LOGIN\" \"$ZDOTDIR\"\n"
                    "gcn_user_function\n"
                )
                files = [zenv, profile, rc, login, logout]
            before = {path: path.read_bytes() for path in files}
            commands = (checks + 'cd -- "$GHOSTTYCN_TEST_CWD"\nprintf "AFTER_CD\\n"\nexit 7\n').encode()
            status, output, errors = run_process(["/bin/sh", "-c", COMMAND], env=env, cwd=home, commands=commands)
            self.assertEqual(status, 7, errors.decode(errors="replace"))
            self.assertIn(b"LOGIN_OK", output)
            self.assertIn(b"PROFILE:loaded", output)
            self.assertIn(b"USER_FUNCTION_OK", output)
            reports = re.findall(rb"\x1b]7;([^\x07]*)\x07", output)
            paths = [unquote(urlsplit(report.decode()).path) for report in reports]
            self.assertIn(str(child), paths, (paths, output.decode(errors="replace"), errors.decode(errors="replace")))
            if shell == "bash":
                self.assertIn(b"ENV:original-env-value", output)
            else:
                self.assertIn(b"ZLOGIN:loaded", output)
                self.assertIn(f"ZDOTDIR:{home / 'custom-rc'}".encode(), output)
                self.assertEqual((home / "logout-marker").read_text(), "logout")
            self.assertEqual(list(scratch.iterdir()), [],
                             str([str(item.relative_to(scratch)) for item in scratch.rglob("*")]))
            for path, content in before.items():
                self.assertEqual(path.read_bytes(), content, f"Changed user's startup file: {path.name}")

    @unittest.skipUnless(BASH_MAJOR >= 4, "Pass --bash with Bash 4+ to exercise automatic Bash injection")
    def test_bash_scalar_prompt(self):
        self.exercise_shell("bash")

    @unittest.skipUnless(BASH_MAJOR >= 4, "Pass --bash with Bash 4+ to exercise automatic Bash injection")
    def test_bash_array_prompt(self):
        self.exercise_shell("bash", array=True)

    @unittest.skipUnless(Path("/bin/zsh").exists(), "zsh is not installed")
    def test_zsh_custom_zdotdir_and_logout(self):
        self.exercise_shell("zsh")

    def test_unsupported_shell_is_passed_through(self):
        with tempfile.TemporaryDirectory(prefix="ghosttycn-shell-fallback-") as directory:
            env = {"HOME": directory, "TMPDIR": directory, "SHELL": "/bin/sh", "PATH": "/usr/bin:/bin"}
            status, output, _ = run_process(["/bin/sh", "-c", COMMAND], env=env, cwd=directory,
                                             commands=b"printf FALLBACK_OK; exit 6\n")
            self.assertEqual(status, 6)
            self.assertIn(b"FALLBACK_OK", output)
            self.assertNotIn(b"\x1b]7;", output)
            self.assertEqual(list(Path(directory).glob("ghosttycn-ssh-*")), [])

    @unittest.skipUnless(subprocess.check_output(["/bin/bash", "--version"]).startswith(b"GNU bash, version 3."), "macOS Bash 3 fallback")
    def test_old_bash_keeps_normal_login(self):
        with tempfile.TemporaryDirectory(prefix="ghosttycn-bash3-fallback-") as directory:
            profile = Path(directory) / ".bash_profile"
            profile.write_text("export GCN_PROFILE=old-bash-login\n")
            env = {"HOME": directory, "TMPDIR": directory, "SHELL": "/bin/bash", "PATH": "/usr/bin:/bin"}
            status, output, _ = run_process(["/bin/sh", "-c", COMMAND], env=env, cwd=directory,
                                             commands=b'printf "%s" "$GCN_PROFILE"; exit 6\n')
            self.assertEqual(status, 6)
            self.assertIn(b"old-bash-login", output)
            self.assertNotIn(b"\x1b]7;", output)
            self.assertEqual(list(Path(directory).glob("ghosttycn-ssh-*")), [])


class LocalShellIntegrationTests(unittest.TestCase):
    def exercise(self, shell, custom=False):
        with tempfile.TemporaryDirectory(prefix="ghosttycn-local-ssh-") as directory:
            root = Path(directory)
            capture = root / "capture.json"
            fake = root / "ghostty"
            fake.write_text(
                "#!/usr/bin/python3\nimport json, os, sys\n"
                "with open(os.environ['GCN_CAPTURE'], 'w') as f: json.dump(sys.argv[1:], f)\n"
            )
            fake.chmod(0o700)
            integration = ROOT / ("src/shell-integration/bash/ghostty.bash" if shell == "bash" else
                                  "src/shell-integration/zsh/ghostty-integration")
            env = {"HOME": directory, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color",
                   "GHOSTTYCN_REMOTE_CWD": "1", "GHOSTTY_SHELL_FEATURES": "",
                   "GHOSTTY_BIN_DIR": directory, "GCN_CAPTURE": str(capture), "GCN_INTEGRATION": str(integration)}
            prefix = "ssh() { printf CUSTOM_SSH; }\n" if custom else ""
            commands = prefix + '. "$GCN_INTEGRATION"\nssh fixture\nexit\n'
            argv = [str(OPTIONS.bash), "--noprofile", "--norc", "-i"] if shell == "bash" else ["/bin/zsh", "-f", "-i"]
            status, output, errors = run_process(argv, env=env, cwd=root, commands=commands.encode())
            self.assertEqual(status, 0, errors.decode(errors="replace"))
            if custom:
                self.assertIn(b"CUSTOM_SSH", output)
                self.assertFalse(capture.exists())
            else:
                self.assertTrue(capture.exists(), errors.decode(errors="replace"))
                self.assertEqual(json.loads(capture.read_text()),
                                 ["+ssh", "--forward-env=false", "--terminfo=false", "--", "fixture"])

    def test_regular_ssh_uses_the_wrapper(self):
        for shell in ["bash", "zsh"]:
            with self.subTest(shell=shell):
                self.exercise(shell)

    def test_custom_ssh_function_is_not_replaced(self):
        for shell in ["bash", "zsh"]:
            with self.subTest(shell=shell):
                self.exercise(shell, custom=True)


@unittest.skipUnless(OPTIONS.ghostty, "Pass --ghostty to exercise +ssh")
class WrapperTests(unittest.TestCase):
    def invoke(self, args, *, tty=True, enabled="1", config=None):
        with tempfile.TemporaryDirectory(prefix="ghosttycn-ssh-wrapper-") as directory:
            root = Path(directory)
            capture = root / "capture.jsonl"
            fake = root / "fake-ssh"
            fake.write_text(
                "#!/usr/bin/python3\nimport json, os, sys\n"
                "with open(os.environ['GCN_CAPTURE'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "if '-G' in sys.argv[1:]: print(os.environ['GCN_CONFIG'])\n"
            )
            fake.chmod(0o700)
            env = {
                "PATH": "/usr/bin:/bin", "HOME": directory, "TERM": "xterm-256color",
                "GCN_CAPTURE": str(capture), "GHOSTTYCN_REMOTE_CWD": enabled,
                "GCN_CONFIG": config if config is not None else
                    "user fixture\nhostname example.invalid\nport 22\nrequesttty auto\nsessiontype default\nstdinnull no\nforkafterauthentication no\n",
            }
            command = [str(OPTIONS.ghostty.resolve()), "+ssh", "--terminfo=false", "--forward-env=false", f"--ssh={fake}", "--", *args]
            status, _, errors = run_process(command, env=env, cwd=root, tty=tty, commands=None if tty else b"")
            self.assertEqual(status, 0, errors.decode(errors="replace"))
            return [json.loads(line) for line in capture.read_text().splitlines()]

    def test_interactive_host_receives_exact_owned_bootstrap(self):
        arguments = ["-p", "2222", "-i", "/fixture/key with spaces", "-J", "jump", "fixture@example.invalid"]
        calls = self.invoke(arguments)
        self.assertEqual(calls[0], ["-G", *arguments])
        self.assertEqual(calls[-1][:-1], ["-t", *arguments])
        self.assertEqual(hashlib.sha256(calls[-1][-1].encode()).digest(), hashlib.sha256(COMMAND.encode()).digest())

    def test_commands_and_protocols_are_unchanged(self):
        for args in [
            ["host", "printf", "hello"], ["-s", "host", "sftp"], ["-N", "host"],
            ["-T", "host"], ["-W", "host:22", "jump"], ["-O", "check", "host"],
        ]:
            with self.subTest(args=args):
                self.assertEqual(self.invoke(args)[-1], args)

    def test_pipes_and_explicit_optout_are_unchanged(self):
        self.assertEqual(self.invoke(["host"], tty=False), [["host"]])
        self.assertEqual(self.invoke(["host"], enabled="0"), [["host"]])

    def test_user_remotecommand_and_no_tty_are_preserved(self):
        for config in [
            "requesttty auto\nsessiontype default\nremotecommand tmux attach\n",
            "requesttty no\nsessiontype default\n", "requesttty force\nsessiontype subsystem\n",
        ]:
            with self.subTest(config=config):
                self.assertEqual(self.invoke(["host"], config=config)[-1], ["host"])


if __name__ == "__main__":
    unittest.main(argv=[__file__, *UNITTEST_ARGS])
