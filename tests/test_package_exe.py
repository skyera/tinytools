"""Integration checks for dist/tinytools.exe; run after `make exe` on Windows."""
from concurrent.futures import ThreadPoolExecutor
import base64
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "dist/tinytools.exe"


@unittest.skipUnless(sys.platform == "win32", "the launcher targets Windows")
class SingleExeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not EXE.is_file():
            raise RuntimeError("Build dist/tinytools.exe with make exe before running these checks")
        parent = ROOT / "build/package-tests"
        parent.mkdir(parents=True, exist_ok=True)
        cls.work = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
        assert cls.work.resolve().is_relative_to(ROOT / "build")
        cls.cwd = cls.work / "caller with spaces & symbols"
        cls.cwd.mkdir()

    def home(self, name):
        return self.work / name

    def run_exe(self, *args, home=None, exe=EXE, input=None):
        env = dict(os.environ, TINYTOOLS_HOME=str(home or self.home("default")))
        # Prove the target needs neither an installed LuaJIT nor build tools.
        env["PATH"] = str(Path(os.environ["SystemRoot"]) / "System32")
        env["TINYTOOLS_OUT"] = "deliberately-invalid-inherited-value"
        return subprocess.run([str(exe), *args], cwd=self.cwd, env=env, input=input,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)

    def test_01_first_launch_and_warm_cache(self):
        home = self.home("cold and warm")
        first = self.run_exe("--list", "--json", home=home)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(len(json.loads(first.stdout)), 5)
        versions = list((home / "cache").iterdir())
        self.assertEqual(len(versions), 1)
        cache = versions[0]
        self.assertRegex(cache.name, r"^[a-f0-9]{64}$")
        script = cache / "apps/toolbox.lua"
        before = script.stat().st_mtime_ns
        again = self.run_exe("--list", "--json", home=home)
        self.assertEqual(json.loads(again.stdout), json.loads(first.stdout))
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(script.stat().st_mtime_ns, before, "warm launch should reuse valid files")
        self.assertTrue((home / "state").is_dir())
        self.assertFalse((cache / "state").exists())

    def test_02_argument_quoting_and_empty_arguments(self):
        for text in ["", 'a "quoted" value', "trailing\\", 'slash\\"quote',
                     "spaces & | > < %PATH% ! $ ` ( )", "first\nsecond"]:
            with self.subTest(text=text):
                result = self.run_exe("--run", "data.base64", "--text", text)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.rstrip(b"\r\n"), base64.b64encode(text.encode()))

    def test_03_stdin_and_relative_input_paths(self):
        result = self.run_exe("--run", "data.base64", "--in", "-", input=b"hello\nworld")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), base64.b64encode(b"hello\nworld"))
        (self.cwd / "input with spaces.txt").write_bytes(b"from the caller")
        result = self.run_exe("--run", "data.base64", "--in", "input with spaces.txt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), base64.b64encode(b"from the caller"))

    def test_04_exit_codes_and_stderr(self):
        result = self.run_exe("--run", "missing.tool")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"unknown tool", result.stderr)
        result = self.run_exe("--run", "data.json", "--text", "{")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"invalid JSON", result.stderr)

    def test_05_repairs_modified_and_missing_cache_files(self):
        home = self.home("repair")
        self.assertEqual(self.run_exe("--list", home=home).returncode, 0)
        cache = next((home / "cache").iterdir())
        script = cache / "lib/cli.lua"
        original = script.read_bytes()
        script.write_bytes(b"os.exit(77)\n")
        (cache / "build/out/glfw3.dll").unlink()
        result = self.run_exe("--smoke", "3", home=home)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(script.read_bytes(), original)
        self.assertTrue((cache / "build/out/glfw3.dll").is_file())

    def test_06_concurrent_cold_start(self):
        home = self.home("concurrent")
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.run_exe("--list", home=home), range(4)))
        for result in results:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, results[0].stdout)

    def test_07_stable_settings_and_gui_layout_location(self):
        home = self.home("settings")
        self.assertEqual(self.run_exe("--list", home=home).returncode, 0)
        settings = home / "state/settings.json"
        saved = b'{"favorites":{"data.json":true}}'
        settings.write_bytes(saved)
        result = self.run_exe("--smoke", "5", home=home)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(settings.read_bytes(), saved)
        self.assertTrue((home / "state/imgui.ini").is_file())
        self.assertFalse((self.cwd / "imgui.ini").exists(), "GUI must not write into the caller's folder")

    def test_08_unwritable_home_fails_cleanly(self):
        home = self.home("a file instead of directory")
        home.write_bytes(b"test")
        result = self.run_exe("--list", home=home)
        self.assertEqual(result.returncode, 125)
        self.assertIn(b"Cannot create the application cache", result.stderr)

    def test_09_damaged_embedded_bundle_is_rejected(self):
        payload = (ROOT / "build/single-exe/bundle.bin").read_bytes()
        data = bytearray(EXE.read_bytes())
        offset = data.find(payload)
        self.assertGreater(offset, 0)
        data[offset + len(payload) // 2] ^= 255
        damaged = self.work / "damaged.exe"
        damaged.write_bytes(data)
        result = self.run_exe("--list", home=self.home("bad payload"), exe=damaged)
        self.assertEqual(result.returncode, 125)
        self.assertIn(b"Cannot unpack", result.stderr)

    def test_10_gui_subsystem_has_no_console_on_double_click(self):
        data = EXE.read_bytes()
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        self.assertEqual(data[pe:pe + 4], b"PE\0\0")
        self.assertEqual(struct.unpack_from("<H", data, pe + 24 + 68)[0], 2)

    def test_11_bundled_selftests_and_longer_gui_smoke(self):
        check = self.run_exe("--check")
        self.assertEqual(check.returncode, 0, check.stderr)
        self.assertIn(b"binding=loadable", check.stdout)
        self.assertIn(b"0 failing", check.stdout)
        smoke = self.run_exe("--smoke", "300")
        self.assertEqual(smoke.returncode, 0, smoke.stderr)
        self.assertIn(b"rendered 300 frames", smoke.stdout)


class ArchiveTests(unittest.TestCase):
    def test_content_version_changes_only_with_content(self):
        spec = importlib.util.spec_from_file_location("package_exe", ROOT / "scripts/package_exe.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        parent = ROOT / "build/package-tests"
        parent.mkdir(parents=True, exist_ok=True)
        fixture = Path(tempfile.mkdtemp(prefix="archive-", dir=parent))
        item = fixture / "file.lua"
        item.write_bytes(b"return 1")
        first = module.archive(fixture)
        self.assertEqual(first, module.archive(fixture))
        item.write_bytes(b"return 2")
        self.assertNotEqual(first, module.archive(fixture))


if __name__ == "__main__":
    unittest.main()
