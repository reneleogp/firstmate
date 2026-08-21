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
import fcntl, json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
assert args[0] == '--home'
home = Path(args[1]); args = args[2:]
command, rest = args[0], args[1:]
reconcile_active = home / 'reconcile-active'
if command in ('mirror-next', 'mirror-claim') and reconcile_active.exists():
    (home / 'drain-overlapped-reconcile').touch()
reconcile_trigger = home / 'delay-next-reconcile'
if command == 'mirror-reconcile' and reconcile_trigger.exists():
    reconcile_trigger.unlink()
    reconcile_active.touch()
    time.sleep(1.2)
    reconcile_active.unlink(missing_ok=True)
lock = (home / 'fake-state.lock').open('a+')
fcntl.flock(lock, fcntl.LOCK_EX)
path = home / 'fake-state.json'
state = json.loads(path.read_text()) if path.exists() else {'request': None, 'deliveries': {}, 'log': []}
state.setdefault('log', []).append([command, *rest])
def save():
    temporary = path.with_name(f'.{path.name}.{os.getpid()}')
    temporary.write_text(json.dumps(state)); os.replace(temporary, path)
def option(name):
    return rest[rest.index(name) + 1] if name in rest else None
def options(name):
    return [rest[index + 1] for index, value in enumerate(rest[:-1]) if value == name]
code = 0
skip_final_save = False
if command == 'mirror-open':
    pass
elif command == 'mirror-reconcile':
    state['legacy_wake'] = False
    request = state.get('request')
    preserved = options('--preserve-request')
    if request and request.get('status') == 'claimed':
        if request.get('id') in preserved:
            request['status'] = 'claimed'; request['owner'] = int(option('--owner-pid'))
        else:
            request['status'] = 'queued'; request.pop('owner', None)
    if request and request.get('status') == 'held':
        print(f"held\t{request['id']}\t{request['turn_id']}")
elif command == 'mirror-next':
    request = state.get('request')
    if request and request.get('status') == 'queued': print(request['id'])
    elif state.get('next_request'): print(state['next_request']['id'])
    else: code = 1
elif command == 'mirror-claim':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'queued': code = 1
    elif (home / 'config' / 'telegram-mirror').read_text().strip() != 'on': code = 1
    else:
        request['status'] = 'claimed'; request['owner'] = int(option('--owner-pid'))
        save()
        delay = request.get('claim_delay_ms', 0)
        if delay:
            skip_final_save = True
            fcntl.flock(lock, fcntl.LOCK_UN)
            time.sleep(delay / 1000)
elif command == 'mirror-read':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'claimed': code = 1
    else: sys.stdout.write(request['text'])
elif command == 'mirror-release':
    request = state.get('request')
    if not request or request.get('id') != rest[0]: code = 1
    else: request['status'] = 'queued'; request.pop('owner', None)
elif command == 'mirror-hold':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') not in ('claimed', 'held'): code = 1
    else:
        request['status'] = 'held'; request['turn_id'] = rest[1]; request.pop('owner', None)
elif command == 'mirror-recover':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'held': code = 1
    else:
        request['status'] = 'queued'; request.pop('turn_id', None)
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
if not skip_final_save: save()
raise SystemExit(code)
PY
chmod +x "$TMP_ROOT/fake-transport.py"
printf '%s\n' '{"request":{"id":"tg-text-u1-m1","text":"hello from Telegram","status":"queued"},"deliveries":{},"log":[]}' >"$home/fake-state.json"

