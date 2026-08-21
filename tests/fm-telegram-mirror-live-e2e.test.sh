#!/usr/bin/env bash
# Real extension lifecycle regression against an executable fake Telegram transport.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-mirror-live)
home="$TMP_ROOT/home"
mkdir -p "$home/config" "$home/state"
printf 'on\n' >"$home/config/telegram-mirror"
touch "$home/state/.lock" "$home/state/.primary"

cat >"$TMP_ROOT/lock-lib.sh" <<'SH'
fm_session_lock_owned_by_self() { [ -f "$1/.primary" ]; }
SH

cat >"$TMP_ROOT/fake-transport.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == '--home'
home = Path(args[1]); args = args[2:]
path = home / 'fake-state.json'
state = json.loads(path.read_text()) if path.exists() else {'request': None, 'deliveries': {}, 'log': []}
command, rest = args[0], args[1:]
state.setdefault('log', []).append([command, *rest])
def save():
    path.write_text(json.dumps(state))
def option(name):
    return rest[rest.index(name) + 1] if name in rest else None
code = 0
if command == 'mirror-reconcile':
    request = state.get('request')
    if request and request.get('status') == 'claimed' and option('--owner-pid') is not None:
        request['status'] = 'queued'; request.pop('owner', None)
elif command == 'mirror-next':
    request = state.get('request')
    if request and request.get('status') == 'queued': print(request['id'])
    else: code = 1
elif command == 'mirror-claim':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'queued': code = 1
    else: request['status'] = 'claimed'; request['owner'] = int(option('--owner-pid'))
elif command == 'mirror-read':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'claimed': code = 1
    else: sys.stdout.write(request['text'])
elif command == 'mirror-release':
    request = state.get('request')
    if not request or request.get('id') != rest[0]: code = 1
    else: request['status'] = 'queued'; request.pop('owner', None)
elif command == 'mirror-delivered':
    state.setdefault('receipts', []).append(rest[0])
elif command == 'mirror-reply':
    delivery_id = rest[0]
    body = Path(option('--text-file')).read_text()
    existing = state['deliveries'].get(delivery_id)
    if existing is not None and existing != body: code = 1
    else: state['deliveries'][delivery_id] = body
elif command == 'mirror-complete':
    request_id, delivery_id = rest[:2]
    request = state.get('request')
    if (not request or request.get('id') != request_id
            or delivery_id not in state['deliveries'] or request.get('status') != 'claimed'):
        code = 1
    else:
        state.setdefault('handled', []).append(request_id); state['request'] = None
elif command == 'mirror-mode':
    action = rest[0]
    mode_path = home / 'config' / 'telegram-mirror'
    if action == 'status': print(mode_path.read_text().strip())
    else:
        mode_path.write_text(action + '\n'); print('Pi · Telegram mirror mode is ' + action + '.')
else:
    code = 1
save()
raise SystemExit(code)
PY
chmod +x "$TMP_ROOT/fake-transport.py"
printf '%s\n' '{"request":{"id":"tg-text-u1-m1","text":"hello from Telegram","status":"queued"},"deliveries":{},"log":[]}' >"$home/fake-state.json"

cat >"$TMP_ROOT/harness.mjs" <<'JS'
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, writeFileSync, unlinkSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [extensionPath, home, transport] = process.argv.slice(2);
process.env.FM_HOME = home;
process.env.FM_TELEGRAM_TRANSPORT = transport;
process.env.FM_TELEGRAM_SESSION_LOCK_LIB = process.env.FM_TELEGRAM_SESSION_LOCK_LIB;
const factory = (await import(pathToFileURL(extensionPath).href + `?test=${Date.now()}`)).default;
const handlers = new Map();
const commands = new Map();
const sent = [];
const transformed = [];
const statuses = [];
const notifications = [];
const pending = [];
let idle = false;
let sendThrows = false;
let leaf = 'leaf-1';
const pi = {
  on(name, handler) { handlers.set(name, [...(handlers.get(name) || []), handler]); },
  registerCommand(name, value) { commands.set(name, value); },
  registerTool() { throw new Error('mirror extension registered a model tool'); },
  exec(command, args) {
    const result = spawnSync(command, args, { cwd: home, encoding: 'utf8' });
    return Promise.resolve({ code: result.status ?? 1, stdout: result.stdout || '', stderr: result.stderr || '' });
  },
  sendUserMessage(text) {
    sent.push(text);
    for (const handler of handlers.get('input') || []) {
      const promise = Promise.resolve(handler({ source: 'extension', text }, context)).then((result) => {
        if (result?.action === 'transform') transformed.push(result.text);
      });
      pending.push(promise);
    }
    if (sendThrows) throw new Error('accepted before persistence interruption');
  },
};
const context = {
  mode: 'tui', hasUI: true, signal: undefined,
  isIdle: () => idle,
  ui: {
    setStatus(_key, value) { statuses.push(value); },
    notify(value) { notifications.push(value); },
  },
  sessionManager: {
    getSessionId: () => 'session-1',
    getLeafId: () => leaf,
  },
};
async function emit(name, event = {}) {
  let result;
  for (const handler of handlers.get(name) || []) result = await handler(event, context);
  await Promise.all(pending.splice(0));
  return result;
}
async function waitFor(predicate, message) {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    await Promise.all(pending.splice(0));
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.fail(message);
}
function state() { return JSON.parse(readFileSync(`${home}/fake-state.json`, 'utf8')); }
function save(value) { writeFileSync(`${home}/fake-state.json`, JSON.stringify(value)); }

