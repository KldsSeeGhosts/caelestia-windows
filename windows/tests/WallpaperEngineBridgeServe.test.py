import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parents[1] / "services/wallpaperengine/bridge.py"
spec = importlib.util.spec_from_file_location("wallpaperengine_bridge", MODULE_PATH)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class WallpaperEngineBridgeServeTests(unittest.TestCase):
    def test_snapshot_request_dispatches_status_mode(self):
        original = bridge.snapshot
        calls = []
        try:
            bridge.snapshot = lambda status_only=False: calls.append(status_only) or {"ok": True, "statusOnly": status_only}
            result = bridge.handle_bridge_request({"command": "snapshot", "statusOnly": True})
        finally:
            bridge.snapshot = original
        self.assertEqual(calls, [True])
        self.assertEqual(result, {"ok": True, "statusOnly": True})

    def test_unsupported_request_fails_closed(self):
        result = bridge.handle_bridge_request({"command": "exec"})
        self.assertFalse(result["ok"])
        self.assertIn("unsupported", result["error"])

    def test_handler_exceptions_are_json_errors_not_worker_exits(self):
        original = bridge.snapshot
        try:
            bridge.snapshot = lambda status_only=False: (_ for _ in ()).throw(ValueError("fixture failure"))
            result = bridge.handle_bridge_request({"command": "snapshot"})
        finally:
            bridge.snapshot = original
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "fixture failure")

    def test_cli_handles_multiple_lines_and_exits_on_eof(self):
        result = subprocess.run(
            [sys.executable, "-B", str(MODULE_PATH), "--serve"],
            input='[]\n{"command":"exec"}\n', text=True, capture_output=True,
            check=True, timeout=10,
        )
        responses = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(len(responses), 2)
        self.assertIn("invalid", responses[0]["error"])
        self.assertIn("unsupported", responses[1]["error"])
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
