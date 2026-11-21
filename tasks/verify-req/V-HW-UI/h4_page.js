// V-HW-UI H4: run the page's preflight code (extracted by h4_extract.py) in node
// against real server replies, and compare its text with the shell's.
//
//   node h4_page.js NEW_PAGE_JS OLD_PAGE_JS RUN_DIR
//
// RUN_DIR holds server-json/ and oldserver-json/ (h1_server.py) and sh/
// (h1_shell.sh). For every host and network the page's stepPreflight runs with
// state.setup.network set as the wizard sets it ('adiri' for testnet), its api()
// answering from the JSON file named by the request's ?network= (none when
// absent). Exit 1 on any failed check.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const [NEW_JS, OLD_JS, RUN] = process.argv.slice(2);
const SINGLE = 'Prioritise single-core performance: EVM execution is single-threaded, so a high clock speed matters more than extra cores.';
const fails = [];
let checks = 0;
function check(name, ok, detail) {
  checks++;
  if (!ok) fails.push(name + (detail ? ' :: ' + detail : ''));
}

function page(file) {
  const els = {};
  const ctx = {
    state: { setup: { network: 'adiri' }, preflight: null },
    module: { exports: {} },
    requested: [],
    reply: () => ({}),
    toast() {}, goStep() {},
    $: sel => els[sel] || (els[sel] = { sel, innerHTML: '', disabled: false, title: '', addEventListener() {} }),
  };
  ctx.api = async url => { ctx.requested.push(url); return ctx.reply(url); };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(file, 'utf8'), ctx);
  return { ctx, els, fn: ctx.module.exports };
}

function decode(s) {
  return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');
}
function rowsOf(html) {
  const out = [];
  const re = /<div class="ct">(.*?)<\/div><div class="cd">(.*?)<\/div>/g;
  let m;
  while ((m = re.exec(html))) out.push([decode(m[1]), decode(m[2])]);
  return out;
}

// Render step 1 for `net` ('testnet' | 'mainnet') with replies from jsonDir.
async function render(p, net, jsonDir, host) {
  p.ctx.state.setup.network = net === 'mainnet' ? 'mainnet' : 'adiri';
  p.ctx.requested.length = 0;
  p.ctx.reply = url => {
    const q = new URL(url, 'http://x').searchParams.get('network');
    return JSON.parse(fs.readFileSync(path.join(jsonDir, `${host}.${q == null ? 'none' : q}.json`), 'utf8'));
  };
  const body = { innerHTML: '' };
  await p.fn.stepPreflight(body);
  const html = p.els['#pfList'].innerHTML;
  return { html, rows: rowsOf(html), url: p.ctx.requested[0] };
}

const cores = n => `${n} cores (${2 * n} vCPU)`;
const disk = gb => (gb >= 1000 && gb % 1000 === 0) ? `${gb / 1000} TB` : `${gb} GB`;
function expectTier(t) {
  const v = t.ok ? 'meets minimum' : t.gaps.length ? 'below minimum — ' + t.gaps.join(', ') : 'could not be measured';
  return `${t.label}: ${v} (${cores(t.min_cpu)} / ${t.min_ram_gb} GB RAM / ${disk(t.min_disk_gb)} disk)`;
}
const BAD_WORDS = /\b(undefined|NaN|null)\b/;

// The shell's role lines for host/net: {node|rpc|validator: {verdict, spec, need}}.
function shellRoles(host, net) {
  const txt = fs.readFileSync(path.join(RUN, 'sh', `${host}.${net}.txt`), 'utf8');
  const labels = { 'Full node (follower)': 'node', 'Public RPC node': 'rpc', 'Validator (minimum)': 'validator' };
  const r = {};
  for (const line of txt.split('\n')) {
    for (const [label, role] of Object.entries(labels)) {
      const i = line.indexOf(label + ': ');
      if (i < 0) continue;
      const rest = line.slice(i + label.length + 2);
      r[role] = r[role] || {};
      let m;
      if ((m = rest.match(/^below minimum — needs ≥ (.*) \(have (.*)\)$/))) { r[role].verdict = 'below'; r[role].need = m[1].split(', '); }
      else if ((m = rest.match(/^meets minimum \((.*)\)$/))) { r[role].verdict = r[role].verdict || 'pass'; r[role].spec = m[1]; }
      else if ((m = rest.match(/^could not check .*; minimum is (.*)$/))) { r[role].verdict = r[role].verdict || 'unknown'; r[role].spec = m[1]; }
    }
  }
  const rec = (txt.match(/Validator \(recommended\): (.*?) NVMe — /) || [])[1];
  const det = (txt.match(/Detected: (.*)/) || [])[1];
  return { roles: r, rec, det, logicalNote: /compared with logical CPUs/.test(txt) };
}

