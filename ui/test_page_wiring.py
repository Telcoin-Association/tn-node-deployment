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
FIREWALL_SETUP = os.path.join(os.path.dirname(HERE), "firewall-setup.sh")


def page():
    with open(INDEX, encoding="utf-8") as f:
        return f.read()


def engine_function(name):
    """The source of the shell function `name() {` in firewall-setup.sh, up to
    its closing brace at the start of a line."""
    with open(FIREWALL_SETUP, encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}\n", text, re.S | re.M)
    if not m:
        raise AssertionError("function %s not found in firewall-setup.sh" % name)
    return m.group(0)


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
        self.assertIn("JSON.stringify({ssh_from: src.list, p2p_from: p2p.list})", body)
        self.assertIn("fwSources(($('#fwSshFrom')||{}).value, 'SSH')", body)
        self.assertIn("fwSources(($('#fwP2pFrom')||{}).value, 'P2P')", body)
        self.assertIn("peers outside that list cannot reach this node", body)
        # The engine's refusal (r.error) is shown as text, not as markup.
        self.assertIn("show(r.error||'firewall enable failed')", body)
        self.assertIn("errBox.textContent=msg", body)

    def test_the_form_appears_only_while_ufw_is_off_and_management_is_allowed(self):
        body = function_body("loadFirewall")
        self.assertIn("(!f.active && !isReadonly())", body)
        self.assertIn('id="fwSshFrom"', body)
        self.assertIn('id="fwP2pFrom"', body)
        self.assertNotIn("select option 2", body)

    def test_the_page_rule_matches_the_server_limits(self):
        self.assertNotIn("fwSshSources", page())
        body = function_body("fwSources")
        self.assertIn("items.length > 16", body)
        self.assertIn("mask<8", body)
        self.assertIn("'at most 16 '+what+' sources'", body)

    def test_the_card_shows_the_kept_p2p_list_and_the_new_flow_limit(self):
        card = function_body("loadFirewall")
        self.assertIn("esc(fwP2pSourcesText(f))", card)
        self.assertIn("fwNewFlowLimitText(f.p2p_new_flow_limit)", card)
        self.assertIn("esc(limitText)", card)
        kept = function_body("fwP2pSourcesText")
        self.assertIn("'every address'", kept)
        self.assertIn("f.p2p_sources_note", kept)
        limit = function_body("fwNewFlowLimitText")
        self.assertIn("' packets per minute of new, unanswered flows per source after a burst of '", limit)
        self.assertNotIn("new flows per minute", limit)
        self.assertIn('title="Counts the packets of P2P flows this node has not answered yet, per source '
                      '(an IPv4 address or an IPv6 /64); answered flows are not limited."', card)
        self.assertIn("l.persistent===false ? ' (not restored at boot)'", limit)
        text = page()
        for reason, words in (("committee", "the P2P committee allowlist replaces it"),
                              ("p2p-list", "a P2P source list is set"),
                              ("nft-missing", "nftables is not installed"),
                              ("not-applied", "not applied yet; enable the firewall"),
                              ("unreadable", "state could not be read")):
            self.assertIn("'%s': '%s'," % (reason, words), text)

    def test_the_card_shows_the_p2p_committee_allowlist(self):
        card = function_body("loadFirewall")
        self.assertIn("const committeeText = fwCommitteeText(f.p2p_committee);", card)
        self.assertIn('P2P committee allowlist</span><span class="v">${esc(committeeText)}</span>', card)
        self.assertIn('title="Turned on and off on the server with firewall-setup.sh --p2p-committee: '
                      'the P2P ports take only the current committee, the bootstrap floor and the P2P '
                      'source list, refreshed every 5 minutes."', card)
        # the row follows the new-flow limit row and comes before the port rows.
        self.assertLess(card.index("P2P new-flow limit</span>"), card.index("P2P committee allowlist</span>"))
        self.assertLess(card.index("P2P committee allowlist</span>"), card.index("${portRows}"))
        body = function_body("fwCommitteeText")
        self.assertIn("if(c.enabled===false) return 'off';", body)
        self.assertIn("if(r) return FW_COMMITTEE_REASONS[r] || 'unknown: '+r;", body)
        self.assertIn("if(c.enabled!==true) return 'unknown';", body)
        self.assertIn("'on, but its table is not loaded, so P2P is open to every source'", body)
        self.assertIn("'stale'+(why ? ': '+why : '')", body)
        self.assertIn("/^(rpc-method-missing|snapshot-version-)/.test(why)", body)
        self.assertIn("if(c.persistent===false) parts.push('not restored at boot');", body)
        self.assertIn("if(c.timer===false) parts.push('the sync timer is not running');", body)
        kept = function_body("fwP2pSourcesText")
        self.assertIn("const committee = !!(c && typeof c==='object' && c.enabled===true);", kept)
        self.assertIn("if(committee) return 'committee allowlist' + (items.length ? ', plus '+items.join(', ') : '');",
                      kept)
        self.assertIn("if(committee) return 'committee allowlist' + (note ? ' ('+note+')' : '');", kept)

    def test_the_page_words_every_committee_reason_the_engine_sends(self):
        engine = set(re.findall(r'reason="([a-z-]+)"', engine_function("json_fw_committee")))
        self.assertEqual(engine, {"off", "unreadable", "tool-missing", "tool-error"})
        m = re.search(r"^const FW_COMMITTEE_REASONS = \{\n(.*?)^\};", page(), re.S | re.M)
        self.assertIsNotNone(m, "FW_COMMITTEE_REASONS not found in index.html")
        self.assertEqual(set(re.findall(r"^  '([a-z-]+)': '", m.group(1), re.M)), engine)
        self.assertIn("'tool-missing': 'on, but tn-p2p-allow-sync is missing; run firewall-setup.sh "
                      "--p2p-committee sync on the server',", m.group(1))


