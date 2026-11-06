#!/usr/bin/env python3
"""Bounds for proc_top.py: merge candidates and scan-host cardinality.

Run: python3 tests/proc_top_test.py
"""
import os
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import proc_top


class TestMergeBound(unittest.TestCase):
    def test_distinct_comms_fast(self):
        snap = {i: (100 + i, 10, "p%04d" % i, 1, "")
                for i in range(1, 4097)}
        start = time.monotonic()
        rows, grouped = proc_top.build_rows(
            snap, snap, 100000, 16000000, 4, True)
        self.assertLess(time.monotonic() - start, 2.0)
        self.assertEqual(len(rows), 4096)
        self.assertEqual(grouped, "comm")

    def test_sep_prefix_merge_intact(self):
        snap = {1: (100, 10, "orca", 1, ""),
                2: (100, 10, "orca-ide", 1, ""),
                3: (100, 10, "pipewire", 1, ""),
                4: (100, 10, "pi", 1, "")}
        rows, _ = proc_top.build_rows(snap, snap, 1000, 16000000, 4, True)
        got = sorted((r["name"], r["count"]) for r in rows)
        self.assertEqual(got, [("orca", 2), ("pi", 1), ("pipewire", 1)])


class TestScanHostsCap(unittest.TestCase):
    def test_cardinality_capped(self):
        # Plant distinct URLs in our own address space, then scan ourselves:
        # self-mem is always readable, no fixture process needed.
        blob = b" ".join(b"https://t%d.captest/" % i for i in range(20000))
        self._blob = blob  # keep alive during the scan
        counts, complete = proc_top._scan_hosts(os.getpid(), None)
        planted = [h for h in counts if h.endswith(".captest")]
        self.assertLessEqual(len(counts), proc_top.SCAN_HOSTS_CAP)
        if len(planted) >= proc_top.SCAN_HOSTS_CAP:
            self.assertFalse(complete)
        self.assertGreater(len(planted), 100)


if __name__ == "__main__":
    unittest.main()
