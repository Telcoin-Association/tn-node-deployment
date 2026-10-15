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


class FirewallEnableTest(unittest.TestCase):

    def test_the_form_posts_the_sources_and_shows_the_engine_message(self):
        body = function_body("enableFirewall")
        self.assertIn("'/api/firewall/enable'", body)
        self.assertIn("JSON.stringify({ssh_from: src.list})", body)
        # The engine's refusal (r.error) is shown as text, not as markup.
        self.assertIn("show(r.error||'firewall enable failed')", body)
        self.assertIn("errBox.textContent=msg", body)

    def test_the_form_appears_only_while_ufw_is_off_and_management_is_allowed(self):
        body = function_body("loadFirewall")
        self.assertIn("(!f.active && !isReadonly())", body)
        self.assertIn('id="fwSshFrom"', body)
        self.assertNotIn("select option 2", body)

    def test_the_page_rule_matches_the_server_limits(self):
        body = function_body("fwSshSources")
        self.assertIn("items.length > 16", body)
        self.assertIn("mask<8", body)


class HostAuditCardTest(unittest.TestCase):

    def test_the_system_panel_loads_the_audit_read_only(self):
        body = function_body("loadHostAudit")
        self.assertIn("api('/api/system/audit')", body)
        # Text only: every engine line goes through esc().
        self.assertIn("esc(i.text)", body)
        self.assertNotIn("method:'POST'", body)
        self.assertIn("loadHostAudit();", function_body("renderSystem"))


if __name__ == "__main__":
    unittest.main()
