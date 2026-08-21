#!/usr/bin/env bash
# Installed Pi runtime regression against the tracked extension and an executable fake transport.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-mirror-live)
home="$TMP_ROOT/home"
agent_dir="$TMP_ROOT/agent"
session_dir="$TMP_ROOT/sessions"
mkdir -p "$home/config" "$home/state" "$agent_dir" "$session_dir"
printf 'on\n' >"$home/config/telegram-mirror"
touch "$home/state/.lock" "$home/state/.primary"

cat >"$TMP_ROOT/lock-lib.sh" <<'SH'
fm_session_lock_owned_by_self() { [ -f "$1/.primary" ]; }
SH

cat >"$TMP_ROOT/fake-transport.py" <<'PY'
#!/usr/bin/env python3
import fcntl, json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert args[0] == '--home'
home = Path(args[1]); args = args[2:]
lock = (home / 'fake-state.lock').open('a+')
fcntl.flock(lock, fcntl.LOCK_EX)
path = home / 'fake-state.json'
state = json.loads(path.read_text()) if path.exists() else {'request': None, 'deliveries': {}, 'log': []}
command, rest = args[0], args[1:]
state.setdefault('log', []).append([command, *rest])
def save():
    temporary = path.with_name(f'.{path.name}.{os.getpid()}')
    temporary.write_text(json.dumps(state)); os.replace(temporary, path)
def option(name):
    return rest[rest.index(name) + 1] if name in rest else None
def options(name):
    return [rest[index + 1] for index, value in enumerate(rest[:-1]) if value == name]
code = 0
if command == 'mirror-open':
    pass
elif command == 'mirror-reconcile':
    request = state.get('request')
    preserved = options('--preserve-request')
    if request and request.get('status') == 'claimed':
        if request.get('id') in preserved:
            request['status'] = 'claimed'; request['owner'] = int(option('--owner-pid'))
        else:
            request['status'] = 'queued'; request.pop('owner', None)
elif command == 'mirror-next':
    request = state.get('request')
    if request and request.get('status') == 'queued': print(request['id'])
    else: code = 1
elif command == 'mirror-claim':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'queued': code = 1
    elif (home / 'config' / 'telegram-mirror').read_text().strip() != 'on': code = 1
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
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'claimed': code = 1
    elif rest[0] not in state.setdefault('receipts', []): state['receipts'].append(rest[0])
elif command == 'mirror-reply':
    delivery_id = rest[0]
    body = sys.stdin.read() if option('--text-file') == '-' else Path(option('--text-file')).read_text()
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

cat >"$TMP_ROOT/runtime.mjs" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, renameSync, writeFileSync, unlinkSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [sdkPath, aiPath, projectRoot, extensionPath, home, agentDir, sessionDir, transport, lockLib] = process.argv.slice(2);
process.env.FM_HOME = home;
process.env.FM_TELEGRAM_TRANSPORT = transport;
process.env.FM_TELEGRAM_SESSION_LOCK_LIB = lockLib;
process.env.FM_TELEGRAM_ADMISSION_TIMEOUT_MS = '150';
const {
  ModelRuntime,
  SessionManager,
  SettingsManager,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
} = await import(pathToFileURL(sdkPath).href);
const { fauxAssistantMessage, fauxProvider } = await import(pathToFileURL(aiPath).href);
const faux = fauxProvider({ tokensPerSecond: 100000 });
const modelRuntime = await ModelRuntime.create({
  authPath: `${agentDir}/auth.json`, modelsPath: null, modelsStorePath: `${agentDir}/models-store.json`,
  refreshOnCreate: false,
});
modelRuntime.registerNativeProvider(faux.provider);
const model = faux.getModel();
const settingsManager = SettingsManager.inMemory({
  compaction: { enabled: false }, retry: { enabled: false }, defaultTools: [],
});
const createRuntime = async ({ cwd, sessionManager, sessionStartEvent }) => {
  const services = await createAgentSessionServices({
    cwd, agentDir, modelRuntime, settingsManager,
    resourceLoaderOptions: { additionalExtensionPaths: [extensionPath] },
  });
  const result = await createAgentSessionFromServices({
    services, sessionManager, sessionStartEvent, model, thinkingLevel: 'off', noTools: 'all',
  });
  return { ...result, services, diagnostics: services.diagnostics };
};
const initialManager = SessionManager.create(home, sessionDir);
const runtime = await createAgentSessionRuntime(createRuntime, {
  cwd: home, agentDir, sessionManager: initialManager,
});
faux.setResponses([
  (context) => {
    assert.match(context.systemPrompt, /authenticated Telegram mirror/);
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.match(user.content.map((part) => part.text || '').join(''), /^You · Telegram/);
    return fauxAssistantMessage('settled answer');
  },
]);
const uiContext = { setStatus() {}, notify() {} };
const bind = async (session) => session.bindExtensions({ mode: 'json', uiContext });
runtime.setRebindSession(bind);
await bind(runtime.session);

