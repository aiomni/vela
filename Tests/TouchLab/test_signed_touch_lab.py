import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SignedTouchLabSafetyTests(unittest.TestCase):
    def test_ad_hoc_identity_is_rejected_before_build_or_secret_read(self):
        module = load_script('build-touch-lab')
        with patch.dict(os.environ, {'SIGNING_IDENTITY': '-'}, clear=True), \
                patch.object(sys, 'argv', ['build-touch-lab']), \
                patch.object(module, 'checked') as checked, \
                patch.object(Path, 'read_text') as read_text:
            with self.assertRaisesRegex(RuntimeError, 'no ad-hoc fallback'):
                module.main()
            checked.assert_not_called()
            read_text.assert_not_called()

    def test_signing_failure_does_not_log_identity_or_raw_diagnostics(self):
        module = load_script('build-touch-lab')
        secret = 'fixture-only-private-signing-configuration'
        result = subprocess.CompletedProcess(['codesign'], 31, b'', secret.encode())
        with patch.object(module.subprocess, 'run', return_value=result):
            with self.assertRaises(RuntimeError) as failure:
                module.checked(['codesign', '--sign', secret], 'Signing')
            self.assertNotIn(secret, str(failure.exception))
            self.assertIn('no signing fallback', str(failure.exception))

    def test_signing_timeout_does_not_expose_arguments(self):
        module = load_script('build-touch-lab')
        secret = 'fixture-only-certificate-name'
        with patch.object(module.subprocess, 'run', side_effect=subprocess.TimeoutExpired([secret], 1)):
            with self.assertRaises(RuntimeError) as failure:
                module.checked([secret], 'Signing')
            self.assertNotIn(secret, str(failure.exception))

    def test_capture_runner_never_accepts_input_injection_mode(self):
        module = load_script('probe-signed-touch-lab')
        with patch.object(sys, 'argv', ['probe-signed-touch-lab', '--app', '/unused/VelaTouchLab.app',
                                        '--mode', 'run', '--output', '/unused/evidence.json']), \
                patch.object(module.subprocess, 'Popen') as spawn, \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as failure:
                module.main()
            self.assertEqual(failure.exception.code, 2)
            spawn.assert_not_called()

    def test_capture_runner_rejects_non_lab_target_before_verification(self):
        module = load_script('probe-signed-touch-lab')
        with patch.object(sys, 'argv', ['probe-signed-touch-lab', '--app', '/Applications/Vela.app',
                                        '--output', '/unused/evidence.json']), \
                patch.object(module.subprocess, 'run') as verify:
            with self.assertRaisesRegex(RuntimeError, 'isolated lab artifact'):
                module.main()
            verify.assert_not_called()


if __name__ == '__main__':
    unittest.main()