class StatusPageLinkTest(unittest.TestCase):

    def test_the_link_comes_from_the_server_never_from_the_page(self):
        self.assertNotIn("status.adiri.telcoin.network", page())
        self.assertIn("${statusPageLink(d)}", function_body("renderNetwork"))
        body = function_body("statusPageLink")
        self.assertIn("d.status_page", body)
        # Only an https URL becomes a link; anything else (mainnet, devnet) shows none.
        self.assertIn("if(!/^https:\\/\\/[^\\s\"'<>]+$/.test(url)) return '';", body)
        self.assertIn('href="${esc(url)}"', body)
        self.assertIn('rel="noopener"', body)


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


class PreflightHardwareTest(unittest.TestCase):
    """The preflight step asks for the wizard's network's hardware tiers and
    words them like the documentation: physical cores with vCPU beside them,
    disks in GB or TB, ECC only when the server says so, and the single-core
    advice."""

    SINGLE_CORE = ("Prioritise single-core performance: EVM execution is single-threaded, "
                   "so a high clock speed matters more than extra cores.")

    def test_the_preflight_request_carries_the_wizards_network(self):
        body = function_body("stepPreflight")
        self.assertIn("api('/api/setup/preflight?network='+encodeURIComponent(setupNetwork()))", body)
        self.assertNotIn("api('/api/setup/preflight')", page())

    def test_cores_and_disks_read_like_the_docs(self):
        self.assertIn("`${n} cores (${2*n} vCPU)`", function_body("hwCores"))
        disk = function_body("hwDiskLabel")
        # Whole thousands of GB read as TB, like the shell's _tn_hw_disk_label.
        self.assertIn("(gb>=1000 && gb%1000===0) ? `${gb/1000} TB` : `${gb} GB`", disk)

    def test_the_tier_row_uses_the_helpers(self):
        body = function_body("hwTierRows")
        self.assertIn("${t.label}: ${verdict} (${hwCores(t.min_cpu)} / ${t.min_ram_gb ?? '?'} GB RAM / "
                      "${hwDiskLabel(t.min_disk_gb)} disk)", body)
        self.assertNotIn("${t.min_cpu} cores / ${t.min_ram_gb} GB RAM / ${t.min_disk_gb} GB disk", page())
        # The rows reach innerHTML through the escaped row template.
        self.assertIn("${esc(desc)}", function_body("stepPreflight"))

    def test_the_info_row_names_the_tier_set_only_when_the_server_does(self):
        body = function_body("hwInfoRow")
        self.assertIn("if(hw.network) parts.push(`Compared with the ${hw.network} hardware tiers.`);", body)
        # hw.network is server text: the whole row is escaped.
        self.assertIn("${esc(parts.join(' '))}", body)

    def test_the_recommendation_uses_the_helpers_and_ecc_only_when_sent(self):
        body = function_body("hwInfoRow")
        self.assertIn("Recommended to validate: ${hwCores(r.cpu)} / ${r.ram_gb ?? '?'} "
                      "${r.ecc ? 'GB ECC RAM' : 'GB RAM'} / ${hwDiskLabel(r.disk_gb)} disk.", body)
        self.assertEqual(page().count("GB ECC RAM"), 1)
        self.assertNotIn("${r.cpu} cores / ${r.ram_gb} GB RAM / ${r.disk_gb} GB disk", page())

    def test_the_detected_disk_is_decimal_gb_like_the_tiers(self):
        body = function_body("hwInfoRow")
        self.assertIn("const diskGb = kb => kb==null ? '?' : String(Math.round(kb*1024/1e9));", body)
        self.assertIn("${diskGb(hw.disk?.total_kb)} GB disk", body)
        self.assertNotIn("${gb(hw.disk?.total_kb)}", body)
        # RAM stays binary GiB, as the shell prints it.
        self.assertIn("const gb = kb => kb==null ? '?' : String(Math.round(kb/1048576));", body)
        self.assertIn("${gb(hw.ram_kb)} GB RAM", body)

    def test_missing_ram_figures_read_as_unknown(self):
        # A partial object (a null min_ram_gb, a validator_recommended of {})
        # shows "?" like the cores and disk helpers, never undefined or null.
        self.assertIn("${t.min_ram_gb ?? '?'} GB RAM", function_body("hwTierRows"))
        self.assertNotIn("${t.min_ram_gb}", function_body("hwTierRows"))
        body = function_body("hwInfoRow")
        self.assertIn("${r.ram_gb ?? '?'} ${r.ecc", body)
        self.assertNotIn("${r.ram_gb}", body)

    LOGICAL_NOTE = ("Physical cores could not be counted, so the tiers are compared with logical "
                    "CPUs; with hyperthreading that is up to twice the physical cores.")

    def test_a_logical_cpu_count_is_worded_as_such_only_when_the_server_says_so(self):
        self.assertEqual(page().count(self.LOGICAL_NOTE), 1)
        body = function_body("hwInfoRow")
        self.assertIn("const logical = hw.cpu_kind === 'logical'", body)
        self.assertIn("const cpu = logical ? `${nLogical ?? '?'} logical CPU${Number(nLogical)===1 ? '' : 's'}`", body)
        # Absent, null or "physical": the cores wording as before.
        self.assertIn(": phys!=null ? `${phys} cores${threads!=null ? ` (${threads} threads)` : ''}` "
                      ": `${hw.cpu??'?'} cores`;", body)
        self.assertIn("if(logical) parts.push('%s');" % self.LOGICAL_NOTE, body)
        # The note follows the detected sentence, before the tier set and the advice.
        self.assertLess(body.index("parts.push(`Detected "), body.index(self.LOGICAL_NOTE))
        self.assertLess(body.index(self.LOGICAL_NOTE), body.index("Compared with the "))
        self.assertEqual(body.count("logical ?"), 1)

    def test_the_single_core_advice_follows_the_rest_of_the_row(self):
        self.assertIn(self.SINGLE_CORE, page())
        body = function_body("hwInfoRow")
        self.assertIn("parts.push('%s');" % self.SINGLE_CORE, body)
        # Only a row with something else in it gets the advice.
        self.assertLess(body.index("if(!parts.length) return '';"), body.index(self.SINGLE_CORE))


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