cat >"$TMP_ROOT/competing-extension.ts" <<'TS'
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  let injected = false;
  let nested = false;
  pi.registerTool({
    name: "mirror_test_tool",
    label: "Mirror test tool",
    description: "Return a diagnostic payload for structural mirror exclusion coverage",
    parameters: Type.Object({}),
    async execute() {
      return { content: [{ type: "text" as const, text: "tool diagnostic payload" }], details: {} };
    },
  });
  pi.on("input", async (event) => {
    const state = globalThis as typeof globalThis & { __telegramMirrorInjectNested?: boolean };
    if (state.__telegramMirrorInjectNested && event.source === "extension" && !nested) {
      nested = true;
      pi.sendUserMessage("nested extension input");
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  });
  pi.on("agent_end", () => {
    const state = globalThis as typeof globalThis & { __telegramMirrorInjectOperational?: boolean };
    if (!state.__telegramMirrorInjectOperational || injected) return;
    injected = true;
    pi.sendMessage({
      customType: "mirror-test-operational",
      content: "operational follow-up",
      display: false,
    }, { triggerTurn: true, deliverAs: "followUp" });
  });
}
TS

cat >"$TMP_ROOT/handling-extension.ts" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  pi.on("input", (event) => {
    const state = globalThis as typeof globalThis & { __telegramMirrorHandleExtensionInput?: boolean };
    if (state.__telegramMirrorHandleExtensionInput && event.source === "extension") {
      return { action: "handled" as const };
    }
  });
}
TS