factory(pi);
assert.equal(commands.has('telegram'), true);
await emit('session_start', { reason: 'startup' });
await new Promise((resolve) => setTimeout(resolve, 100));
assert.equal(sent.length, 0, 'busy startup injected a Telegram turn');
idle = true;
await waitFor(() => sent.length === 1, `idle rescan did not inject the queued Telegram turn: ${JSON.stringify({ statuses, state: state() })}`);
assert.equal(sent[0], 'hello from Telegram');
assert.equal(transformed[0], 'You · Telegram\n\nhello from Telegram');
const busyTerminal = await emit('input', { source: 'interactive', text: 'terminal confirmation while busy' });
assert.equal(busyTerminal.text, 'You · Terminal\n\nterminal confirmation while busy');
const authority = await emit('before_agent_start', { systemPrompt: 'base' });
assert.match(authority.systemPrompt, /authenticated Telegram mirror/);
assert.match(authority.systemPrompt, /interactive terminal/);
await emit('message_end', { message: { role: 'toolResult', content: [{ type: 'text', text: 'secret tool bytes' }] } });
await emit('message_end', { message: { role: 'assistant', stopReason: 'toolUse', content: [{ type: 'text', text: 'intermediate tool preface' }] } });
await emit('message_end', { message: { role: 'assistant', stopReason: 'stop', content: [{ type: 'thinking', thinking: 'hidden' }, { type: 'text', text: 'settled answer' }] } });
await emit('agent_settled');
await waitFor(() => state().handled?.includes('tg-text-u1-m1'), 'settled Telegram request was not durably completed');
let current = state();
assert.equal(Object.values(current.deliveries).filter((body) => body === 'You · Terminal\n\nterminal confirmation while busy').length, 1);
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · settled answer').length, 1);
assert.equal(current.receipts.length, 1);
const terminalDeliveriesBeforeReload = Object.values(current.deliveries).filter((body) => body.startsWith('You · Terminal')).length;

await emit('session_shutdown', { reason: 'reload' });
await emit('session_start', { reason: 'reload' });
await new Promise((resolve) => setTimeout(resolve, 100));
assert.equal(sent.length, 1, 'reload reinjected a completed request');
assert.equal(Object.values(state().deliveries).filter((body) => body.startsWith('You · Terminal')).length, terminalDeliveriesBeforeReload, 'reload replayed terminal history');

const replacement = state();
replacement.request = { id: 'tg-text-u2-m2', text: 'replacement request', status: 'claimed', owner: process.pid };
save(replacement);
await emit('session_shutdown', { reason: 'resume' });
await emit('session_start', { reason: 'resume' });
await waitFor(() => sent.length === 2, 'session replacement did not reconcile its live claim');
assert.equal(transformed[1], 'You · Telegram\n\nreplacement request');
leaf = 'leaf-2';
await emit('message_end', { message: { role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: 'replacement answer' }] } });
await emit('agent_settled');
await waitFor(() => state().handled?.includes('tg-text-u2-m2'), 'replacement request did not complete');

leaf = 'leaf-3';
const terminalResult = await emit('input', { source: 'interactive', text: 'terminal request' });
assert.equal(terminalResult.text, 'You · Terminal\n\nterminal request');
await emit('message_end', { message: { role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: 'terminal answer' }] } });
await emit('agent_settled');
current = state();
assert.equal(Object.values(current.deliveries).filter((body) => body === 'You · Terminal\n\nterminal request').length, 1);
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · terminal answer').length, 1);
const beforeExcluded = Object.keys(current.deliveries).length;
await emit('input', { source: 'rpc', text: 'rpc diagnostic' });
await emit('input', { source: 'extension', text: 'other extension message' });
await emit('message_end', { message: { role: 'assistant', stopReason: 'stop', content: [{ type: 'text', text: 'must not mirror' }] } });
await emit('agent_settled');
assert.equal(Object.keys(state().deliveries).length, beforeExcluded);

unlinkSync(`${home}/state/.primary`);
await emit('session_shutdown', { reason: 'reload' });
await emit('session_start', { reason: 'reload' });
assert.equal(statuses.at(-1), 'telegram: not the primary session');

writeFileSync(`${home}/state/.primary`, '');
const crash = state();
crash.request = { id: 'tg-text-u3-m3', text: 'crash boundary', status: 'queued' };
save(crash);
sendThrows = true;
idle = true;
await emit('session_shutdown', { reason: 'reload' });
await emit('session_start', { reason: 'reload' });
await waitFor(() => state().request?.status === 'queued', 'accepted-before-persistence interruption did not leave a retryable request');
await emit('session_shutdown', { reason: 'quit' });
assert.equal(notifications.length, 0);
console.log('pass: real mirror extension injection, labels, authority, fan-out, completion, replacement, exclusions, lock, and crash contract');
JS

FM_TELEGRAM_SESSION_LOCK_LIB="$TMP_ROOT/lock-lib.sh" \
  node --experimental-transform-types "$TMP_ROOT/harness.mjs" \
  "$ROOT/.pi/extensions/fm-telegram-mirror.ts" "$home" "$TMP_ROOT/fake-transport.py"