class PortMismatchTest(unittest.TestCase):

    def test_a_listener_port_mismatch_is_confirmed_and_sent(self):
        body = function_body("saveConfigField")
        self.assertIn("udpPort(ext)", body)
        self.assertIn("NAT or port forward", body)
        self.assertIn("if(!confirm(", body)
        self.assertIn("body.allow_port_mismatch = true", body)

    def test_the_external_addresses_are_kept_for_the_check(self):
        self.assertIn("state.cfgExternal = {primary_listener: d.external_primary||'', "
                      "worker_listener: d.external_worker||''}", page())


if __name__ == "__main__":
    unittest.main()


class NodeRestartTest(unittest.TestCase):
    """Stop, restart, the tracing toggle and the advertised name are confirmed,
    then stream the helper's progress; a committee refusal offers the override
    once."""

    def test_stop_and_restart_are_confirmed_and_streamed(self):
        body = function_body("serviceAction")
        self.assertIn("action!=='start' && !confirm(restartConfirmText(", body)
        self.assertIn("nodeRestartStream('/api/service/'+state.node+'/'+action, {}", body)
        # Start stays a plain call.
        self.assertIn("if(action==='start'){", body)
        self.assertIn("api('/api/service/'+state.node+'/'+action, {method:'POST'})", body)

    def test_the_confirmation_says_what_happens_first(self):
        body = function_body("restartConfirmText")
        self.assertIn("checks that the committee keeps its quorum", body)
        self.assertIn("waits for the boundary (up to 30 minutes)", body)

    def test_the_override_is_offered_only_after_a_committee_refusal(self):
        body = function_body("nodeRestartStream")
        self.assertIn("!d.ok && d.quorum === true && confirm(", body)
        self.assertIn("Object.assign({}, body, {allow_quorum_risk:true})", body)
        self.assertEqual(body.count("allow_quorum_risk"), 1)
        self.assertIn("target:'#restartLog'", body)

    def test_tracing_and_the_name_restart_through_the_stream(self):
        tracing = function_body("setTracing")
        self.assertIn("confirm(restartConfirmText(", tracing)
        self.assertIn("nodeRestartStream('/api/tracing/'+(enable?'enable':'disable')+'/'+type, {}", tracing)
        name = function_body("saveAdvertisedName")
        self.assertIn("nodeRestartStream('/api/config/'+t+'/hostname', {name}", name)
        self.assertIn("confirm(restartConfirmText(msg))", name)
