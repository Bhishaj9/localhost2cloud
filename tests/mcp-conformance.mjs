#!/usr/bin/env node
/**
 * Protocol conformance test for the MCP server: speaks raw MCP over stdio and
 * asserts the handshake, tool listing and error handling. No MCP client lib.
 */
import { spawn } from 'node:child_process';
import path from 'node:path';

const server = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..', 'servers', 'mcp-server.mjs');
let failures = 0;

function check(name, cond, detail = '') {
  const tag = cond ? 'PASS' : 'FAIL';
  if (!cond) failures++;
  console.log(`  [${tag}] ${name}${detail ? ' :: ' + detail : ''}`);
}

const child = spawn(process.execPath, [server], { stdio: ['pipe', 'pipe', 'pipe'] });

let stdoutBuf = '';
let stderrBuf = '';
const responses = [];
const waiters = new Map();

child.stdout.setEncoding('utf8');
child.stdout.on('data', (chunk) => {
  stdoutBuf += chunk;
  let i;
  while ((i = stdoutBuf.indexOf('\n')) !== -1) {
    const line = stdoutBuf.slice(0, i).trim();
    stdoutBuf = stdoutBuf.slice(i + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      console.log(`  [FAIL] stdout was not JSON: ${line.slice(0, 120)}`);
      failures++;
      continue;
    }
    responses.push(msg);
    if (msg.id !== undefined && waiters.has(msg.id)) {
      waiters.get(msg.id)(msg);
      waiters.delete(msg.id);
    }
  }
});
child.stderr.setEncoding('utf8');
child.stderr.on('data', (c) => (stderrBuf += c));

let nextId = 1;
function rpc(method, params) {
  const id = nextId++;
  const p = new Promise((resolve) => waiters.set(id, resolve));
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  return p;
}
function notify(method, params) {
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');
}

const timeout = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  console.log('=== MCP protocol conformance ===');

  // 1. initialize
  const init = await Promise.race([rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1' } }), timeout(5000)]);
  check('initialize responds', Boolean(init?.result), JSON.stringify(init?.result?.protocolVersion));
  check('negotiated a known protocol version', ['2025-06-18', '2025-03-26', '2024-11-05'].includes(init?.result?.protocolVersion));
  check('advertises tools capability', Boolean(init?.result?.capabilities?.tools));
  check('serverInfo present', Boolean(init?.result?.serverInfo?.name));

  // 2. initialized notification (must produce no response)
  notify('notifications/initialized', {});
  await timeout(300);

  // 3. ping
  const ping = await Promise.race([rpc('ping', {}), timeout(3000)]);
  check('ping responds', Boolean(ping && 'result' in ping));

  // 4. tools/list
  const list = await Promise.race([rpc('tools/list', {}), timeout(5000)]);
  const tools = list?.result?.tools ?? [];
  check('tools/list returns 3 tools', tools.length === 3, tools.map((t) => t.name).join(', '));
  const names = tools.map((t) => t.name).sort();
  check('tool names correct', JSON.stringify(names) === JSON.stringify(['localhost2cloud_boot', 'localhost2cloud_status', 'localhost2cloud_stop']));
  check('every tool has an object schema', tools.every((t) => t.inputSchema?.type === 'object'));
  check('boot schema has provider enum', JSON.stringify(tools.find((t) => t.name.endsWith('boot'))?.inputSchema?.properties?.provider?.enum) === JSON.stringify(['cloudflare', 'ngrok', 'none']));

  // 5. unknown tool -> JSON-RPC error, not a crash
  const bad = await Promise.race([rpc('tools/call', { name: 'nope', arguments: {} }), timeout(4000)]);
  check('unknown tool returns error code', bad?.error?.code === -32602, `code=${bad?.error?.code}`);

  // 6. unknown method -> method not found
  const badMethod = await Promise.race([rpc('nonsense/method', {}), timeout(4000)]);
  check('unknown method returns -32601', badMethod?.error?.code === -32601, `code=${badMethod?.error?.code}`);

  // 7. status against a project with no demo running: must not hang or crash
  const status = await Promise.race([
    rpc('tools/call', { name: 'localhost2cloud_status', arguments: { working_directory: 'D:/Temp' } }),
    timeout(60000),
  ]);
  const statusText = status?.result?.content?.[0]?.text;
  check('status returns content', Boolean(statusText), String(statusText).slice(0, 80));
  if (statusText) {
    let parsed = null;
    try { parsed = JSON.parse(statusText); } catch {}
    check('status payload is valid JSON', parsed !== null);
    check('status reports running=false when nothing is up', parsed?.running === false, `running=${parsed?.running}`);
  }

  // 8. stdout purity
  check('stdout carried only JSON-RPC', responses.length > 0);
  check('server logged to stderr', stderrBuf.length > 0, `${stderrBuf.split('\n')[0] ?? ''}`);

  child.kill();
  console.log(`\n${failures === 0 ? 'ALL PASS' : failures + ' FAILURE(S)'}`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('test crashed:', e);
  child.kill();
  process.exit(1);
});
