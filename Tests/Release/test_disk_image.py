import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which("hdiutil"), "Disk images require macOS")
class DiskImageTests(unittest.TestCase):
    def test_drag_install_image_preserves_bundle_and_rejects_overwrite(self):
        script = Path(__file__).resolve().parents[2] / "scripts/create-dmg.sh"
        with tempfile.TemporaryDirectory(prefix="vela disk image ") as directory:
            root = Path(directory)
            bundle = root / "Vela.app"
            files = {
                "Contents/MacOS/Vela": b"fixture main executable\n",
                "Contents/Applications/VelaConnect.app/Contents/MacOS/VelaConnect": b"fixture controller\n",
                "Contents/Resources/fixture.txt": b"fixture resource\n",
            }
            for name, data in files.items():
                path = bundle / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
                path.chmod(0o755 if "/MacOS/" in name else 0o644)
            with (bundle / "Contents/Info.plist").open("wb") as output:
                plistlib.dump({"CFBundleShortVersionString": "1.2.3"}, output)
            image = root / "output directory/Vela fixture.dmg"
            result = subprocess.run(["zsh", str(script), str(bundle), str(image)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            digest = hashlib.sha256(image.read_bytes()).digest()
            result = subprocess.run(["zsh", str(script), str(bundle), str(image)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("new .dmg file", result.stderr)
            self.assertEqual(hashlib.sha256(image.read_bytes()).digest(), digest)
            mount = root / "mounted"
            mount.mkdir()
            subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image)],
                           check=True, capture_output=True)
            try:
                self.assertEqual((mount / "Applications").readlink(), Path("/Applications"))
                for name, data in files.items():
                    path = mount / "Vela.app" / name
                    self.assertEqual(path.read_bytes(), data)
                    if "/MacOS/" in name:
                        self.assertTrue(path.stat().st_mode & 0o111)
            finally:
                subprocess.run(["hdiutil", "detach", str(mount)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
