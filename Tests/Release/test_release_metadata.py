import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_metadata", Path(__file__).resolve().parents[2] / "scripts/release-metadata.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseMetadataTests(unittest.TestCase):
    def test_partial_signing_configuration_fails_before_packaging(self):
        script = Path(__file__).resolve().parents[2] / "scripts/package-ci.sh"
        keys = ["MACOS_CERTIFICATE_P12_BASE64", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY"]
        for configured in keys:
            environment = {key: value for key, value in os.environ.items() if key not in keys}
            environment.update(VELA_VERSION="1.2.3", VELA_BUILD_NUMBER="12")
            environment[configured] = "fixture"
            result = subprocess.run(["zsh", str(script)], env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("All three signing secrets", result.stderr)

    def test_workflow_is_tag_only_and_manual_runs_require_a_tag(self):
        path = Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
        data = json.loads(subprocess.check_output(["ruby", "-ryaml", "-rjson", "-e",
            "puts JSON.generate(YAML.load_file(ARGV[0]))", str(path)], text=True))
        triggers = data.get("on", data.get("true"))
        self.assertEqual(triggers["push"], {"tags": ["v*"]})
        self.assertTrue(triggers["workflow_dispatch"]["inputs"]["tag"]["required"])
        self.assertEqual(data["permissions"], {"contents": "read"})
        self.assertEqual(data["jobs"]["publish"]["permissions"], {"contents": "write"})

    def test_tag_must_point_at_the_checkout(self):
        script = Path(__file__).resolve().parents[2] / "scripts/release-metadata.py"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)
            git("init", "-b", "main")
            def commit():
                git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
                    "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture")
            commit(); git("tag", "v1.2.3")
            output = root / "outputs"
            environment = dict(os.environ, RELEASE_TAG="v1.2.3", GITHUB_RUN_NUMBER="12",
                               PUBLISH_RELEASE="true", GITHUB_OUTPUT=str(output))
            result = subprocess.run(["python3", str(script)], cwd=root, env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("version=1.2.3", output.read_text())
            output.unlink(); commit()
            result = subprocess.run(["python3", str(script)], cwd=root, env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("checked-out commit", result.stderr)
            self.assertFalse(output.exists())

    def test_branch_build_cannot_produce_an_artifact_without_a_tag(self):
        with self.assertRaises(ValueError):
            release.metadata("", "12", False)
        result = release.metadata("v1.2.3", "12", False)
        self.assertEqual((result["version"], result["publish"], result["tag"]), ("1.2.3", "false", "v1.2.3"))

    def test_tag_sets_numeric_bundle_version_and_prerelease_flag(self):
        result = release.metadata("v2.3.4-beta.1", "24", True)
        self.assertEqual((result["version"], result["prerelease"], result["publish"]), ("2.3.4", "true", "true"))
        self.assertEqual(release.metadata("v2.3.4", "25", True)["prerelease"], "false")

    def test_rejects_unsafe_tags_and_missing_publish_target(self):
        for tag in ["v1.2", "v01.2.3", "v1.2.3/other", "v1.2.3\nversion=9.9.9", "$(id)", "--help"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.metadata(tag, "1", True)
        with self.assertRaises(ValueError):
            release.metadata("", "1", True)
        with self.assertRaises(ValueError):
            release.metadata("v1.2.3", "1\nbuild=2", True)


if __name__ == "__main__":
    unittest.main()
