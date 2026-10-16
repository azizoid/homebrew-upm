import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


loader = importlib.machinery.SourceFileLoader("upm", str(Path(__file__).with_name("brew-upm")))
spec = importlib.util.spec_from_loader(loader.name, loader)
upm = importlib.util.module_from_spec(spec)
loader.exec_module(upm)


def package(name, old="1.2.3", new="1.2.4", pinned=False):
    return {"name": name, "installed_versions": [old], "current_version": new, "pinned": pinned}


class UpmTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = Path(self.temp.name) / "packages.txt"
        self.env = patch.dict(os.environ, {"BREW_UPM_CONFIG": str(self.config)})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.output = io.StringIO()

    def run_cli(self, args, outdated=None, installed=None, fail=None):
        calls = []

        def brew(args, capture=False):
            calls.append(args)
            if fail and args[:len(fail)] == fail:
                raise upm.UpmError("simulated brew failure")
            if args == ["outdated", "--json=v2"]:
                return json.dumps(outdated or {"formulae": [], "casks": []})
            if args[:1] == ["list"]:
                return "\n".join((installed or {}).get(args[1], []))
            return ""

        with patch.object(upm, "brew", side_effect=brew), contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            status = upm.main(args)
        return status, calls

    def test_patch_revision_and_comma_build_are_skipped(self):
        self.config.write_text("cask:docker-desktop\nformula:tool\n")
        status, calls = self.run_cli([], {"formulae": [package("tool", "1.2.3_1", "1.2.3_2")], "casks": [package("docker-desktop", "4.93.0,1", "4.93.1,2")]})
        self.assertEqual(status, 0)
        self.assertFalse(any(call[0] in {"upgrade", "pin", "unpin"} for call in calls))
        self.assertIn("patch", self.output.getvalue())

    def test_upgrades_all_unlisted_and_minor_or_major_listed_packages(self):
        self.config.write_text("formula:minor\ncask:major\n")
        status, calls = self.run_cli([], {"formulae": [package("minor", new="1.3.0"), package("unlisted")], "casks": [package("major", new="2.0.0"), package("plain")]})
        self.assertEqual(status, 0)
        self.assertEqual(calls[0], ["update"])
        self.assertIn(["upgrade", "--formula", "minor", "unlisted"], calls)
        self.assertIn(["upgrade", "--cask", "major", "plain"], calls)

    def test_unknown_and_existing_pin_never_become_upgrade_targets(self):
        self.config.write_text("cask:unknown\nformula:pinned\n")
        status, calls = self.run_cli([], {"formulae": [package("pinned", new="2.0.0", pinned=True)], "casks": [package("unknown", "latest", "2.0.0"), package("normal")]})
        self.assertEqual(status, 0)
        self.assertIn(["pin", "--cask", "unknown"], calls)
        self.assertIn(["unpin", "--cask", "unknown"], calls)
        self.assertFalse(any("pinned" in call for call in calls))
        self.assertIn("cannot compare", self.output.getvalue())

    def test_restores_temporary_pins_after_failed_upgrade(self):
        self.config.write_text("formula:protected\n")
        status, calls = self.run_cli([], {"formulae": [package("protected"), package("normal")], "casks": []}, fail=["upgrade"])
        self.assertEqual(status, 1)
        self.assertLess(calls.index(["pin", "--formula", "protected"]), calls.index(["upgrade", "--formula", "normal"]))
        self.assertEqual(calls[-1], ["unpin", "--formula", "protected"])

    def test_pin_failure_prevents_upgrades_and_restores_prior_pins(self):
        self.config.write_text("formula:one\ncask:two\n")
        status, calls = self.run_cli([], {"formulae": [package("one"), package("normal")], "casks": [package("two")]}, fail=["pin", "--cask"])
        self.assertEqual(status, 1)
        self.assertFalse(any(call[0] == "upgrade" for call in calls))
        self.assertIn(["unpin", "--formula", "one"], calls)

    def test_dry_run_does_not_mutate_brew(self):
        self.config.write_text("cask:docker-desktop\n")
        status, calls = self.run_cli(["--dry-run"], {"formulae": [package("tool")], "casks": [package("docker-desktop")]})
        self.assertEqual(status, 0)
        self.assertEqual(calls, [["outdated", "--json=v2"]])
        self.assertIn("Would upgrade formula:tool", self.output.getvalue())

    def test_list_add_remove_round_trip_uses_personal_config(self):
        installed = {"--formula": ["wget"], "--cask": ["docker-desktop"]}
        status, calls = self.run_cli(["add", "docker-desktop", "wget"], installed=installed)
        self.assertEqual(status, 0)
        self.assertEqual(set(self.config.read_text().splitlines()), {"cask:docker-desktop", "formula:wget"})
        status, calls = self.run_cli(["list"])
        self.assertEqual(status, 0)
        self.assertEqual(calls, [])
        self.assertIn("cask:docker-desktop", self.output.getvalue())
        status, calls = self.run_cli(["remove", "wget"])
        self.assertEqual(status, 0)
        self.assertNotIn("wget", self.config.read_text())

    def test_ambiguous_or_uninstalled_add_does_not_change_config(self):
        installed = {"--formula": ["same"], "--cask": ["same"]}
        status, _ = self.run_cli(["add", "same"], installed=installed)
        self.assertEqual(status, 1)
        self.assertIn("formula:same", self.output.getvalue())
        self.assertFalse(self.config.exists())
        status, _ = self.run_cli(["add", "missing"], installed=installed)
        self.assertEqual(status, 1)
        self.assertFalse(self.config.exists())
        status, _ = self.run_cli(["add", "cask:same"], installed=installed)
        self.assertEqual(status, 0)
        self.assertEqual(self.config.read_text(), "cask:same\n")

    def test_multiple_installed_versions_use_newest_for_policy(self):
        self.config.write_text("formula:tool\n")
        item = package("tool", new="2.3.1")
        item["installed_versions"] = ["1.0.0", "2.3.0"]
        status, calls = self.run_cli([], {"formulae": [item], "casks": []})
        self.assertEqual(status, 0)
        self.assertFalse(any(call[0] == "upgrade" for call in calls))

    def test_invalid_json_or_config_fails_before_upgrade(self):
        self.config.write_text("--danger\n")
        status, calls = self.run_cli([])
        self.assertEqual(status, 1)
        self.assertEqual(calls, [])
        self.config.unlink()
        with patch.object(upm, "brew", return_value="invalid json"), contextlib.redirect_stderr(self.output):
            self.assertEqual(upm.main(["--dry-run"]), 1)

    def test_version_comparison_is_conservative(self):
        for value in ["latest", "HEAD", "unknown", "1", "1.3.0-rc1", "1.2.bad"]:
            with self.subTest(value=value):
                self.assertIsNone(upm.version_tuple(value))
        self.assertEqual(upm.version_tuple("v1.2.3_2,456"), (1, 2, 3))
        self.assertEqual(upm.version_tuple("1.2"), (1, 2))

    def test_homebrew_command_failures_are_readable(self):
        with patch.object(upm.subprocess, "run", side_effect=FileNotFoundError):
            with self.assertRaisesRegex(upm.UpmError, "not found"):
                upm.brew(["update"])
        error = subprocess.CalledProcessError(1, ["brew"], stderr="network unavailable")
        with patch.object(upm.subprocess, "run", side_effect=error):
            with self.assertRaisesRegex(upm.UpmError, "network unavailable"):
                upm.brew(["outdated"], capture=True)

    def test_tap_formula_identity_is_preserved(self):
        status, _ = self.run_cli(["add", "tool"], installed={"--formula": ["owner/tap/tool"]})
        self.assertEqual(status, 0)
        self.assertEqual(self.config.read_text(), "formula:owner/tap/tool\n")
        status, calls = self.run_cli([], {"formulae": [package("owner/tap/tool")], "casks": []})
        self.assertEqual(status, 0)
        self.assertFalse(any(call[0] == "upgrade" for call in calls))

    def test_busy_upgrade_lock_prevents_brew_calls(self):
        with upm.upgrade_lock():
            status, calls = self.run_cli([])
        self.assertEqual(status, 1)
        self.assertEqual(calls, [])
        self.assertIn("Another brew upm", self.output.getvalue())

    def test_interrupt_restores_all_temporary_pins(self):
        calls = []

        def brew(args):
            calls.append(args)

        with patch.object(upm, "brew", side_effect=brew):
            with self.assertRaises(KeyboardInterrupt):
                with upm.temporary_pins(["formula:one", "cask:two"]):
                    raise KeyboardInterrupt
        self.assertEqual(calls[-2:], [["unpin", "--cask", "two"], ["unpin", "--formula", "one"]])

    def test_cleanup_failure_reports_recovery_and_attempts_remaining_pins(self):
        calls = []

        def brew(args):
            calls.append(args)
            if args == ["unpin", "--cask", "two"]:
                raise upm.UpmError("failed")

        with patch.object(upm, "brew", side_effect=brew):
            with self.assertRaisesRegex(upm.UpmError, "brew unpin --cask two"):
                with upm.temporary_pins(["formula:one", "cask:two"]):
                    pass
        self.assertEqual(calls[-1], ["unpin", "--formula", "one"])

    def test_cli_runs_complete_upgrade_flow_against_fake_homebrew(self):
        self.config.write_text("cask:docker-desktop\n")
        fake_brew = Path(self.temp.name) / "brew"
        log = Path(self.temp.name) / "calls.jsonl"
        data = {"formulae": [package("wget")], "casks": [package("docker-desktop")]}
        fake_brew.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"with open({str(log)!r}, 'a') as handle:\n"
            "    handle.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "assert os.environ['HOMEBREW_NO_AUTO_UPDATE'] == '1'\n"
            "if sys.argv[1] == 'outdated':\n"
            f"    print({json.dumps(data)!r})\n"
        )
        fake_brew.chmod(0o755)
        env = {**os.environ, "PATH": f"{self.temp.name}:{os.environ.get('PATH', '')}"}
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("brew-upm"))], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(line) for line in log.read_text().splitlines()], [
            ["update"], ["outdated", "--json=v2"],
            ["pin", "--cask", "docker-desktop"],
            ["upgrade", "--formula", "wget"],
            ["unpin", "--cask", "docker-desktop"],
        ])


if __name__ == "__main__":
    unittest.main()
