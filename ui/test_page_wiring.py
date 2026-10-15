"""Static checks on ui/static/index.html: the page calls the routes the server
has, with the bodies the server reads, and shows what the engine reports.

The page has no JavaScript test runner; these tests read its source. Each one
names the behaviour it pins, so a change to the page that drops it fails here.
"""

import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX = os.path.join(HERE, "static", "index.html")


def page():
    with open(INDEX, encoding="utf-8") as f:
        return f.read()


def function_body(name):
    """The source of `function name(...)` or `async function name(...)` up to
    the next top-level function."""
    text = page()
    m = re.search(r"^(?:async )?function " + re.escape(name) + r"\(.*?(?=^(?:async )?function |\Z)",
                  text, re.S | re.M)
    if not m:
        raise AssertionError("function %s not found in index.html" % name)
    return m.group(0)


class CredentialPanelTest(unittest.TestCase):

    def test_actions_follow_the_method(self):
        body = function_body("credentialAction")
        self.assertIn("m==='credential') return 'reseal'", body)
        self.assertIn("m==='stdin' || m==='env') return 'migrate'", body)

    def test_buttons_post_the_action_to_the_credential_route(self):
        card = function_body("credentialCard")
        self.assertIn("Migrate to an encrypted credential", card)
        self.assertIn("'Re-seal'", card)
        run = function_body("runCredential")
        self.assertIn("'/api/config/'+state.node+'/credential', {action:action}", run)
        # The events land in the config progress pane (done and error included).
        self.assertIn("target:'#cfgLog'", run)

    def test_method_display_names_the_three_methods(self):
        body = function_body("passphraseLabel")
        for m in ("credential", "stdin", "env"):
            self.assertIn("m==='%s'" % m, body)
        self.assertNotIn("TPM", body)
        self.assertNotIn("tpm", body)


if __name__ == "__main__":
    unittest.main()
