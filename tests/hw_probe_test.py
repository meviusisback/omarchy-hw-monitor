#!/usr/bin/env python3
"""Discovery helper: a hung nvidia-smi must not outlive hw-probe.

The panel's watchdog can only signal the Bash helper, so hw-probe bounds its
own NVIDIA child with `timeout -k 1 5`. This test fails if that guard is
deleted: the stub child hangs and the helper never returns.

Run: python3 tests/hw_probe_test.py
"""
import json
import os
import subprocess
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE = os.path.join(ROOT, "hw-probe")


class TestNvidiaDiscoveryBound(unittest.TestCase):
    def test_hung_nvidia_smi_is_bounded_and_reaped(self):
        with tempfile.TemporaryDirectory(prefix="hwprobe-stub-") as d:
            pidfile = os.path.join(d, "child.pid")
            stub = os.path.join(d, "nvidia-smi")
            with open(stub, "w") as f:
                f.write("#!/bin/bash\n")
                f.write("echo $$ > '%s'\n" % pidfile)
                f.write("exec sleep 30\n")
            os.chmod(stub, 0o755)

            env = dict(os.environ)
            env["PATH"] = d + os.pathsep + env.get("PATH", "")

            start = time.monotonic()
            try:
                proc = subprocess.run([PROBE], env=env, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, timeout=12)
            except subprocess.TimeoutExpired:
                # Clean up the orphan from a failing (guard-deleted) run.
                self._kill_stub(pidfile)
                self.fail("hw-probe hung on nvidia-smi: the timeout guard is missing")
            elapsed = time.monotonic() - start

            self.assertEqual(proc.returncode, 0,
                             proc.stderr.decode(errors="replace"))
            self.assertLess(elapsed, 9,
                            "hw-probe took %.1fs; nvidia-smi is not bounded" % elapsed)
            # A bound probe is treated as "no NVIDIA cards", not as an error.
            json.loads(proc.stdout.decode())

            # The child must be gone, not merely orphaned and forgotten.
            with open(pidfile) as f:
                child = int(f.read().strip())
            for _ in range(20):
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                os.kill(child, 9)
                self.fail("nvidia-smi child %d survived hw-probe" % child)

    @staticmethod
    def _kill_stub(pidfile):
        try:
            with open(pidfile) as f:
                os.kill(int(f.read().strip()), 9)
        except (OSError, ValueError):
            pass


if __name__ == "__main__":
    unittest.main()
