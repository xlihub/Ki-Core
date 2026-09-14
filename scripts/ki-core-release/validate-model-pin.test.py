"""验证 Core 固定 SDK 来源的公开校验命令。"""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ki-core-release/validate-model-pin.py"


class ModelPinTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for name in ("Cargo.toml", "Cargo.lock", "ki-core-model.json"):
            shutil.copyfile(ROOT / name, self.root / name)

    def check(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), *args],
            capture_output=True, text=True, check=False,
        )

    def test_current_fixed_source_is_consistent(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_upstream_sync_cannot_replace_accepted_product_pin(self):
        path = self.root / "Cargo.toml"
        path.write_text(path.read_text().replace("xlihub/Ki-Model", "iOfficeAI/aionrs"))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("aion-agent", result.stderr)

    def test_mixed_locked_types_are_rejected(self):
        path = self.root / "Cargo.lock"
        path.write_text(path.read_text().replace("xlihub/Ki-Model", "iOfficeAI/aionrs", 1))
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("locked SDK source", result.stderr)

    def test_local_patch_cannot_bypass_pin(self):
        path = self.root / "Cargo.toml"
        with path.open("a") as file:
            file.write('\n[patch."https://github.com/xlihub/Ki-Model.git"]\naion-types = { path = "/synthetic" }\n')
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("patch", result.stderr)

    def test_unverified_sdk_cannot_enter_a_core_release(self):
        path = self.root / "ki-core-model.json"
        data = json.loads(path.read_text())
        data["releaseVerified"] = False
        path.write_text(json.dumps(data))
        result = self.check("--require-release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not release-verified", result.stderr)


if __name__ == "__main__":
    unittest.main()
