#!/usr/bin/env node
/**
 * localhost2cloud MCP server (stdio transport, zero dependencies).
 *
 * Wraps the existing scripts so an agent gets structured results instead of
 * parsing session.json out of a shell. Three tools:
 *
 *   localhost2cloud_boot    -> { url, provider, services[], healthy }
 *   localhost2cloud_status  -> { running, url, services[], healthy, complete }
 *   localhost2cloud_stop    -> { stopped[], still_running[] }
 *
 * Design notes:
 *  - No dependencies. A demo tool that needs an `npm install` before it works is
 *    a demo tool that fails at the wrong moment.
 *  - The scripts stay the single source of truth. This server shells out to them
 *    and parses their session file; it never reimplements tunnel or proxy logic.
 *  - stdout carries ONLY JSON-RPC messages, per the MCP stdio spec. Anything we
 *    want to log goes to stderr.
 */

import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const SERVER_NAME = 'localhost2cloud';
const SERVER_VERSION = '1.0.0';
const PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05'];

// The skill directory: two levels up from servers/ (servers/ -> skill root).
const SKILL_DIR = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');
const isWindows = process.platform === 'win32';

// ---------------------------------------------------------------------------
// Logging — stderr only, never stdout
// ---------------------------------------------------------------------------
function log(...args) {
  process.stderr.write(`[${SERVER_NAME}] ${args.join(' ')}\n`);
}

// ---------------------------------------------------------------------------
// Tool definitions
// ---------------------------------------------------------------------------
const TOOLS = [
  {
    name: 'localhost2cloud_boot',
    description:
      'Boot the local app stack described by demo.config.json and open one public HTTPS link ' +
      'the team can open in a browser. Returns the URL plus per-service health. Use when the ' +
      'user wants a shareable demo link for an app running on this machine.',
    inputSchema: {
      type: 'object',
      properties: {
        config_path: {
          type: 'string',
          description:
            'Path to demo.config.json. Omit to auto-discover from the current directory upward.',
        },
        provider: {
          type: 'string',
          enum: ['cloudflare', 'ngrok', 'none'],
          description:
            'Tunnel provider. "cloudflare" (default) gives an anonymous public URL; "none" keeps it local only.',
        },
        dev_mode: {
          type: 'boolean',
          description: 'Use each service\'s devMode start args (hot reload) instead of production.',
        },
        force: {
          type: 'boolean',
          description: 'Tear down an existing session first, then boot fresh.',
        },
        working_directory: {
          type: 'string',
          description: 'Directory to run from. Defaults to the MCP process cwd.',
        },
      },
    },
  },
  {
    name: 'localhost2cloud_status',
    description:
      'Report whether the demo and its public link are alive: process state, service ports, ' +
      'gateway routing and the public URL. Returns the link so it can be re-shared.',
    inputSchema: {
      type: 'object',
      properties: {
        config_path: { type: 'string', description: 'Path to demo.config.json. Omit to auto-discover.' },
        working_directory: { type: 'string', description: 'Directory to run from.' },
      },
    },
  },
  {
    name: 'localhost2cloud_stop',
    description:
      'Close the public link and stop what the demo started, using the recorded session. ' +
      'Services that were already running before the boot are left alone by default. ' +
      'Use when the audience is done or the user says to kill the demo.',
    inputSchema: {
      type: 'object',
      properties: {
        config_path: { type: 'string', description: 'Path to demo.config.json. Omit to auto-discover.' },
        include_reused: {
          type: 'boolean',
          description: 'Also stop services that were already running before the demo booted.',
        },
        working_directory: { type: 'string', description: 'Directory to run from.' },
      },
    },
  },
];

// ---------------------------------------------------------------------------
// Script invocation
// ---------------------------------------------------------------------------
function scriptPath(base) {
  // Windows is the supported platform; fall back to bash elsewhere.
  return isWindows
    ? path.join(SKILL_DIR, 'scripts', `${base}.ps1`)
    : path.join(SKILL_DIR, 'scripts', shellName(base));
}

function shellName(base) {
  // PowerShell file names differ from their bash counterparts.
  const map = {
    'Start-Demo': 'start.sh',
    'Status-Demo': 'status.sh',
    'Stop-Demo': 'stop.sh',
  };
  return map[base] ?? `${base}.sh`;
}

/** Run a script and capture stdout+stderr. Never throws; returns the result.
 *
 *  IMPORTANT: resolve on 'exit', never on 'close'.
 *  The boot script starts long-lived services as children. Those inherit the
 *  stdio pipes, so the pipes stay open after the script itself exits and
 *  Node's 'close' event never fires - waiting on it hangs the tool call
 *  forever. 'exit' fires when the script process is done, which is exactly the
 *  signal we need. (Verified: exit at ~4.5s, close never.)
 */
