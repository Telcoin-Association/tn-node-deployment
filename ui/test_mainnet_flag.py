#!/usr/bin/env python3
"""The Node Manager UI's mainnet switches follow the library's.

`readonly TN_MAINNET_ENABLED=<0|1>` in lib/common.sh decides whether a script
release offers mainnet (the network menu, setup-node.sh --json, the UI helper's
setup). ui/server.py keeps its own TN_MAINNET_ENABLED (no mainnet image is looked
up while it is False) and the page its SETUP_MAINNET_ENABLED (the wizard's
mainnet card). The release that flips the library line flips both; these tests
fail when one of them is left behind.

No network, no sudo. Python 3.10 or later with Flask (ui/requirements.txt):

    python3 -m unittest discover -s ui -p 'test_*.py'
"""

import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import server  # noqa: E402

LIB_COMMON = os.path.join(os.path.dirname(HERE), "lib", "common.sh")
INDEX = os.path.join(HERE, "static", "index.html")

TIE = ("TN_MAINNET_ENABLED in lib/common.sh, TN_MAINNET_ENABLED in ui/server.py and "
       "SETUP_MAINNET_ENABLED in ui/static/index.html must change together, in the "
       "release that offers mainnet")

_LIB_LINE = re.compile(r"^readonly TN_MAINNET_ENABLED=(.*)$", re.M)
_PAGE_LINE = re.compile(r"^const SETUP_MAINNET_ENABLED = (.*);$", re.M)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def library_flag(text):
    """True or False from the one `readonly TN_MAINNET_ENABLED=0|1` line of a
    lib/common.sh text. ValueError when the line is missing, doubled or holds
    anything else."""
    found = _LIB_LINE.findall(text)
    if len(found) != 1:
        raise ValueError("lib/common.sh needs exactly one 'readonly TN_MAINNET_ENABLED=0|1' "
                         "line, found %d" % len(found))
    if found[0] not in ("0", "1"):
        raise ValueError("TN_MAINNET_ENABLED in lib/common.sh is %r, not 0 or 1" % found[0])
    return found[0] == "1"


def page_flag(text):
    """True or False from the page's `const SETUP_MAINNET_ENABLED = true|false;`."""
    found = _PAGE_LINE.findall(text)
    if len(found) != 1 or found[0] not in ("true", "false"):
        raise ValueError("index.html needs exactly one 'const SETUP_MAINNET_ENABLED = "
                         "true|false;' line, found %r" % found)
    return found[0] == "true"


def drift(lib_text, server_value, page_text):
    """'' when the server and the page follow the library, else what differs."""
    lib = library_flag(lib_text)
    out = []
    if server_value is not lib:
        out.append("ui/server.py TN_MAINNET_ENABLED is %s, the library's is %d"
                   % (server_value, lib))
    if page_flag(page_text) is not lib:
        out.append("index.html SETUP_MAINNET_ENABLED is %s, the library's is %d"
                   % (str(page_flag(page_text)).lower(), lib))
    return "; ".join(out + [TIE]) if out else ""


def lib_text(value):
    return ("readonly MAINNET_RPC_URL=\"https://rpc.telcoin.network\"\n"
            "readonly TN_MAINNET_ENABLED=%s\n"
            "tn_mainnet_enabled() {\n    [[ \"$TN_MAINNET_ENABLED\" == \"1\" ]]\n}\n" % value)


def page_text(value):
    return "const SETUP_MAINNET_ENABLED = %s;\n" % ("true" if value else "false")


class MainnetFlagTieTest(unittest.TestCase):

    def test_the_server_follows_the_library(self):
        self.assertIsInstance(server.TN_MAINNET_ENABLED, bool)
        self.assertIs(server.TN_MAINNET_ENABLED, library_flag(read(LIB_COMMON)), TIE)

    def test_the_page_follows_the_library(self):
        self.assertIs(page_flag(read(INDEX)), library_flag(read(LIB_COMMON)), TIE)

    def test_the_repository_has_no_drift(self):
        self.assertEqual(drift(read(LIB_COMMON), server.TN_MAINNET_ENABLED, read(INDEX)), "")

    def test_both_library_values_are_read_and_drift_is_caught_either_way(self):
        for value, on in (("0", False), ("1", True)):
            with self.subTest(value=value):
                self.assertIs(library_flag(lib_text(value)), on)
                self.assertEqual(drift(lib_text(value), on, page_text(on)), "")
                msg = drift(lib_text(value), not on, page_text(on))
                self.assertIn("ui/server.py TN_MAINNET_ENABLED is %s" % (not on), msg)
                self.assertIn("must change together", msg)
                msg = drift(lib_text(value), on, page_text(not on))
                self.assertIn("index.html SETUP_MAINNET_ENABLED", msg)
                self.assertIn("must change together", msg)

    def test_a_missing_doubled_or_odd_library_line_is_an_error(self):
        for text in ("", "TN_MAINNET_ENABLED=1\n", "readonly TN_MAINNET_ENABLED=true\n",
                     'readonly TN_MAINNET_ENABLED="1"\n', "readonly TN_MAINNET_ENABLED=1 # on\n",
                     lib_text("0") + lib_text("0")):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    library_flag(text)


if __name__ == "__main__":
    unittest.main()
