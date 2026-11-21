#!/usr/bin/env python3
"""The Node Manager UI's hardware tiers mirror the library's.

check_hardware in lib/common.sh (setup-node.sh's preflight) reads the
`readonly HW_TESTNET_*` and `readonly HW_MAINNET_*` constants; the setup
wizard's preflight reads HW_TIERS and HW_VALIDATOR_RECOMMENDED in ui/server.py.
A host must get the same verdict from both, so every constant must exist in the
library and hold the value ui/server.py has, and the library must hold no
HW_TESTNET_* or HW_MAINNET_* constant that ui/server.py does not mirror.

TN_HW_MIRROR_LIB names another copy of lib/common.sh to read (default: the
repository's).

No network, no sudo. Python 3.10 or later with Flask (ui/requirements.txt):

    python3 -m pytest -q ui/test_hw_mirror.py
"""

import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import server  # noqa: E402

LIB_COMMON = (os.environ.get("TN_HW_MIRROR_LIB")
              or os.path.join(os.path.dirname(HERE), "lib", "common.sh"))

# One `readonly NAME=value` per statement (statements may share a line with ;).
_CONST = re.compile(r"readonly (HW_(TESTNET|MAINNET)_[A-Z_]+)=([0-9]+)")

# The library's name stem for each role of HW_TIERS, and for the recommended
# validator host.
_ROLE_STEM = {"node": "NODE_MIN", "rpc": "RPC_MIN", "validator": "VAL_MIN"}
_RECOMMENDED_STEM = "VAL_REC"


def expected_constants():
    """{library constant name: value} as ui/server.py has them."""
    out = {}
    for net, tiers in server.HW_TIERS.items():
        prefix = "HW_%s_" % net.upper()
        for role, _label, cpu, ram_gb, disk_gb in tiers:
            stem = prefix + _ROLE_STEM[role]
            out.update({stem + "_CPU": cpu, stem + "_RAM_GB": ram_gb,
                        stem + "_DISK_GB": disk_gb})
    for net, rec in server.HW_VALIDATOR_RECOMMENDED.items():
        stem = "HW_%s_%s" % (net.upper(), _RECOMMENDED_STEM)
        out.update({stem + "_CPU": rec["cpu"], stem + "_RAM_GB": rec["ram_gb"],
                    stem + "_DISK_GB": rec["disk_gb"]})
    return out


def library_constants(path):
    """[(name, value)] for each HW_TESTNET_* / HW_MAINNET_* constant in `path`,
    in file order (a name defined twice appears twice)."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    return [(m.group(1), int(m.group(3))) for m in _CONST.finditer(text)]


class HardwareMirrorTest(unittest.TestCase):

    def setUp(self):
        self.assertTrue(os.path.isfile(LIB_COMMON), "no library to compare with: " + LIB_COMMON)
        self.found = library_constants(LIB_COMMON)
        self.expected = expected_constants()

    def test_the_server_names_both_networks_and_every_tier(self):
        self.assertEqual(set(server.HW_TIERS), {"testnet", "mainnet"})
        self.assertEqual(set(server.HW_VALIDATOR_RECOMMENDED), {"testnet", "mainnet"})
        self.assertEqual(len(self.expected), 24, sorted(self.expected))

    def test_every_constant_is_in_the_library(self):
        names = {name for name, _value in self.found}
        missing = sorted(set(self.expected) - names)
        self.assertEqual(missing, [], "%s lacks %d of the %d hardware constants "
                         "ui/server.py mirrors: %s"
                         % (LIB_COMMON, len(missing), len(self.expected), ", ".join(missing)))

    def test_the_library_has_no_constant_the_server_lacks(self):
        extra = sorted({name for name, _value in self.found} - set(self.expected))
        self.assertEqual(extra, [], "constants in %s that ui/server.py does not mirror: %s"
                         % (LIB_COMMON, ", ".join(extra)))

    def test_each_constant_is_defined_once(self):
        names = [name for name, _value in self.found]
        twice = sorted({name for name in names if names.count(name) > 1})
        self.assertEqual(twice, [], "defined more than once in " + LIB_COMMON)

    def test_every_value_matches(self):
        found = dict(self.found)
        wrong = ["%s: library %s, ui/server.py %s" % (name, found[name], want)
                 for name, want in sorted(self.expected.items())
                 if name in found and found[name] != want]
        self.assertEqual(wrong, [], "hardware tiers differ between %s and ui/server.py"
                         % LIB_COMMON)


if __name__ == "__main__":
    unittest.main()