async function main() {
  const NEW = page(NEW_JS), OLD = page(OLD_JS);
  const hosts = [...new Set(fs.readdirSync(path.join(RUN, 'server-json')).map(f => f.split('.')[0]))].sort();
  const huge = /^huge/;
  const notes = [];
  for (const host of hosts) {
    for (const net of ['testnet', 'mainnet']) {
      const tag = `${host}/${net}`;
      // ---- new page, new server ----
      const r = await render(NEW, net, path.join(RUN, 'server-json'), host);
      const reply = JSON.parse(fs.readFileSync(path.join(RUN, 'server-json', `${host}.${net}.json`), 'utf8'));
      const hw = reply.hardware;
      check(`${tag} request line`, r.url === `/api/setup/preflight?network=${net}`, r.url);
      const text = r.rows.map(x => x[1]).join('\n');
      check(`${tag} no undefined/NaN/null`, !BAD_WORDS.test(text), text.match(BAD_WORDS)?.[0]);
      const tierRows = r.rows.filter(x => x[0] === 'Hardware' && !x[1].startsWith('Detected') && !x[1].startsWith('Compared') && !x[1].startsWith('Recommended'));
      check(`${tag} three tier rows`, tierRows.length === 3, String(tierRows.length));
      hw.tiers.forEach((t, i) => check(`${tag} tier row ${t.role}`, tierRows[i] && tierRows[i][1] === expectTier(t), tierRows[i] && tierRows[i][1]));
      const info = r.rows.find(x => x[0] === 'Hardware' && /Recommended to validate/.test(x[1]));
      check(`${tag} info row present`, !!info);
      if (info) {
        const i = info[1];
        check(`${tag} info: compared-with`, i.includes(`Compared with the ${net} hardware tiers.`), i);
        const rv = hw.validator_recommended;
        const recTxt = `Recommended to validate: ${cores(rv.cpu)} / ${rv.ram_gb} ${net === 'mainnet' ? 'GB ECC RAM' : 'GB RAM'} / ${disk(rv.disk_gb)} disk.`;
        check(`${tag} info: recommended`, i.includes(recTxt), i);
        check(`${tag} info: single-core sentence last, once`, i.endsWith(' ' + SINGLE) && i.split(SINGLE).length === 2, i);
        check(`${tag} ECC only on mainnet`, (text.includes('ECC')) === (net === 'mainnet'), text);
        // ---- wording parity with the shell ----
        const sh = shellRoles(host, net);
        hw.tiers.forEach((t, k) => {
          const s = sh.roles[t.role] || {};
          const pageV = t.ok ? 'pass' : t.gaps.length ? 'below' : 'unknown';
          check(`${tag} ${t.role} verdict page=${pageV} shell=${s.verdict}`, pageV === s.verdict);
          const fm = tierRows[k] ? tierRows[k][1].match(/: (?:meets minimum|below minimum — [^(]*|could not be measured) \((.*)\)$/) : null;
          const figs = (fm ? fm[1] : '').split(' / ');
          if (s.spec) {
            const pageSpec = figs.map(f => f.replace(/ RAM$/, '').replace(/ disk$/, '')).join(' / ');
            check(`${tag} ${t.role} tier figures equal`, pageSpec === s.spec, `page=${pageSpec} shell=${s.spec}`);
          }
          if (s.need) for (const n of s.need) check(`${tag} ${t.role} shell need "${n}" in page figures`, figs.includes(n), figs.join(' / '));
        });
        const recFigs = recTxt.replace('Recommended to validate: ', '').replace(/\.$/, '').replace(' RAM /', ' /').replace(/ disk$/, '');
        check(`${tag} recommended figures equal`, recFigs === sh.rec, `page=${recFigs} shell=${sh.rec}`);
        const det = i.match(/^Detected (.*?) \/ (\S+) GB RAM \/ (\S+) GB disk/);
        const sdet = sh.det.match(/^(.*?), (?:(\S+) GB RAM|unknown RAM), (?:(\S+) GB disk|unknown disk)/);
        if (det && sdet && !huge.test(host)) {
          check(`${tag} detected RAM GB equal`, det[2] === (sdet[2] || '?'), `page=${det[2]} shell=${sdet[2]}`);
          check(`${tag} detected disk GB equal`, det[3] === (sdet[3] || '?'), `page=${det[3]} shell=${sdet[3]}`);
          if (sh.logicalNote && net === 'testnet') notes.push(`${host}: shell "${sdet[1]}" + logical-CPU note; page "Detected ${det[1]}" (no note)`);
        }
        if (net === 'testnet' && ['tnval', 'mixed', 'memzero', 'cpunone', 'allnone', 'log8', 'hugemem63', 'hugedisk53'].includes(host)) {
          notes.push(`${tag} page rows:\n    ` + r.rows.filter(x => x[0] === 'Hardware').map(x => x[1]).join('\n    '));
        }
        if (net === 'mainnet' && host === 'tnval') {
          notes.push(`${tag} page rows:\n    ` + r.rows.filter(x => x[0] === 'Hardware').map(x => x[1]).join('\n    '));
          notes.push(`${tag} shell lines:\n    ` + fs.readFileSync(path.join(RUN, 'sh', `${host}.${net}.txt`), 'utf8').split('\n').filter(l => /below|meets|could not|recommended|Detected|Prioritise/.test(l)).join('\n    '));
        }
      }
      // ---- new page, old server (no network, no ecc) ----
      const ro = await render(NEW, net, path.join(RUN, 'oldserver-json'), host);
      const to = ro.rows.map(x => x[1]).join('\n');
      check(`${tag} new page/old server: no undefined/NaN/null`, !BAD_WORDS.test(to), to);
      check(`${tag} new page/old server: no compared-with`, !to.includes('Compared with'), to);
      check(`${tag} new page/old server: no ECC`, !to.includes('ECC'), to);
      check(`${tag} new page/old server: single-core`, to.includes(SINGLE));
      check(`${tag} new page/old server: 3 tier rows`, ro.rows.filter(x => / minimum|could not be measured/.test(x[1]) && x[0] === 'Hardware').length === 3, to);
      if (host === 'tnval' && net === 'testnet') notes.push(`new page / old server, ${tag}:\n    ` + ro.rows.filter(x => x[0] === 'Hardware').map(x => x[1]).join('\n    '));
      // ---- old page, new server ----
      const rn = await render(OLD, net, path.join(RUN, 'server-json'), host);
      const tn = rn.rows.map(x => x[1]).join('\n');
      check(`${tag} old page/new server: request without network`, rn.url === '/api/setup/preflight', rn.url);
      check(`${tag} old page/new server: no undefined/NaN/null`, !BAD_WORDS.test(tn), tn);
      check(`${tag} old page/new server: 3 tier rows`, rn.rows.filter(x => / minimum|could not be measured/.test(x[1]) && x[0] === 'Hardware').length === 3, tn);
      if (host === 'tnval' && net === 'testnet') notes.push(`old page / new server, ${tag} (request ${rn.url}):\n    ` + rn.rows.filter(x => x[0] === 'Hardware').map(x => x[1]).join('\n    '));
    }
  }

  // ---- hostile and partial replies, new page ----
  const base = JSON.parse(fs.readFileSync(path.join(RUN, 'server-json', 'tnval.testnet.json'), 'utf8'));
  const hostile = JSON.parse(JSON.stringify(base));
  hostile.hardware.network = '<img src=x onerror=alert(1)>';
  hostile.hardware.tiers[0].label = '<script>alert(2)</script>';
  hostile.hardware.disk.path = '"><svg onload=alert(3)>';
  hostile.hardware.validator_recommended.disk_gb = '<b>9</b>';
  hostile.hardware.tiers[1].gaps = ['<i>x</i>'];
  hostile.hardware.tiers[1].ok = false;
  const partials = {
    hostile,
    'no hardware': Object.assign({}, base, { hardware: undefined }),
    'hardware {}': Object.assign({}, base, { hardware: {} }),
    'fetch error': { error: 'TypeError: Failed to fetch' },
    'validator_recommended {}': (() => { const x = JSON.parse(JSON.stringify(base)); x.hardware.validator_recommended = {}; return x; })(),
    'tier minima null': (() => { const x = JSON.parse(JSON.stringify(base)); x.hardware.tiers.forEach(t => { t.min_cpu = null; t.min_ram_gb = null; t.min_disk_gb = null; }); return x; })(),
  };
  for (const [name, rep] of Object.entries(partials)) {
    NEW.ctx.state.setup.network = 'adiri';
    NEW.ctx.reply = () => rep;
    await NEW.fn.stepPreflight({ innerHTML: '' });
    const html = NEW.els['#pfList'].innerHTML;
    const txt = rowsOf(html).map(x => x[1]).join('\n');
    if (name === 'hostile') {
      check('hostile: no raw tag in html', !/<(img|script|svg|b|i)[\s>]/.test(html.replace(/<div[^>]*>|<\/div>|<span[^>]*>|<\/span>/g, '')), html);
      check('hostile: network shown escaped', html.includes('&lt;img src=x onerror=alert(1)&gt;'), html);
    } else {
      check(`partial "${name}": no undefined/NaN/null`, !BAD_WORDS.test(txt), txt);
    }
    notes.push(`partial "${name}": ` + rowsOf(html).filter(x => x[0] === 'Hardware').map(x => x[1]).join(' || '));
  }
  console.log(notes.join('\n'));
  console.log(`\nchecks: ${checks}, failed: ${fails.length}`);
  const uniq = {};
  for (const f of fails) { const k = f.replace(/^\S+\/(testnet|mainnet) /, '').replace(/ :: .*$/, ''); (uniq[k] = uniq[k] || []).push(f); }
  for (const [k, v] of Object.entries(uniq)) console.log(`FAIL x${v.length} ${k}\n    e.g. ${v[0].slice(0, 400)}`);
  process.exit(fails.length ? 1 : 0);
}
main().catch(e => { console.error(e); process.exit(2); });