function state() { return JSON.parse(readFileSync(`${home}/fake-state.json`, 'utf8')); }
function save(value) {
  const temporary = `${home}/.fake-state.${process.pid}`;
  writeFileSync(temporary, JSON.stringify(value)); renameSync(temporary, `${home}/fake-state.json`);
}
async function waitFor(predicate, message) {
  for (let attempt = 0; attempt < 160; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.fail(message);
}
function userTexts(manager) {
  return manager.getEntries()
    .filter((entry) => entry.type === 'message' && entry.message.role === 'user')
    .map((entry) => entry.message.content.map?.((part) => part.text || '').join('') ?? entry.message.content);
}

await waitFor(() => state().handled?.includes('tg-text-u1-m1')
  && initialManager.getEntries().some((entry) =>
    entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission'
      && entry.data.state === 'completed'), 'real runtime did not complete Telegram admission');
let current = state();
assert.equal(current.receipts.filter((id) => id === 'tg-text-u1-m1').length, 1);
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · settled answer').length, 1);
assert.equal(userTexts(initialManager).filter((text) => text.startsWith('You · Telegram')).length, 1);
assert.equal(initialManager.getEntries().some((entry) =>
  entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission' && entry.data.state === 'completed'), true);
assert.equal(runtime.session.agent.state.tools.some((tool) => /telegram/i.test(tool.name)), false);

const usersBeforeReload = userTexts(initialManager).length;
await runtime.session.reload();
await new Promise((resolve) => setTimeout(resolve, 150));
assert.equal(userTexts(initialManager).length, usersBeforeReload, 'fresh extension reload duplicated a completed request');

faux.appendResponses([
  (context) => {
    assert.doesNotMatch(context.systemPrompt, /authenticated Telegram mirror/);
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.match(user.content.map((part) => part.text || '').join(''), /^You · Terminal/);
    return fauxAssistantMessage('terminal answer');
  },
]);
await runtime.session.prompt('terminal request', { source: 'interactive' });
current = state();
assert.equal(Object.values(current.deliveries).filter((body) => body === 'You · Terminal\n\nterminal request').length, 1);
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · terminal answer').length, 1);

const beforeRpc = Object.keys(current.deliveries).length;
faux.appendResponses([fauxAssistantMessage('rpc diagnostic answer')]);
await runtime.session.prompt('rpc diagnostic', { source: 'rpc' });
assert.equal(Object.keys(state().deliveries).length, beforeRpc, 'RPC input was mirrored');

const replacement = state();
replacement.request = { id: 'tg-text-u2-m2', text: 'replacement request', status: 'claimed', owner: process.pid };
save(replacement);
const turnId = 'telegram-tg-text-u2-m2-persisted';
initialManager.appendCustomEntry('firstmate-telegram-admission', {
  requestId: 'tg-text-u2-m2', turnId, sessionId: initialManager.getSessionId(), state: 'admitted',
});
initialManager.appendMessage({
  role: 'user', content: [{ type: 'text', text: 'You · Telegram\n\nreplacement request' }], timestamp: Date.now(),
});
initialManager.appendMessage(fauxAssistantMessage('replacement answer'));
const previousFile = initialManager.getSessionFile();
await runtime.newSession({ parentSession: previousFile });
await waitFor(() => state().handled?.includes('tg-text-u2-m2'), 'session replacement did not reconcile persisted admission provenance');
assert.equal(userTexts(runtime.session.sessionManager).length, 0, 'session replacement reinjected represented Telegram input');
assert.equal(Object.values(state().deliveries).filter((body) => body === 'Firstmate · replacement answer').length, 1);

const crash = state();
crash.request = { id: 'tg-text-u3-m3', text: 'accepted without persistence', status: 'claimed', owner: process.pid };
save(crash);
faux.appendResponses([fauxAssistantMessage('crash retry answer')]);
await runtime.newSession({ parentSession: runtime.session.sessionFile });
await waitFor(() => state().handled?.includes('tg-text-u3-m3'), 'unpersisted accepted claim was not eligible for bounded reinjection');
assert.equal(userTexts(runtime.session.sessionManager).filter((text) => text.includes('accepted without persistence')).length, 1);

unlinkSync(`${home}/state/.primary`);
await runtime.session.reload();
const lockCount = userTexts(runtime.session.sessionManager).length;
await new Promise((resolve) => setTimeout(resolve, 100));
assert.equal(userTexts(runtime.session.sessionManager).length, lockCount, 'non-primary runtime admitted Telegram input');

await runtime.dispose();

writeFileSync(`${home}/state/.primary`, '');
const failed = state();
failed.request = { id: 'tg-text-u4-m4', text: 'missing model request', status: 'queued' };
const receiptsBeforeFailure = failed.receipts.length;
save(failed);
const emptyRuntime = await ModelRuntime.create({
  authPath: `${agentDir}/empty-auth.json`, modelsPath: null,
  modelsStorePath: `${agentDir}/empty-models-store.json`, refreshOnCreate: false,
});
const failedSettings = SettingsManager.inMemory({
  compaction: { enabled: false }, retry: { enabled: false }, defaultTools: [],
});
const failedServices = await createAgentSessionServices({
  cwd: home, agentDir: `${agentDir}/empty`, modelRuntime: emptyRuntime, settingsManager: failedSettings,
  resourceLoaderOptions: { additionalExtensionPaths: [extensionPath] },
});
const failedManager = SessionManager.create(home, `${sessionDir}/failed`);
const failedResult = await createAgentSessionFromServices({
  services: failedServices, sessionManager: failedManager, noTools: 'all', thinkingLevel: 'off',
});
await failedResult.session.bindExtensions({ mode: 'json', uiContext });
await waitFor(() => {
  const observed = state();
  return observed.request?.status === 'queued'
    && observed.log.some((call) => call[0] === 'mirror-claim' && call[1] === 'tg-text-u4-m4');
}, 'preflight failure did not release its unaccepted claim');
assert.equal(state().receipts.length, receiptsBeforeFailure, 'preflight failure sent a false Pi delivery receipt');
assert.equal(userTexts(failedManager).length, 0, 'preflight failure persisted a Telegram user turn');
unlinkSync(`${home}/state/.primary`);
await failedResult.session.reload();
failedResult.session.dispose();
console.log('pass: installed Pi runtime mirror admission, persistence, reload, replacement, preflight, fan-out, exclusions, lock, and crash contract');
JS

pi_cli=$(readlink -f "$(command -v pi)")
pi_root=$(cd "$(dirname "$pi_cli")/.." && pwd)
sdk_path="$pi_root/dist/index.js"
ai_path="$pi_root/node_modules/@earendil-works/pi-ai/dist/index.js"
node "$TMP_ROOT/runtime.mjs" \
  "$sdk_path" "$ai_path" "$ROOT" "$ROOT/.pi/extensions/fm-telegram-mirror.ts" \
  "$home" "$agent_dir" "$session_dir" "$TMP_ROOT/fake-transport.py" "$TMP_ROOT/lock-lib.sh"
