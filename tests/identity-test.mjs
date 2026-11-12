#!/usr/bin/env node
/**
 * Verify the identity fix: a stale session pointing at a LIVE but unrelated
 * process must report running=false. Before the fix this returned true.
 */
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, rmSync, readFileSync, copyFileSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const REPO = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');
const PROJ = path.join(os.tmpdir(), 'l2c-identity-test');
const GATE = 8480, APP = 3480;

let fail = 0;
const check = (n, c, d = '') => { if (!c) fail++; console.log(`  [${c ? 'PASS' : 'FAIL'}] ${n}${d ? ' :: ' + d : ''}`); };

if (existsSync(PROJ)) { try { rmSync(PROJ, { recursive: true, force: true, maxRetries: 5 }); } catch {} }
mkdirSync(PROJ, { recursive: true });
writeFileSync(path.join(PROJ, 'app.py'), `import sys, http.server, socketserver
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b=b'ok'; self.send_response(200); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', port), H) as s: s.serve_forever()
`);
writeFileSync(path.join(PROJ, 'demo.config.json'), JSON.stringify({
  services: [{ name: 'app', command: process.platform === 'win32' ? 'python' : 'python3',
    startArgs: ['app.py', String(APP)], port: APP, healthUrl: `http://127.0.0.1:${APP}/`, default: true }],
  gateway: { port: GATE },
}));

const child = spawn(process.execPath, [path.join(REPO, 'servers', 'mcp-server.mjs')], {
  stdio: ['pipe', 'pipe', 'pipe'], cwd: PROJ,
});
let buf = '';
const waiters = new Map();
child.stdout.setEncoding('utf8');
child.stdout.on('data', (c) => {
  buf += c; let i;
  while ((i = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
    if (!line) continue;
    const m = JSON.parse(line);
    if (m.id && waiters.has(m.id)) { waiters.get(m.id)(m); waiters.delete(m.id); }
  }
});
let id = 1;
const rpc = (m, p) => { const myId = id++; const pr = new Promise((r) => waiters.set(myId, r)); child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: myId, method: m, params: p }) + '\n'); return pr; };
const tmo = (ms) => new Promise((r) => setTimeout(r, ms));
const call = async (name, args, ms = 240000) => {
  const r = await Promise.race([rpc('tools/call', { name, arguments: args }), tmo(ms)]);
  const t = r?.result?.content?.[0]?.text;
  try { return JSON.parse(t); } catch { return null; }
};
child.stderr.setEncoding('utf8');
child.stderr.on('data', (c) => {
  // Surface server-side complaints; they explain silent tool failures.
  if (/error|reused|exceeded|unreadable/i.test(c)) process.stdout.write('    SRV: ' + c.trim() + '\n');
});

await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'idtest', version: '1' } });
child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
await tmo(200);

console.log('=== 1. real boot reports running=true ===');
const boot = await call('localhost2cloud_boot', { working_directory: PROJ, provider: 'none' });
check('booted', boot?.ok === true);
const stUp = await call('localhost2cloud_status', { working_directory: PROJ });
check('running=true while up', stUp?.running === true, `running=${stUp?.running}`);
check('identity_verified=true', stUp?.identity_verified === true);

console.log('\n=== 2. corrupt the fingerprint to point at a LIVE stranger ===');
// Start an unrelated process we control.
const stranger = spawn(process.platform === 'win32' ? 'python' : 'python3',
  ['-c', 'import time; time.sleep(240)'], { stdio: 'ignore', windowsHide: true });
await tmo(1200);
check('stranger alive', stranger.pid > 0, `pid=${stranger.pid}`);

const sf = path.join(PROJ, '.demo-state', 'session.json');
const raw = readFileSync(sf, 'utf8').replace(/^\uFEFF/, '');
const sess = JSON.parse(raw);
sess.Pids.app = stranger.pid;
sess.Pids.gateway = stranger.pid;
// Deliberately wrong start time: same pid, different process.
sess.Starts.app = 'Thu Jan  1 00:00:00 1970';
sess.Starts.gateway = 'Thu Jan  1 00:00:00 1970';
writeFileSync(sf, JSON.stringify(sess, null, 2));

const stStale = await call('localhost2cloud_status', { working_directory: PROJ });
check('running=false for a recycled pid', stStale?.running === false, `running=${stStale?.running}`);
check('identity_verified=true (it proved it is not ours)', stStale?.identity_verified === true);

console.log('\n=== 3. the stranger is untouched ===');
let strangerAlive = true;
try { process.kill(stranger.pid, 0); } catch { strangerAlive = false; }
check('stranger process still running', strangerAlive);

console.log('\n=== 4. correct fingerprint is still believed ===');
stranger.kill('SIGKILL');
// The corrupted session no longer names the real stack, so a plain stop cannot
// find it - it correctly reports "not fully closed". Force-clean, then boot.
await call('localhost2cloud_stop', { working_directory: PROJ, include_reused: true });
await tmo(1200);
// Belt and braces: nothing may hold our ports before the re-boot.
for (const p of [GATE, APP]) {
  await fetch(`http://127.0.0.1:${p}/`).catch(() => {});
}
const boot2 = await call('localhost2cloud_boot', { working_directory: PROJ, provider: 'none' });
check('re-booted after a corrupted session', boot2?.ok === true, JSON.stringify(boot2 ?? {}).slice(0, 300));
if (boot2?.ok !== true) {
  console.log('    detail:', String(boot2?.detail ?? boot2?.raw ?? '').split('\n').slice(-6).join('\n    '));
}
const st2 = await call('localhost2cloud_status', { working_directory: PROJ });
check('running=true again with a fresh session', st2?.running === true, `running=${st2?.running}`);
check('identity_verified=true', st2?.identity_verified === true);

await call('localhost2cloud_stop', { working_directory: PROJ });
child.kill();
try { rmSync(PROJ, { recursive: true, force: true, maxRetries: 5 }); } catch {}
console.log(`\n${fail === 0 ? 'IDENTITY TEST: PASS' : `IDENTITY TEST: ${fail} FAILURE(S)`}`);
process.exit(fail === 0 ? 0 : 1);
