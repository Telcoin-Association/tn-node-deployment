// V-HW-UI H5: the wizard's network as the preflight request carries it.
//
//   node h5_flow.js FLOW_JS
//
// FLOW_JS is h4_extract.py's output with renderSetup goStep setSetupNetwork
// stepNetwork loadSetupDefaults const:STEP_LABELS const:SETUP_MAINNET_ENABLED.
// Runs the wizard as shipped (mainnet card disabled) and once more with
// SETUP_MAINNET_ENABLED switched to true in a copy, and prints every
// /api/setup/preflight request with the step that made it. Exit 1 when a
// request carries a network other than the wizard's.
'use strict';
const fs = require('fs');
const vm = require('vm');

const src = fs.readFileSync(process.argv[2], 'utf8');
let bad = 0;
const settle = async () => { for (let i = 0; i < 5; i++) await new Promise(r => setImmediate(r)); };

function make(code) {
  const els = {};
  const el = sel => els[sel] || (els[sel] = {
    sel, innerHTML: '', disabled: false, title: '', handlers: {},
    addEventListener(t, f) { this.handlers[t] = f; },
    querySelectorAll(q) {
      if (q !== '[data-net]') return [];
      return [...this.innerHTML.matchAll(/data-net="([^"]*)"/g)].map(m => ({
        dataset: { net: m[1] }, addEventListener(t, f) { this.click = f; },
      })).map(c => { this.cards = (this.cards || []).concat([c]); return c; });
    },
  });
  const ctx = {
    state: { setup: { network: 'adiri', method: 'source', defaultsLoaded: false }, setupStep: 1, nodes: {}, node: 'node1', view: 'setup', preflight: null },
    module: { exports: {} }, log: [],
    $: el, toast() {}, stepMethod() {}, stepConfigure() {}, stepReview() {},
  };
  ctx.api = async url => {
    ctx.log.push(`step ${ctx.state.setupStep} network=${ctx.state.setup.network} -> ${url}`);
    if (url.startsWith('/api/setup/preflight')) {
      const q = new URL(url, 'http://x').searchParams.get('network');
      return { systemd: { ok: true, version: 255, required: 247 }, internet: { ok: true }, disk: { ok: true, percent: 10 },
        hardware: { network: q === 'mainnet' ? 'mainnet' : 'testnet', cpu: 4, ram_kb: 16365288, disk: { path: '/', total_kb: 360000000 }, tiers: [],
          validator_recommended: { cpu: 4, ram_gb: 16, disk_gb: 500, ecc: false } } };
    }
    return {};
  };
  vm.createContext(ctx);
  vm.runInContext(code, ctx);
  return { ctx, els, fn: ctx.module.exports };
}

async function flow(label, code) {
  const w = make(code);
  const { ctx, els, fn } = w;
  const say = s => console.log(`[${label}] ${s}`);
  fn.renderSetup(); await settle();
  say('open the wizard (step 1, before the Network step)');
  fn.goStep(2); await settle();
  const cards = els['#stepBody'].cards || [];
  say(`step 2 cards with data-net: ${cards.map(c => c.dataset.net).join(', ') || 'none'}; mainnet card html: ` +
      ((els['#stepBody'].innerHTML.match(/<div class="rcard[^"]*"[^>]*>\s*<div class="rt">Mainnet.*?<\/div>/s) || [''])[0].replace(/\s+/g, ' ')));
  const testnet = cards.find(c => c.dataset.net === 'adiri');
  if (testnet) { testnet.click(); await settle(); say(`clicked the testnet card: state.setup.network=${ctx.state.setup.network}`); }
  fn.goStep(1); await settle();
  say('back to step 1');
  const main = (els['#stepBody'].cards || []).find(c => c.dataset.net === 'mainnet');
  fn.goStep(2); await settle();
  const main2 = (els['#stepBody'].cards || []).reverse().find(c => c.dataset.net === 'mainnet');
  if (main2 || main) {
    (main2 || main).click(); await settle();
    say(`clicked the mainnet card: state.setup.network=${ctx.state.setup.network}, step ${ctx.state.setupStep}`);
    fn.goStep(1); await settle();
    say('back to step 1 after mainnet');
  }
  for (const l of ctx.log) {
    console.log(`[${label}]   ${l}`);
    const m = l.match(/network=(\S+) -> \/api\/setup\/preflight\?network=(\S+)$/);
    if (l.includes('/api/setup/preflight') && (!m || (m[1] === 'mainnet' ? 'mainnet' : 'testnet') !== m[2])) { bad++; console.log('    ^ MISMATCH'); }
  }
}

(async () => {
  await flow('shipped', src);
  const enabled = src.replace('const SETUP_MAINNET_ENABLED = false;', 'const SETUP_MAINNET_ENABLED = true;');
  if (enabled === src) { console.log('could not switch SETUP_MAINNET_ENABLED'); process.exit(2); }
  await flow('mainnet enabled (copy)', enabled);
  console.log(`mismatched preflight requests: ${bad}`);
  process.exit(bad ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