cat >"$TMP_ROOT/runtime.mjs" <<'JS'
import assert from 'node:assert/strict';
import { existsSync, readFileSync, renameSync, writeFileSync, unlinkSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [sdkPath, aiPath, projectRoot, extensionPath, competingPath, handlingPath, home, agentDir, sessionDir, transport, lockLib] = process.argv.slice(2);
process.env.FM_HOME = home;
process.env.FM_TELEGRAM_TRANSPORT = transport;
process.env.FM_TELEGRAM_SESSION_LOCK_LIB = lockLib;
process.env.FM_TELEGRAM_ADMISSION_TIMEOUT_MS = '150';
process.env.FM_TELEGRAM_RECONCILE_INTERVAL_MS = '500';
const {
  ModelRuntime,
  SessionManager,
  SettingsManager,
  createAgentSessionFromServices,
  createAgentSessionRuntime,
  createAgentSessionServices,
} = await import(pathToFileURL(sdkPath).href);
const { fauxAssistantMessage, fauxProvider, fauxThinking, fauxText, fauxToolCall } = await import(pathToFileURL(aiPath).href);
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
    resourceLoaderOptions: { additionalExtensionPaths: [competingPath, extensionPath, handlingPath] },
  });
  const result = await createAgentSessionFromServices({
    services, sessionManager, sessionStartEvent, model, thinkingLevel: 'off', noTools: 'builtin',
  });
  return { ...result, services, diagnostics: services.diagnostics };
};
globalThis.__telegramMirrorInjectNested = true;
const initialManager = SessionManager.create(home, sessionDir);
const runtime = await createAgentSessionRuntime(createRuntime, {
  cwd: home, agentDir, sessionManager: initialManager,
});
faux.setResponses([
  async (context) => {
    assert.doesNotMatch(context.systemPrompt, /authenticated Telegram mirror/);
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.equal(user.content.map((part) => part.text || '').join(''), 'nested extension input');
    await new Promise((resolve) => setTimeout(resolve, 100));
    return fauxAssistantMessage('nested extension answer');
  },
  (context) => {
    assert.match(context.systemPrompt + JSON.stringify(context.messages), /authenticated Telegram mirror/);
    const user = context.messages.findLast((message) => message.role === 'user');
    const text = user.content.map((part) => part.text || '').join('');
    assert.match(text, /^You · Telegram\n\nhello from Telegram/);
    assert.match(text, /authenticated Telegram mirror/);
    assert.doesNotMatch(text, /firstmate-origin/);
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
  assert.fail(`${message}: ${JSON.stringify({ state: state(), entries: initialManager.getEntries(), calls: faux.state.callCount })}`);
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
globalThis.__telegramMirrorInjectNested = false;
assert.equal(current.receipts.filter((id) => id === 'tg-text-u1-m1').length, 1);
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · settled answer').length, 1);
assert.equal(Object.values(current.deliveries).some((body) => body.includes('nested extension answer')), false);
assert.equal(userTexts(initialManager).filter((text) => text.startsWith('You · Telegram')).length, 1);
assert.equal(userTexts(initialManager).filter((text) => text === 'nested extension input').length, 1);
assert.equal(initialManager.getEntries().some((entry) =>
  entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission' && entry.data.state === 'completed'), true);
assert.equal(runtime.session.agent.state.tools.some((tool) => /telegram/i.test(tool.name)), false);

const usersBeforeReload = userTexts(initialManager).length;
await runtime.session.reload();
await new Promise((resolve) => setTimeout(resolve, 150));
assert.equal(userTexts(initialManager).length, usersBeforeReload, 'fresh extension reload duplicated a completed request');
await new Promise((resolve) => setTimeout(resolve, 800));
const idleScansBefore = state().log.filter((call) => call[0] === 'mirror-next').length;
await new Promise((resolve) => setTimeout(resolve, 1600));
const idleScans = state().log.filter((call) => call[0] === 'mirror-next').length - idleScansBefore;
assert.ok(idleScans >= 2 && idleScans <= 3, `idle scan duplicated queue probes: ${idleScans}`);
const lateLegacyWake = state();
lateLegacyWake.legacy_wake = true;
save(lateLegacyWake);
await waitFor(() => state().legacy_wake === false, 'slow reconciliation did not retire a late legacy wake');

writeFileSync(`${home}/delay-next-reconcile`, '');
await waitFor(() => existsSync(`${home}/reconcile-active`), 'delayed reconciliation did not start');
const reconcileRace = state();
reconcileRace.request = {
  id: 'tg-text-u14-m14', text: 'reconcile race request', status: 'queued',
};
save(reconcileRace);
faux.appendResponses([fauxAssistantMessage('reconcile race answer')]);
await waitFor(() => state().handled?.includes('tg-text-u14-m14'),
  'request queued during reconciliation did not settle');
await new Promise((resolve) => setTimeout(resolve, 50));
assert.equal(existsSync(`${home}/drain-overlapped-reconcile`), false,
  'drain started while slow reconciliation was in flight');
assert.equal(userTexts(initialManager).filter((text) => text.includes('reconcile race request')).length, 1);
assert.equal(Object.values(state().deliveries).filter((body) => body === 'Firstmate · reconcile race answer').length, 1);

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

writeFileSync(`${home}/config/telegram-mirror`, 'off\n');
const beforeModeOff = Object.keys(current.deliveries).length;
faux.appendResponses([
  (context) => {
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.equal(user.content.map((part) => part.text || '').join(''), 'ordinary mode-off terminal');
    return fauxAssistantMessage('ordinary mode-off answer');
  },
]);
await runtime.session.prompt('ordinary mode-off terminal', { source: 'interactive' });
assert.equal(Object.keys(state().deliveries).length, beforeModeOff, 'mode-off terminal turn was mirrored');
writeFileSync(`${home}/config/telegram-mirror`, 'on\n');

const beforeRpc = Object.keys(state().deliveries).length;
faux.appendResponses([fauxAssistantMessage('rpc diagnostic answer')]);
await runtime.session.prompt('rpc diagnostic', { source: 'rpc' });
assert.equal(Object.keys(state().deliveries).length, beforeRpc, 'RPC input was mirrored');

const busy = state();
busy.request = {
  id: 'tg-text-u8-m8', text: 'busy Telegram request', status: 'queued', claim_delay_ms: 250,
};
save(busy);
faux.appendResponses([
  async (context) => {
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.match(user.content.map((part) => part.text || '').join(''), /^You · Terminal/);
    await new Promise((resolve) => setTimeout(resolve, 500));
    return fauxAssistantMessage('busy terminal answer');
  },
  (context) => {
    assert.match(context.systemPrompt + JSON.stringify(context.messages), /authenticated Telegram mirror/);
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.match(user.content.map((part) => part.text || '').join(''), /^You · Telegram/);
    return fauxAssistantMessage('busy Telegram answer');
  },
]);
await waitFor(() => state().request?.status === 'claimed', 'delayed claim did not begin while idle');
const busyPrompt = runtime.session.prompt('terminal raced with claim', { source: 'interactive' });
await busyPrompt;
await waitFor(() => state().handled?.includes('tg-text-u8-m8'), 'busy follow-up Telegram turn did not settle');
current = state();
assert.equal(userTexts(initialManager).filter((text) => text.includes('busy Telegram request')).length, 1);
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · busy terminal answer').length, 1);
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · busy Telegram answer').length, 1);
assert.equal(current.receipts.filter((id) => id === 'tg-text-u8-m8').length, 1);

const consumed = state();
consumed.request = {
  id: 'tg-text-u12-m12', text: 'handled by later extension', status: 'queued', claim_delay_ms: 250,
};
save(consumed);
globalThis.__telegramMirrorHandleExtensionInput = true;
faux.appendResponses([
  async (context) => {
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.match(user.content.map((part) => part.text || '').join(''), /^You · Terminal/);
    await new Promise((resolve) => setTimeout(resolve, 500));
    return fauxAssistantMessage('terminal during consumed admission');
  },
]);
await waitFor(() => state().request?.status === 'claimed', 'consumed admission claim did not begin');
await runtime.session.prompt('race a consumed admission', { source: 'interactive' });
await waitFor(() => state().request?.status === 'queued', 'later-handler-consumed admission was not released');
globalThis.__telegramMirrorHandleExtensionInput = false;
current = state();
current.request = null;
save(current);
assert.equal(userTexts(initialManager).some((text) => text.includes('handled by later extension')), false);
assert.equal(current.receipts?.includes('tg-text-u12-m12') ?? false, false);

const competing = state();
competing.request = { id: 'tg-text-u9-m9', text: 'paired Telegram request', status: 'queued' };
save(competing);
globalThis.__telegramMirrorInjectOperational = true;
faux.appendResponses([
  (context) => {
    assert.match(context.systemPrompt + JSON.stringify(context.messages), /authenticated Telegram mirror/);
    return fauxAssistantMessage([
      fauxThinking('private Telegram reasoning'),
      fauxToolCall('mirror_test_tool', {}, { id: 'mirror-test-tool-call' }),
    ], { stopReason: 'toolUse' });
  },
  (context) => {
    assert.match(JSON.stringify(context.messages), /tool diagnostic payload/);
    return fauxAssistantMessage('paired answer');
  },
  (context) => {
    const operational = context.messages.findLast((message) => message.role === 'custom');
    assert.equal(operational.content, 'operational follow-up');
    return fauxAssistantMessage('operational answer');
  },
]);
await waitFor(() => state().handled?.includes('tg-text-u9-m9'), 'competing extension turn prevented Telegram settlement');
await waitFor(() => initialManager.getEntries().some((entry) =>
  entry.type === 'custom_message' && entry.content === 'operational follow-up'),
'competing custom operational continuation did not execute');
current = state();
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · paired answer').length, 1);
assert.equal(Object.values(current.deliveries).some((body) => body.includes('operational answer')), false);
assert.equal(Object.values(current.deliveries).some((body) => body.includes('private Telegram reasoning')), false);
assert.equal(Object.values(current.deliveries).some((body) => body.includes('tool diagnostic payload')), false);
globalThis.__telegramMirrorInjectOperational = false;

const voice = state();
voice.request = { id: 'tg-voice-u10-m10', text: 'confirmed voice text', status: 'queued' };
save(voice);
faux.appendResponses([fauxAssistantMessage('confirmed voice answer')]);
await waitFor(() => state().handled?.includes('tg-voice-u10-m10'), 'confirmed voice queue did not become a Pi turn');
current = state();
assert.equal(userTexts(initialManager).filter((text) => text === 'You · Telegram\n\nconfirmed voice text').length, 1);
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · confirmed voice answer').length, 1);
assert.equal(current.receipts.filter((id) => id === 'tg-voice-u10-m10').length, 1);

const failedTurn = state();
failedTurn.request = { id: 'tg-text-u11-m11', text: 'provider failure request', status: 'queued' };
save(failedTurn);
const callsBeforeFailure = faux.state.callCount;
faux.appendResponses([
  fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'provider failed' }),
]);
await waitFor(() => initialManager.getEntries().some((entry) =>
  entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission'
    && entry.data.requestId === 'tg-text-u11-m11' && entry.data.state === 'interrupted'),
'provider failure did not persist an interrupted admission');
await new Promise((resolve) => setTimeout(resolve, 300));
current = state();
assert.equal(current.request?.status, 'held', 'provider failure did not bound its interrupted request');
assert.equal(faux.state.callCount, callsBeforeFailure + 1, 'provider failure hot-looped another model turn');
assert.equal(userTexts(initialManager).filter((text) => text.includes('provider failure request')).length, 1);
current.next_request = { id: 'tg-text-u13-m13', text: 'must remain queued' };
save(current);
await new Promise((resolve) => setTimeout(resolve, 300));
assert.equal(state().log.some((call) => call[0] === 'mirror-claim' && call[1] === 'tg-text-u13-m13'), false,
  'held provider failure admitted another Telegram request');
faux.appendResponses([fauxAssistantMessage('terminal after interrupted answer')]);
await runtime.session.prompt('terminal after interrupted Telegram', { source: 'interactive' });
current = state();
assert.equal(current.request?.status, 'held', 'terminal turn released the interrupted Telegram hold');
assert.equal(Object.values(current.deliveries).filter((body) =>
  body === 'You · Terminal\n\nterminal after interrupted Telegram').length, 1);
assert.equal(Object.values(current.deliveries).filter((body) =>
  body === 'Firstmate · terminal after interrupted answer').length, 1);
current.next_request = null;
save(current);
faux.appendResponses([fauxAssistantMessage('explicit provider recovery answer')]);
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await waitFor(() => state().handled?.includes('tg-text-u11-m11'), 'explicit mode-on recovery did not settle the held request');

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
initialManager.appendMessage({
  role: 'user', content: [{ type: 'text', text: 'operational after represented admission' }], timestamp: Date.now(),
});
initialManager.appendMessage(fauxAssistantMessage('later operational answer'));
const previousFile = initialManager.getSessionFile();
await runtime.newSession({ parentSession: previousFile });
await waitFor(() => state().handled?.includes('tg-text-u2-m2'), 'session replacement did not reconcile persisted admission provenance');
assert.equal(userTexts(runtime.session.sessionManager).length, 0, 'session replacement reinjected represented Telegram input');
assert.equal(Object.values(state().deliveries).filter((body) => body === 'Firstmate · replacement answer').length, 1);
assert.equal(Object.values(state().deliveries).some((body) => body.includes('later operational answer')), false);

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
faux.appendResponses([
  (context) => {
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.equal(user.content.map((part) => part.text || '').join(''), 'ordinary non-primary terminal');
    return fauxAssistantMessage('ordinary non-primary answer');
  },
]);
const nonPrimaryDeliveries = Object.keys(state().deliveries).length;
await runtime.session.prompt('ordinary non-primary terminal', { source: 'interactive' });
assert.equal(Object.keys(state().deliveries).length, nonPrimaryDeliveries, 'non-primary terminal turn was mirrored');

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
  "$TMP_ROOT/competing-extension.ts" "$TMP_ROOT/handling-extension.ts" \
  "$home" "$agent_dir" "$session_dir" "$TMP_ROOT/fake-transport.py" "$TMP_ROOT/lock-lib.sh"
