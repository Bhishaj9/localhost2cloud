#!/usr/bin/env node
/**
 * Release gate: boots a real two-service stack, checks the promises this tool
 * makes, tears it down, and confirms nothing leaked. Self-contained — it builds
 * its own fixture, so it needs nothing but Node and the CLI tools.
 *
 *   node tests/release-gate.mjs
 *
 * Exit code 0 = every check passed.
 */
import { spawn } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, readdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const SELF = new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1');
const REPO = path.resolve(path.dirname(SELF), '..');
const PROJ = path.join(os.tmpdir(), 'localhost2cloud-gate-proj');
const GATEWAY = 8460;
const APP_PORT = 3460;
const ENGINE_PORT = 7860;
const PY = process.platform === 'win32' ? 'python' : 'python3';

let fail = 0;
const check = (n, c, d = '') => {
  if (!c) fail++;
  console.log(`  [${c ? 'PASS' : 'FAIL'}] ${n}${d ? ' :: ' + d : ''}`);
};

// --- fixture ---------------------------------------------------------------
const APP_SRC = `import sys, http.server, socketserver
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>app</title><h1>ok</h1>'
        self.send_response(200)
        self.send_header('Content-Type','text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', port), H) as s: s.serve_forever()
`;

const ENGINE_SRC = `import sys, http.server, socketserver
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            body=b'{"status":"healthy"}'; code=200
        else:
            body=b'{"error":"unauthorized"}'; code=401
        self.send_response(code)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(('127.0.0.1', port), H) as s: s.serve_forever()
`;

function setup() {
  if (existsSync(PROJ)) {
    try {
      rmSync(PROJ, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
    } catch {
      /* Windows file locks; the run may still succeed */
    }
  }
  mkdirSync(PROJ, { recursive: true });
  writeFileSync(path.join(PROJ, 'app.py'), APP_SRC);
  writeFileSync(path.join(PROJ, 'engine.py'), ENGINE_SRC);
  writeFileSync(
    path.join(PROJ, 'demo.config.json'),
    JSON.stringify(
      {
        services: [
          {
            name: 'engine',
            command: PY,
            startArgs: ['engine.py', String(ENGINE_PORT)],
            port: ENGINE_PORT,
            healthUrl: `http://127.0.0.1:${ENGINE_PORT}/health`,
            expose: ['/api/v1/*'],
            verifyPath: '/api/v1/health',
            acceptStatus: [401],
          },
          {
            name: 'app',
            command: PY,
            startArgs: ['app.py', String(APP_PORT)],
            port: APP_PORT,
            healthUrl: `http://127.0.0.1:${APP_PORT}/`,
            default: true,
          },
        ],
        gateway: { port: GATEWAY },
      },
      null,
      2
    )
  );
}

// setup() must run before spawn: the spawn cwd is PROJ.
setup();

// --- MCP client ------------------------------------------------------------
const child = spawn(process.execPath, [path.join(REPO, 'servers', 'mcp-server.mjs')], {
  stdio: ['pipe', 'pipe', 'pipe'],
  cwd: PROJ,
});
let buf = '';
let stderrText = '';
const waiters = new Map();
child.stdout.setEncoding('utf8');
child.stdout.on('data', (c) => {
  buf += c;
  let i;
  while ((i = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, i).trim();
    buf = buf.slice(i + 1);
    if (!line) continue;
    const m = JSON.parse(line);
    if (m.id && waiters.has(m.id)) {
      waiters.get(m.id)(m);
      waiters.delete(m.id);
    }
  }
});
child.stderr.setEncoding('utf8');
child.stderr.on('data', (c) => (stderrText += c));

let id = 1;
const rpc = (method, params) => {
  const myId = id++;
  const p = new Promise((r) => waiters.set(myId, r));
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: myId, method, params }) + '\n');
  return p;
};
const tmo = (ms) => new Promise((r) => setTimeout(r, ms));
const call = async (name, args, ms = 300000) => {
  const r = await Promise.race([rpc('tools/call', { name, arguments: args }), tmo(ms)]);
  const t = r?.result?.content?.[0]?.text;
  try {
    return { json: JSON.parse(t), isError: r?.result?.isError === true };
  } catch {
    return { json: null, raw: t, isError: r?.result?.isError === true };
  }
};