function runScript(base, args, cwd) {
  return new Promise((resolve) => {
    const file = scriptPath(base);
    if (!existsSync(file)) {
      resolve({ code: -1, output: `Script not found: ${file}`, file });
      return;
    }

    const child = isWindows
      ? spawn('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', file, ...args], {
          cwd,
          windowsHide: true,
          stdio: ['ignore', 'pipe', 'pipe'],
        })
      : spawn('bash', [file, ...args], { cwd, stdio: ['ignore', 'pipe', 'pipe'] });

    let out = '';
    let settled = false;
    const finish = (code) => {
      if (settled) return;
      settled = true;
      clearTimeout(hardTimer);
      resolve({ code, output: out, file });
    };

    // Backstop: a wedged script must not hang the agent's turn indefinitely.
    const hardTimer = setTimeout(() => {
      log(`script ${base} exceeded 10 minutes - returning partial output`);
      try { child.kill('SIGKILL'); } catch {}
      finish(-2);
    }, 10 * 60 * 1000);

    child.stdout.on('data', (d) => (out += d.toString()));
    child.stderr.on('data', (d) => (out += d.toString()));
    child.on('error', (err) => {
      out += `\n${err.message}`;
      finish(-1);
    });
    child.on('exit', (code) => finish(code ?? -1));
  });
}

