// tasks/verify-fup/V5/render_v5.js -- run the page's own card and link helpers
// (extracted from ui/static/index.html) in node and check their text per state.
//   docker run --rm -v "$PWD:/w" -w /w node:22-slim node tasks/verify-fup/V5/render_v5.js [SRC]
'use strict';
const fs = require('fs');
const path = require('path');
const src = process.argv[2] || path.join(__dirname, '..', '..', '..');
const page = fs.readFileSync(path.join(src, 'ui', 'static', 'index.html'), 'utf8');
function grab(start) {
  const i = page.indexOf(start);
  if (i < 0) throw new Error('not found: ' + start);
  let j = page.indexOf('{', i), depth = 0;
  for (; j < page.length; j++) {
    if (page[j] === '{') depth++;
    else if (page[j] === '}') { depth--; if (depth === 0) break; }
  }
  let end = j + 1;
  if (page[end] === ';') end++;
  return page.slice(i, end);
}
const escLine = page.split('\n').find(l => l.startsWith('const esc = '));
const code = [escLine, grab('function statusPageLink('), grab('function fwP2pSourcesText('),
  grab('const FW_LIMIT_REASONS'), grab('function fwNewFlowLimitText('), grab('function fwSources(')].join('\n');
const api = new Function(code + '\nreturn {esc, statusPageLink, fwP2pSourcesText, fwNewFlowLimitText, fwSources};')();
let checks = 0, fails = 0;
function check(name, want, got) {
  checks++;
  if (want === got) { console.log('ok    ' + name); return; }
  fails++; console.log('FAIL  ' + name + '\n      expected: ' + JSON.stringify(want) + '\n      actual:   ' + JSON.stringify(got));
}
const L = (o) => api.fwNewFlowLimitText(o);
check('J1 active + persistent', 'active, 20 new flows per minute per source after a burst of 40',
  L({active: true, rate: 20, burst: 40, reason: null, persistent: true}));
check('J2 active + not persistent', 'active, 20 new flows per minute per source after a burst of 40 (not restored at boot)',
  L({active: true, rate: 20, burst: 40, reason: null, persistent: false}));
check('J3 active, persistent missing (older engine)', 'active, 5 new flows per minute per source after a burst of 10',
  L({active: true, rate: 5, burst: 10, reason: null}));
check('J4 p2p-list', 'inactive: a P2P source list is set', L({active: false, rate: null, burst: null, reason: 'p2p-list', persistent: false}));
check('J5 nft-missing', 'inactive: nftables is not installed', L({active: false, reason: 'nft-missing'}));
check('J6 not-applied', 'inactive: not applied yet; enable the firewall', L({active: false, reason: 'not-applied'}));
check('J7 unreadable', 'inactive: state could not be read', L({active: false, reason: 'unreadable'}));
check('J8 unknown reason shown as is', 'inactive: something-new', L({active: false, reason: 'something-new'}));
check('J9 no field: no row', '', L(undefined));
check('J10 bad numbers shown as ?', 'active, ? new flows per minute per source after a burst of ?', L({active: true, rate: '20', burst: -1}));
check('J10b not-applied with persistent:true (boot copy enabled, table gone)', 'inactive: not applied yet; enable the firewall',
  L({active: false, reason: 'not-applied', persistent: true}));
check('J11 sources list', '10.0.0.0/8, 2001:db8::/32', api.fwP2pSourcesText({p2p_sources: ['10.0.0.0/8', '2001:db8::/32']}));
check('J12 sources empty', 'every address', api.fwP2pSourcesText({p2p_sources: []}));
check('J13 sources null', '—', api.fwP2pSourcesText({p2p_sources: null}));
check('J14 sources missing (older server)', '—', api.fwP2pSourcesText({}));
check('J15 testnet link', '<a href="https://status.adiri.telcoin.network/" target="_blank" rel="noopener" style="margin-left:auto;font-size:12px">status page ↗</a>',
  api.statusPageLink({status_page: 'https://status.adiri.telcoin.network/'}));
check('J16 mainnet: no link', '', api.statusPageLink({status_page: ''}));
check('J17 missing field: no link', '', api.statusPageLink({}));
check('J18 http refused', '', api.statusPageLink({status_page: 'http://status.example/'}));
check('J19 javascript: refused', '', api.statusPageLink({status_page: 'javascript:alert(1)'}));
check('J20 quote refused', '', api.statusPageLink({status_page: 'https://x/"onmouseover="a'}));
check('J21 fwSources P2P ok', '198.51.100.0/24,2001:db8::/48', api.fwSources('198.51.100.0/24 2001:db8::/48', 'P2P').list);
check('J22 fwSources P2P bad names P2P', 'P2P sources: not an address or a CIDR of /8 or narrower: 10.0.0.0/4', api.fwSources('10.0.0.0/4', 'P2P').error);
check('J23 fwSources 17', 'at most 16 P2P sources', api.fwSources(Array.from({length: 17}, (_, i) => '10.0.' + i + '.0/24').join(','), 'P2P').error);
check('J24 fwSources leading slash', 'P2P sources: not an address or a CIDR of /8 or narrower: /etc/passwd', api.fwSources('/etc/passwd', 'P2P').error);
check('J25 fwSources empty', '', api.fwSources('', 'P2P').list);
console.log('\n' + checks + ' checks, ' + fails + ' failures');
process.exit(fails ? 1 : 0);
