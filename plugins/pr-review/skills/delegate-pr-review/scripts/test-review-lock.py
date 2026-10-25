#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("review-lock.py")
FIRST = "12345678-1234-4234-8234-123456789abc"
SECOND = "99999999-9999-4999-8999-999999999999"


class ReviewLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def command(self, action="acquire", request=FIRST, pr="https://github.com/acme/widget/pull/42"):
        return [sys.executable, str(SCRIPT), action, "--pr", pr, "--request-id", request,
                "--state-path", str(self.root / (request + ".json")),
                "--registry-root", str(self.root / "registry")]

    def run_lock(self, *args, **kwargs):
        result = subprocess.run(self.command(*args, **kwargs), capture_output=True, text=True)
        return result.returncode, json.loads(result.stdout)

    def test_only_one_concurrent_request_acquires(self):
        first = subprocess.Popen(self.command(request=FIRST), stdout=subprocess.PIPE, text=True)
        second = subprocess.Popen(self.command(request=SECOND), stdout=subprocess.PIPE, text=True)
        results = []
        for process in (first, second):
            stdout, _ = process.communicate()
            results.append((process.returncode, json.loads(stdout)))
        self.assertEqual(sorted(code for code, _ in results), [0, 3])
        self.assertEqual(sorted(data["status"] for _, data in results), ["acquired", "busy"])

    def test_resume_and_release_are_owner_scoped(self):
        self.assertEqual(self.run_lock()[1]["status"], "acquired")
        self.assertEqual(self.run_lock()[1]["status"], "owned")
        self.assertEqual(self.run_lock("release", request=SECOND)[0], 3)
        self.assertEqual(self.run_lock(request=SECOND)[0], 3)
        self.assertEqual(self.run_lock("release")[1]["status"], "released")
        self.assertEqual(self.run_lock(request=SECOND)[1]["status"], "acquired")

    def test_url_case_and_trailing_slash_share_lock(self):
        self.run_lock()
        code, result = self.run_lock(request=SECOND, pr="https://GITHUB.COM/Acme/Widget/pull/42/")
        self.assertEqual((code, result["status"]), (3, "busy"))

    def test_incomplete_owner_is_not_stolen(self):
        _, result = self.run_lock()
        owner = Path(result["lock_path"]) / "owner.json"
        owner.write_text("{")
        self.assertEqual(self.run_lock()[0], 3)
        self.assertEqual(self.run_lock("release")[0], 3)
        self.assertEqual(owner.read_text(), "{")

    def test_distinct_pull_requests_do_not_block_each_other(self):
        self.run_lock()
        code, result = self.run_lock(request=SECOND, pr="https://github.com/acme/widget/pull/43")
        self.assertEqual((code, result["status"]), (0, "acquired"))


if __name__ == "__main__":
    unittest.main()