// ---------------------------------------------------------------------------
// Session state (the scripts own it; we only read)
// ---------------------------------------------------------------------------
function findConfig(startDir) {
  let dir = startDir;
  for (let i = 0; i < 40; i++) {
    const candidate = path.join(dir, 'demo.config.json');
    if (existsSync(candidate)) return candidate;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

function readSession(startDir) {
  const config = findConfig(startDir);
  if (!config) return { configPath: null, session: null, config: null };
  const projectDir = path.dirname(config);
  const sessionPath = path.join(projectDir, '.demo-state', 'session.json');
  let session = null;
  let cfg = null;
  // Strip a UTF-8 BOM before parsing: PowerShell's `Set-Content -Encoding UTF8`
  // writes one, and JSON.parse rejects it. Without this every read of a
  // Windows-written session silently failed and status reported "not running".
  const readJson = (file) => JSON.parse(readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
  try {
    if (existsSync(sessionPath)) session = readJson(sessionPath);
  } catch (e) {
    log(`unreadable session: ${e.message}`);
  }
  try {
    cfg = readJson(config);
  } catch {
    cfg = null;
  }
  return { configPath: config, projectDir, session, config: cfg };
}

// ---------------------------------------------------------------------------
// Output parsing — the scripts print human text; extract the machine facts
// ---------------------------------------------------------------------------
function parseUrl(text) {
  const m = text.match(/https:\/\/[a-z0-9.-]+\.(trycloudflare\.com|ngrok-free\.(app|dev)|ngrok\.(app|dev))[^\s]*/i);
  if (m) return m[0];
  const local = text.match(/http:\/\/127\.0\.0\.1:(\d+)/);
  return local ? local[0] : null;
}

function parseStopped(text) {
  const stopped = [];
  const gone = [];
  for (const line of text.split(/\r?\n/)) {
    const s = line.match(/^\s+(\S+) stopped \(pid (\d+)\)/);
    if (s) stopped.push({ name: s[1], pid: Number(s[2]) });
    const g = line.match(/^\s+(\S+) already gone \(pid (\d+)\)/);
    if (g) gone.push({ name: g[1], pid: Number(g[2]) });
  }
  return { stopped, gone };
}

/** Probe each declared service's healthUrl directly — cheaper and truer than
 *  trusting the script's prose. */
async function probeServices(config) {
  if (!config?.services) return [];
  const results = [];
  for (const svc of config.services) {
    if (!svc.healthUrl) {
      results.push({ name: svc.name, port: svc.port, healthy: null, status: 'no-health-url' });
      continue;
    }
    const accept = Array.isArray(svc.acceptStatus) ? svc.acceptStatus : [];
    let healthy = false;
    let status = 'unreachable';
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 4000);
      const res = await fetch(svc.healthUrl, { signal: ctrl.signal }).catch((e) => ({ _err: e }));
      clearTimeout(timer);
      if (res?._err) {
        status = 'unreachable';
      } else {
        status = `HTTP ${res.status}`;
        healthy = (res.status >= 200 && res.status < 400) || accept.includes(res.status);
      }
    } catch {
      status = 'unreachable';
    }
    results.push({ name: svc.name, port: svc.port, healthy, status });
  }
  return results;
}

// ---------------------------------------------------------------------------
// Process identity
// ---------------------------------------------------------------------------
// A bare `kill(pid, 0)` only proves *some* process holds that PID. Windows and
// Linux both recycle PIDs aggressively, so a stale session could report
// "running" for something completely unrelated - and the scripts deliberately
// guard against that. We must use the same check, or the two interfaces
// disagree about reality.
//
// The scripts record Starts[name] as:
//   Windows: PowerShell  $p.StartTime.ToUniversalTime().ToString('o')
//   POSIX:   ps -p PID -o lstart=
// We query with the SAME method so the strings are directly comparable.

/** Return Map<pid, startString> for the pids that exist. One child process. */
async function readStartTimes(pids) {
  const out = new Map();
  const list = pids.filter((p) => Number.isInteger(p) && p > 0);
  if (list.length === 0) return out;

  if (isWindows) {
    const script =
      `$ids = @(${list.join(',')}); ` +
      `foreach ($i in $ids) { ` +
      `  try { $p = Get-Process -Id $i -ErrorAction Stop; ` +
      `        Write-Output ("{0}|{1}" -f $i, $p.StartTime.ToUniversalTime().ToString('o')) } ` +
      `  catch { Write-Output ("{0}|" -f $i) } }`;
    const { output } = await runProcess('powershell', ['-NoProfile', '-NonInteractive', '-Command', script]);
    for (const line of output.split(/\r?\n/)) {
      const m = line.match(/^\s*(\d+)\|(.*)$/);
      if (m && m[2].trim()) out.set(Number(m[1]), m[2].trim());
    }
  } else {
    const { output } = await runProcess('ps', ['-p', list.join(','), '-o', 'pid=,lstart=']);
    for (const line of output.split(/\r?\n/)) {
      const m = line.match(/^\s*(\d+)\s+(.+?)\s*$/);
      if (m) out.set(Number(m[1]), m[2].trim());
    }
  }
  return out;
}

/** Minimal argv runner for the identity probe (not the demo scripts). */
function runProcess(cmd, args) {
  return new Promise((resolve) => {
    let out = '';
    try {
      const child = spawn(cmd, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      const timer = setTimeout(() => {
        try { child.kill('SIGKILL'); } catch {}
        resolve({ output: out });
      }, 15000);
      child.stdout.on('data', (d) => (out += d.toString()));
      child.stderr.on('data', (d) => (out += d.toString()));
      child.on('error', () => { clearTimeout(timer); resolve({ output: out }); });
      child.on('exit', () => { clearTimeout(timer); resolve({ output: out }); });
    } catch {
      resolve({ output: '' });
    }
  });
}

/**
 * Is this session still ours?
 * Returns { running, verified } where `verified` is false when every recorded
 * pid lacks a fingerprint (a session written by an older version), in which
 * case we degrade to an existence check and say so instead of pretending.
 */
async function sessionAlive(session) {
  if (!session?.Pids) return { running: false, verified: true };
  const entries = Object.entries(session.Pids).filter(([, pid]) => Number.isInteger(pid) && pid > 0);
  if (entries.length === 0) return { running: false, verified: true };

  const starts = await readStartTimes(entries.map(([, pid]) => pid));
  let sawFingerprint = false;

  for (const [name, pid] of entries) {
    const recorded = session.Starts?.[name];
    if (!recorded) continue; // no fingerprint: not conclusive
    sawFingerprint = true;
    const actual = starts.get(pid);
    if (!actual) continue; // process gone
    if (actual === String(recorded).trim()) return { running: true, verified: true };
    // Same PID, different process: the demo is gone.
    log(`pid ${pid} (${name}) was reused by an unrelated process - not counting it as running`);
  }

  if (!sawFingerprint) {
    // Legacy session: fall back, but be explicit that identity was not proven.
    return { running: starts.size > 0, verified: false };
  }
  return { running: false, verified: true };
}

// ---------------------------------------------------------------------------
// Tool handlers
// ---------------------------------------------------------------------------
async function handleBoot(args) {
  const cwd = args.working_directory || process.cwd();
  const cli = [];
  if (args.config_path) cli.push('-ConfigPath', args.config_path);
  if (args.provider) cli.push('-Provider', args.provider);
  if (args.dev_mode) cli.push('-DevMode');
  if (args.force) cli.push('-Force');

  const bashArgs = [];
  if (args.config_path) bashArgs.push('--config', args.config_path);
  if (args.provider) bashArgs.push('--provider', args.provider);
  if (args.dev_mode) bashArgs.push('--dev');
  if (args.force) bashArgs.push('--force');

  const { code, output } = await runScript('Start-Demo', isWindows ? cli : bashArgs, cwd);
  const state = readSession(cwd);
  const url = parseUrl(output);
  const services = await probeServices(state.config);
  const booted = /SHARE THIS LINK/.test(output);

  if (!booted && code !== 0) {
    return {
      content: [
        {
          type: 'text',
          text: JSON.stringify(
            {
              ok: false,
              error: 'boot failed',
              exit_code: code,
              detail: output.split(/\r?\n/).filter(Boolean).slice(-12).join('\n'),
            },
            null,
            2
          ),
        },
      ],
      isError: true,
    };
  }

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(
          {
            ok: true,
            url,
            provider: state.session?.Provider ?? args.provider ?? 'cloudflare',
            auth_enabled: Boolean(state.config?.auth?.enabled),
            login_user: state.config?.auth?.enabled ? (state.config.auth.username ?? 'demo') : null,
            services,
            note: url?.startsWith('https://')
              ? 'Share this link with the audience. Anyone with it can open it unless auth is enabled.'
              : 'Local only — no public link was created.',
          },
          null,
          2
        ),
      },
    ],
  };
}

