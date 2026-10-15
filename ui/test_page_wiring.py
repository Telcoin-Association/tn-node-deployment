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


class SetupWizardTest(unittest.TestCase):

    def test_mainnet_selection_stays_off_until_the_mainnet_release(self):
        self.assertIn("const SETUP_MAINNET_ENABLED = false;", page())
        body = function_body("stepNetwork")
        self.assertIn("${SETUP_MAINNET_ENABLED", body)
        self.assertIn('<div class="rcard disabled"><div class="rt">Mainnet', body)
        self.assertIn("enabled with the mainnet release", body)

    def test_mainnet_defaults_to_a_signed_release(self):
        body = function_body("setSetupNetwork")
        self.assertIn("s.method = net==='mainnet' ? 'release' : 'source';", body)
        method = function_body("stepMethod")
        for m in ("release", "source", "docker"):
            self.assertIn('data-m="%s"' % m, method)

    def test_payload_carries_the_network_release_tag_log_target_and_tpm_choice(self):
        body = function_body("buildSetupPayload")
        self.assertIn("network: setupNetwork(),", body)
        self.assertIn("build_ref: (s.method==='source' || s.method==='release') ? s.buildRef : ''", body)
        self.assertIn("log_target: setupNetwork()==='mainnet' ? 'journal' : ''", body)
        self.assertIn("allow_no_tpm: noTpmReported() && !!s.allowNoTpm", body)
        self.assertNotIn("network: 'testnet'", body)

    def test_allow_no_tpm_is_offered_only_when_the_engine_reports_no_tpm(self):
        body = function_body("noTpmReported")
        self.assertIn("setupNetwork()==='mainnet'", body)
        self.assertIn("state.preflight?.tpm2===false || state.setup.noTpmRefused", body)
        self.assertIn("${noTpmReported() ?", function_body("stepReview"))
        self.assertIn("/--allow-no-tpm/.test(", function_body("runKeygen"))

    def test_docker_field_takes_a_release_tag_or_a_digest_never_latest(self):
        body = function_body("dockerImageError")
        self.assertIn("latest is refused", body)
        self.assertIn("@sha256:[0-9a-f]{64}$", body)
        self.assertIn("dockerImageError(state.setup.dockerImage)", function_body("stepMethod"))

    def test_defaults_are_asked_for_the_chosen_network(self):
        self.assertIn("'/api/setup/defaults?network='+setupNetwork()", function_body("loadSetupDefaults"))


class UpdatePanelTest(unittest.TestCase):

    def test_done_fields_are_shown(self):
        body = function_body("updateOutcomeHtml")
        self.assertIn("d.downgrade===true", body)
        self.assertIn("d.storage_downgrade===true", body)
        self.assertIn("d.voting===false", body)
        self.assertIn("esc(n)", body)
        run = function_body("startUpdateStream")
        self.assertIn("out.innerHTML = updateOutcomeHtml(d)", run)
        self.assertIn("d.voting===false", run)

    def test_a_moved_tag_is_shown(self):
        body = function_body("fillUpdateStatus")
        self.assertIn("u.tag_moved===true", body)
        self.assertIn("u.tag_unknown===true", body)
        self.assertIn("method==='release'", body)

    def test_refusals_before_the_engine_land_in_the_pane(self):
        run = function_body("startUpdateStream")
        self.assertIn("appendStream('#updLog', {event:'error'", run)
        self.assertIn("onReject})", run)


class RpcExposureConsentTest(unittest.TestCase):

    def test_the_exposure_text_is_shown_before_the_engine_runs(self):
        body = function_body("rpcEnable")
        ask = body.index("api('/api/rpc/exposure?domain='")
        confirm = body.index("if(!confirm(prompt)) return;")
        call = body.index("streamPost('/api/rpc/enable'")
        self.assertLess(ask, confirm)
        self.assertLess(confirm, call)
        self.assertIn("+ ex.summary +", body)
        # No summary, no call.
        self.assertIn("if(!ex || !ex.ok || !ex.summary) return toast(", body)


class StaleTextTest(unittest.TestCase):
    """open-ui.sh opens http://127.0.0.1:8080; no operator-facing text in the UI
    files says otherwise, and the server's start refusal names the token."""

    FILES = ("server.py", "static/index.html", "install-ui.sh", "telcoin-ui-helper.sh",
             "../open-ui.sh")

    def test_no_localhost_8080_text(self):
        for name in self.FILES:
            with self.subTest(file=name):
                with open(os.path.join(HERE, name), encoding="utf-8") as f:
                    self.assertNotIn("localhost:8080", f.read())

    def test_start_refusal_names_the_token(self):
        with open(os.path.join(HERE, "server.py"), encoding="utf-8") as f:
            text = f.read()
        self.assertNotIn("no auth of its own", text)
        self.assertIn("per-install token", text[text.index('if __name__ == "__main__":'):])


if __name__ == "__main__":
    unittest.main()