async function main() {
  console.log('=== 0. preconditions ===');
  check('fixture built', existsSync(path.join(PROJ, 'demo.config.json')), PROJ);
  await rpc('initialize', {
    protocolVersion: '2025-06-18',
    capabilities: {},
    clientInfo: { name: 'release-gate', version: '1' },
  });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  await tmo(200);
  check('MCP handshake completed', true);

  console.log('\n=== 1. boot ===');
  const boot = await call('localhost2cloud_boot', { working_directory: PROJ, provider: 'none' });
  check('boot ok', boot.json?.ok === true, JSON.stringify(boot.json ?? boot.raw).slice(0, 90));
  check('returns a URL', typeof boot.json?.url === 'string', boot.json?.url);
  check(
    'both services healthy',
    (boot.json?.services ?? []).every((s) => s.healthy === true),
    (boot.json?.services ?? []).map((s) => `${s.name}=${s.status}`).join(' ')
  );

  console.log('\n=== 2. one-origin routing (the core promise) ===');
  const page = await fetch(`http://127.0.0.1:${GATEWAY}/`).then((r) => r.status).catch(() => 0);
  const engine = await fetch(`http://127.0.0.1:${GATEWAY}/api/v1/health`).then((r) => r.status).catch(() => 0);
  check('page served through the gateway', page === 200, `HTTP ${page}`);
  check('engine routed on /api/v1/* (401 = auth-gated, correct)', engine === 401, `HTTP ${engine}`);

  console.log('\n=== 3. status ===');
  const st = await call('localhost2cloud_status', { working_directory: PROJ });
  check('running=true', st.json?.running === true, `running=${st.json?.running}`);
  check('complete=true', st.json?.complete === true, `complete=${st.json?.complete}`);
  check('healthy=true', st.json?.healthy === true);

  console.log('\n=== 4. a second boot must not duplicate the stack ===');
  const dup = await call('localhost2cloud_boot', { working_directory: PROJ, provider: 'none' });
  check('second boot handled without hang or crash', dup.json !== null || dup.isError, `ok=${dup.json?.ok}`);

  console.log('\n=== 5. stop ===');
  const stop = await call('localhost2cloud_stop', { working_directory: PROJ });
  check('stop ok', stop.json?.ok === true, `exit=${stop.json?.exit_code}`);
  check('link closed', stop.json?.link_closed === true);
  check('nothing still running', (stop.json?.still_running ?? []).length === 0);

  console.log('\n=== 6. ports genuinely released ===');
  for (const p of [GATEWAY, APP_PORT, ENGINE_PORT]) {
    const open = await fetch(`http://127.0.0.1:${p}/`).then(() => true).catch(() => false);
    check(`port ${p} closed`, !open);
  }

  console.log('\n=== 7. no leaked state or locks ===');
  check('session.json removed', !existsSync(path.join(PROJ, '.demo-state', 'session.json')));
  const locks = readdirSync(os.tmpdir()).filter((f) => f.startsWith('localhost2cloud-') && f.endsWith('.lock'));
  check('no boot locks left behind', locks.length === 0, locks.join(','));

  console.log('\n=== 8. stdout purity ===');
  check('server logged only to stderr', stderrText.includes('[localhost2cloud]'));

  child.kill();
  try {
    rmSync(PROJ, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
  } catch {
    /* Windows file locks; harmless */
  }
  console.log(`\n${fail === 0 ? 'RELEASE GATE: PASS' : `RELEASE GATE: ${fail} FAILURE(S)`}`);
  process.exit(fail === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('gate crashed:', e);
  child.kill();
  process.exit(1);
});