async function handleStatus(args) {
  const cwd = args.working_directory || process.cwd();
  const bashArgs = args.config_path ? ['--config', args.config_path] : [];
  const cli = args.config_path ? ['-ConfigPath', args.config_path] : [];

  const { code, output } = await runScript('Status-Demo', isWindows ? cli : bashArgs, cwd);
  const state = readSession(cwd);
  const services = await probeServices(state.config);
  const liveness = await sessionAlive(state.session);

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(
          {
            running: liveness.running,
            identity_verified: liveness.verified,
            complete: state.session?.Complete ?? null,
            url: state.session?.Url ?? null,
            provider: state.session?.Provider ?? null,
            started_at: state.session?.StartedAt ?? null,
            auth_enabled: Boolean(state.config?.auth?.enabled),
            services,
            healthy: services.every((s) => s.healthy !== false),
            exit_code: code,
          },
          null,
          2
        ),
      },
    ],
  };
}

async function handleStop(args) {
  const cwd = args.working_directory || process.cwd();
  const bashArgs = args.config_path ? ['--config', args.config_path] : [];
  const cli = args.config_path ? ['-ConfigPath', args.config_path] : [];
  if (args.include_reused) {
    if (isWindows) cli.push('-IncludeReused');
    else bashArgs.push('--include-reused');
  }

  const before = readSession(cwd);
  const { code, output } = await runScript('Stop-Demo', isWindows ? cli : bashArgs, cwd);
  const { stopped, gone } = parseStopped(output);
  const after = readSession(cwd);
  const services = await probeServices(after.config);

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify(
          {
            ok: code === 0,
            previous_url: before.session?.Url ?? null,
            stopped,
            already_gone: gone,
            still_running: services.filter((s) => s.healthy === true).map((s) => s.name),
            link_closed: !after.session?.Url,
            exit_code: code,
          },
          null,
          2
        ),
      },
    ],
  };
}

// ---------------------------------------------------------------------------
// JSON-RPC plumbing (newline-delimited, per MCP stdio transport)
// ---------------------------------------------------------------------------
function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function reply(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function fail(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

async function handleMessage(msg) {
  const { id, method, params } = msg;

  // Notifications carry no id and expect no response.
  if (id === undefined || id === null) {
    if (method === 'notifications/initialized') log('client initialized');
    return;
  }

  switch (method) {
    case 'initialize': {
      const requested = params?.protocolVersion;
      const version = PROTOCOL_VERSIONS.includes(requested) ? requested : PROTOCOL_VERSIONS[0];
      reply(id, {
        protocolVersion: version,
        capabilities: { tools: {} },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
      return;
    }

    case 'ping':
      reply(id, {});
      return;

    case 'tools/list':
      reply(id, { tools: TOOLS });
      return;

    case 'tools/call': {
      const name = params?.name;
      const args = params?.arguments ?? {};
      try {
        if (name === 'localhost2cloud_boot') return reply(id, await handleBoot(args));
        if (name === 'localhost2cloud_status') return reply(id, await handleStatus(args));
        if (name === 'localhost2cloud_stop') return reply(id, await handleStop(args));
        fail(id, -32602, `Unknown tool: ${name}`);
      } catch (err) {
        log(`tool error: ${err.stack || err.message}`);
        fail(id, -32603, `Tool failed: ${err.message}`);
      }
      return;
    }

    default:
      fail(id, -32601, `Method not found: ${method}`);
  }
}

// ---------------------------------------------------------------------------
// stdio loop
// ---------------------------------------------------------------------------
let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  // Messages are newline-delimited and MUST NOT contain embedded newlines.
  let idx;
  while ((idx = buffer.indexOf('\n')) !== -1) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (!line) continue;
    let msg;
    try {
      msg = JSON.parse(line);
    } catch (e) {
      log(`bad JSON from client: ${e.message}`);
      continue;
    }
    handleMessage(msg).catch((err) => log(`handler crash: ${err.stack || err.message}`));
  }
});

process.stdin.on('end', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
process.on('SIGTERM', () => process.exit(0));

log(`ready (skill dir: ${SKILL_DIR}, platform: ${process.platform})`);
