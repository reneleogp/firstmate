#!/usr/bin/env bash
# Installed Pi runtime regression against the tracked extension and an executable fake transport.
set -u

if [ "${FM_TELEGRAM_MIRROR_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_TELEGRAM_MIRROR_LIVE_E2E=1 to run the installed Pi Telegram mirror regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram-mirror-live)
VOICE_SERVER_PID=
cleanup() {
  [ -z "$VOICE_SERVER_PID" ] || kill "$VOICE_SERVER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT
home="$TMP_ROOT/home"
agent_dir="$TMP_ROOT/agent"
session_dir="$TMP_ROOT/sessions"
override_config="$TMP_ROOT/override-config"
mkdir -p "$home/config" "$home/state" "$agent_dir" "$session_dir" "$override_config"
printf 'on\n' >"$home/config/telegram-mirror"
printf 'off\n' >"$override_config/telegram-mirror"
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
state.setdefault('reservations', {})
state.setdefault('log', []).append([command, *rest])
def save():
    temporary = path.with_name(f'.{path.name}.{os.getpid()}')
    temporary.write_text(json.dumps(state)); os.replace(temporary, path)
def option(name):
    return rest[rest.index(name) + 1] if name in rest else None
def options(name):
    return [rest[index + 1] for index, value in enumerate(rest[:-1]) if value == name]
def mode_path():
    return home / 'config' / 'telegram-mirror'
code = 0
skip_final_save = False
if command == 'mirror-open':
    pass
elif command == 'mirror-reconcile':
    state['legacy_wake'] = False
    request = state.get('request')
    preserved = options('--preserve-request')
    if request and request.get('status') == 'held' and state.pop('expire_held', False):
        state['request'] = None; request = None
    if request and request.get('status') == 'claimed':
        if request.get('id') in preserved:
            request['status'] = 'claimed'; request['owner'] = int(option('--owner-pid'))
            print(f"owned\t{request['id']}")
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
    elif mode_path().read_text().strip() != 'on': code = 1
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
elif command == 'mirror-reserve':
    delivery_id = rest[0]
    body = sys.stdin.read() if option('--text-file') == '-' else Path(option('--text-file')).read_text()
    if (mode_path().read_text().strip() != 'on' and '--accepted-input' not in rest): code = 1
    elif (home / 'reject-user-reserve').exists(): code = 1
    elif delivery_id in state['reservations'] and state['reservations'][delivery_id] != body: code = 1
    elif delivery_id in state['deliveries'] and state['deliveries'][delivery_id] != body: code = 1
    else: state['reservations'][delivery_id] = body
elif command == 'mirror-cancel':
    state['reservations'].pop(rest[0], None)
elif command == 'mirror-delivered':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'claimed': code = 1
    elif rest[0] not in state.setdefault('receipts', []): state['receipts'].append(rest[0])
elif command == 'mirror-reply':
    delivery_id = rest[0]
    body = sys.stdin.read() if option('--text-file') == '-' else Path(option('--text-file')).read_text()
    reservation = state['reservations'].get(delivery_id)
    if reservation is not None and reservation != body: code = 1
    if (home / 'reject-mirror-reply').exists(): code = 1
    if (home / 'reject-user-reply').exists() and body.startswith('You · Terminal'): code = 1
    if (home / 'reject-assistant-reply').exists() and body.startswith('Firstmate ·'): code = 1
    existing = state['deliveries'].get(delivery_id)
    if code == 0 and existing is not None and existing != body: code = 1
    elif code == 0:
        state['deliveries'][delivery_id] = body
        state['reservations'].pop(delivery_id, None)
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
    preference_path = mode_path()
    if action == 'status': print(preference_path.read_text().strip())
    else:
        preference_path.write_text(action + '\n'); print('Pi · Telegram mirror mode is ' + action + '.')
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
  pi.on("input", async (event) => {
    const state = globalThis as typeof globalThis & {
      __telegramMirrorHandleExtensionInput?: boolean;
      __telegramMirrorHandleInteractiveInput?: boolean;
      __telegramMirrorDelayInteractiveInput?: boolean;
    };
    if (state.__telegramMirrorDelayInteractiveInput && event.source === "interactive") {
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (state.__telegramMirrorHandleExtensionInput && event.source === "extension") {
      return { action: "handled" as const };
    }
    if (state.__telegramMirrorHandleInteractiveInput && event.source === "interactive") {
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
const statuses = [];
const notices = [];
const uiContext = {
  setStatus(key, value) { statuses.push([key, value]); },
  notify(message, level) { notices.push([message, level]); },
};
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
assert.ok(idleScans >= 1 && idleScans <= 3, `idle scan duplicated queue probes: ${idleScans}`);
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

writeFileSync(`${home}/reject-user-reserve`, '');
const callsBeforeRejectedTerminal = faux.state.callCount;
faux.appendResponses([fauxAssistantMessage('answer after accepted reservation block')]);
await runtime.session.prompt('terminal reservation rejection', { source: 'interactive' });
await waitFor(() => statuses.at(-1)?.[1] === 'telegram: delivery needs attention',
  'accepted terminal reservation failure was not retained');
unlinkSync(`${home}/reject-user-reserve`);
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await waitFor(() => Object.values(state().deliveries)
  .some((body) => body === 'Firstmate · answer after accepted reservation block'),
'accepted terminal reservation failure did not settle after retry');
assert.equal(faux.state.callCount, callsBeforeRejectedTerminal + 1,
  'terminal reservation recovery invoked another model turn');

writeFileSync(`${home}/reject-user-reply`, '');
faux.appendResponses([fauxAssistantMessage('answer after accepted user delivery block')]);
await runtime.session.prompt('accepted terminal delivery block', { source: 'interactive' });
await waitFor(() => statuses.at(-1)?.[1] === 'telegram: delivery needs attention',
  'accepted terminal user delivery failure was not retained');
const callsAfterAcceptedUserBlock = faux.state.callCount;
unlinkSync(`${home}/reject-user-reply`);
await runtime.session.prompt('/telegram off', { source: 'interactive' });
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await waitFor(() => Object.values(state().deliveries)
  .some((body) => body === 'Firstmate · answer after accepted user delivery block'),
'accepted terminal pair did not settle after user delivery retry');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\naccepted terminal delivery block').length, 1);
assert.equal(faux.state.callCount, callsAfterAcceptedUserBlock,
  'accepted terminal delivery retry invoked the model');

writeFileSync(`${home}/reject-user-reply`, '');
globalThis.__telegramMirrorDelayInteractiveInput = true;
const callsBeforeQueuedUserBlock = faux.state.callCount;
faux.appendResponses([
  fauxAssistantMessage('queued user block A answer'),
  fauxAssistantMessage('queued user block B answer'),
]);
const queuedUserBlockA = runtime.session.prompt('queued user block A', { source: 'interactive' });
const queuedUserBlockB = runtime.session.prompt('queued user block B', {
  source: 'interactive', streamingBehavior: 'followUp',
});
await Promise.all([queuedUserBlockA, queuedUserBlockB]);
globalThis.__telegramMirrorDelayInteractiveInput = false;
await waitFor(() => statuses.at(-1)?.[1] === 'telegram: delivery needs attention',
  'queued terminal user delivery failure did not pause ordered settlement');
unlinkSync(`${home}/reject-user-reply`);
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await waitFor(() => Object.values(state().deliveries)
  .some((body) => body === 'Firstmate · queued user block B answer'),
'queued terminal B did not settle after A user delivery recovered');
const queuedBodies = Object.values(state().deliveries);
assert.equal(queuedBodies.filter((body) => body === 'You · Terminal\n\nqueued user block A').length, 1);
assert.equal(queuedBodies.filter((body) => body === 'Firstmate · queued user block A answer').length, 1);
assert.equal(queuedBodies.filter((body) => body === 'You · Terminal\n\nqueued user block B').length, 1);
assert.equal(queuedBodies.filter((body) => body === 'Firstmate · queued user block B answer').length, 1);
assert.equal(faux.state.callCount, callsBeforeQueuedUserBlock + 2,
  'queued terminal delivery recovery invoked another model turn');

faux.appendResponses([
  (context) => {
    assert.doesNotMatch(context.systemPrompt, /authenticated Telegram mirror/);
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.match(user.content.map((part) => part.text || '').join(''), /^You · Terminal/);
    return fauxAssistantMessage([fauxText('terminal'), fauxText('answer')]);
  },
]);
await runtime.session.prompt('terminal request', { source: 'interactive' });
current = state();
assert.equal(Object.values(current.deliveries).filter((body) => body === 'You · Terminal\n\nterminal request').length, 1);
assert.equal(Object.values(current.deliveries).filter((body) => body === 'Firstmate · terminal\nanswer').length, 1);

const usersBeforeHandledTerminal = userTexts(initialManager).length;
const callsBeforeHandledTerminal = faux.state.callCount;
const reservationsBeforeHandledFlood = Object.keys(state().reservations).length;
globalThis.__telegramMirrorHandleInteractiveInput = true;
for (let index = 0; index < 260; index += 1) {
  await runtime.session.prompt(`handled terminal candidate ${index}`, { source: 'interactive' });
}
globalThis.__telegramMirrorHandleInteractiveInput = false;
assert.equal(userTexts(initialManager).length, usersBeforeHandledTerminal,
  'later handler did not consume terminal inputs');
assert.equal(faux.state.callCount, callsBeforeHandledTerminal,
  'later-handler-consumed terminal inputs started a model turn');
assert.equal(Object.keys(state().reservations).length, reservationsBeforeHandledFlood,
  'consumed terminal inputs used bounded Python delivery capacity');
faux.appendResponses([fauxAssistantMessage('valid turn after handled flood')]);
await runtime.session.prompt('valid terminal after handled flood', { source: 'interactive' });
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\nvalid terminal after handled flood').length, 1);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · valid turn after handled flood').length, 1);

faux.appendResponses([fauxAssistantMessage('long preflight answer')]);
globalThis.__telegramMirrorDelayInteractiveInput = true;
const callsBeforeLongPreflight = faux.state.callCount;
const longPreflight = runtime.session.prompt('long preflight terminal', { source: 'interactive' });
await new Promise((resolve) => setTimeout(resolve, 250));
assert.equal(Object.values(state().reservations)
  .filter((body) => body === 'You · Terminal\n\nlong preflight terminal').length, 0,
  'long input preflight reserved Python delivery capacity before acceptance');
assert.equal(Object.values(state().deliveries)
  .some((body) => body === 'You · Terminal\n\nlong preflight terminal'), false,
  'terminal input was delivered before Pi accepted it');
assert.equal(faux.state.callCount, callsBeforeLongPreflight,
  'long input preflight started the model before acceptance');
await longPreflight;
globalThis.__telegramMirrorDelayInteractiveInput = false;
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\nlong preflight terminal').length, 1);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · long preflight answer').length, 1);

writeFileSync(`${home}/reject-assistant-reply`, '');
faux.appendResponses([fauxAssistantMessage('blocked terminal answer')]);
await runtime.session.prompt('terminal with blocked assistant', { source: 'interactive' });
await waitFor(() => statuses.at(-1)?.[1] === 'telegram: delivery needs attention',
  'accepted terminal turn did not retain its blocked assistant response');
const callsAfterTerminalBlock = faux.state.callCount;
unlinkSync(`${home}/reject-assistant-reply`);
await runtime.session.prompt('/telegram off', { source: 'interactive' });
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await waitFor(() => Object.values(state().deliveries)
  .some((body) => body === 'Firstmate · blocked terminal answer'),
'blocked terminal assistant response was not retried');
assert.equal(faux.state.callCount, callsAfterTerminalBlock,
  'blocked terminal assistant retry invoked the model');
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('terminal with blocked assistant')).length, 1);

writeFileSync(`${home}/reject-assistant-reply`, '');
const callsBeforeOrderedBlock = faux.state.callCount;
faux.appendResponses([
  async () => {
    await new Promise((resolve) => setTimeout(resolve, 150));
    return fauxAssistantMessage('ordered blocked A answer');
  },
  fauxAssistantMessage('ordered finalized B answer'),
]);
const orderedA = runtime.session.prompt('ordered blocked A', { source: 'interactive' });
await waitFor(() => userTexts(initialManager).some((text) => text.includes('ordered blocked A')),
  'ordered blocked A did not start');
await runtime.session.prompt('ordered finalized B', {
  source: 'interactive', streamingBehavior: 'followUp',
});
await orderedA;
await waitFor(() => statuses.at(-1)?.[1] === 'telegram: delivery needs attention',
  'ordered blocked A did not stop settlement before finalized B');
unlinkSync(`${home}/reject-assistant-reply`);
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await waitFor(() => Object.values(state().deliveries)
  .some((body) => body === 'Firstmate · ordered finalized B answer'),
'finalized B did not settle immediately after blocked A recovered');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · ordered blocked A answer').length, 1);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · ordered finalized B answer').length, 1);
assert.equal(faux.state.callCount, callsBeforeOrderedBlock + 2,
  'ordered blocked delivery recovery invoked an extra model pass');

faux.appendResponses([
  async () => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    return fauxAssistantMessage('off during accepted turn answer');
  },
]);
const callsBeforeOffDuringTurn = faux.state.callCount;
const offDuringTurn = runtime.session.prompt('off during accepted terminal turn', { source: 'interactive' });
await waitFor(() => userTexts(initialManager)
  .some((text) => text.includes('off during accepted terminal turn')),
'accepted terminal turn did not start before mode-off command');
await runtime.session.prompt('/telegram off', { source: 'interactive' });
await offDuringTurn;
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\noff during accepted terminal turn').length, 1);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · off during accepted turn answer').length, 1);
assert.equal(faux.state.callCount, callsBeforeOffDuringTurn + 1,
  'mode-off during an accepted turn started a second model pass');
await runtime.session.prompt('/telegram on', { source: 'interactive' });

current = state();
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

const expiringHold = state();
expiringHold.request = { id: 'tg-text-u15-m15', text: 'expiring provider failure', status: 'queued' };
save(expiringHold);
faux.appendResponses([fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'provider failed' })]);
await waitFor(() => state().request?.status === 'held', 'second provider failure was not held');
const expiringHeldState = state();
expiringHeldState.expire_held = true;
save(expiringHeldState);
await waitFor(() => state().request === null, 'expired interrupted admission was preserved by reconciliation');
const callsAfterHeldExpiry = faux.state.callCount;
await new Promise((resolve) => setTimeout(resolve, 800));
assert.equal(faux.state.callCount, callsAfterHeldExpiry, 'expired interrupted admission was reinjected');

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

const expiredManager = runtime.session.sessionManager;
const expiredTurn = 'telegram-tg-text-u16-m16-expired';
expiredManager.appendCustomEntry('firstmate-telegram-admission', {
  requestId: 'tg-text-u16-m16', turnId: expiredTurn,
  sessionId: expiredManager.getSessionId(), state: 'admitted',
});
expiredManager.appendMessage({
  role: 'user', content: [{ type: 'text', text: 'You · Telegram\n\nexpired historical request' }], timestamp: Date.now(),
});
expiredManager.appendMessage(fauxAssistantMessage('expired historical answer'));
const deliveriesBeforeExpiredResume = Object.keys(state().deliveries).length;
await runtime.newSession({ parentSession: expiredManager.getSessionFile() });
await new Promise((resolve) => setTimeout(resolve, 300));
assert.equal(Object.keys(state().deliveries).length, deliveriesBeforeExpiredResume,
  'expired persisted response was replayed without an owned transport request');

const crash = state();
crash.request = { id: 'tg-text-u3-m3', text: 'accepted without persistence', status: 'claimed', owner: process.pid };
save(crash);
faux.appendResponses([fauxAssistantMessage('crash retry answer')]);
await runtime.newSession({ parentSession: runtime.session.sessionFile });
await waitFor(() => state().handled?.includes('tg-text-u3-m3'), 'unpersisted accepted claim was not eligible for bounded reinjection');
assert.equal(userTexts(runtime.session.sessionManager).filter((text) => text.includes('accepted without persistence')).length, 1);

const blocked = state();
blocked.request = { id: 'tg-text-u17-m17', text: 'delivery block request', status: 'queued' };
save(blocked);
writeFileSync(`${home}/reject-mirror-reply`, '');
faux.appendResponses([fauxAssistantMessage('blocked delivery answer')]);
await waitFor(() => state().log.some((call) =>
  call[0] === 'mirror-reply' && call[1].startsWith('assistant-telegram-tg-text-u17-m17-')),
'assistant delivery failure was not attempted');
await waitFor(() => statuses.at(-1)?.[1] === 'telegram: delivery needs attention',
  'assistant delivery failure was not surfaced');
const usersBeforeBlockedPrompt = userTexts(runtime.session.sessionManager).length;
const callsBeforeBlockedPrompt = faux.state.callCount;
await runtime.session.prompt('must be refused while mirror delivery is blocked', { source: 'interactive' });
assert.equal(userTexts(runtime.session.sessionManager).length, usersBeforeBlockedPrompt,
  'blocked mirror silently admitted an ordinary terminal turn');
assert.equal(faux.state.callCount, callsBeforeBlockedPrompt, 'blocked mirror terminal input started a model turn');
assert.equal(notices.some(([message]) => message.includes('use /telegram off before continuing')), true);
const blockedUserTurns = userTexts(runtime.session.sessionManager)
  .filter((text) => text.includes('delivery block request')).length;
const modelCallsAfterBlockedResponse = faux.state.callCount;
unlinkSync(`${home}/reject-mirror-reply`);
await runtime.session.prompt('/telegram off', { source: 'interactive' });
faux.appendResponses([fauxAssistantMessage('ordinary answer after mirror off')]);
await runtime.session.prompt('ordinary after delivery block off', { source: 'interactive' });
assert.equal(userTexts(runtime.session.sessionManager).at(-1), 'ordinary after delivery block off');
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await waitFor(() => state().handled?.includes('tg-text-u17-m17'),
  'blocked settled response did not retry transport delivery after mode on');
assert.equal(userTexts(runtime.session.sessionManager)
  .filter((text) => text.includes('delivery block request')).length, blockedUserTurns,
  'blocked Telegram request started a second Pi turn after mode off/on');
assert.equal(faux.state.callCount, modelCallsAfterBlockedResponse + 1,
  'blocked Telegram response transport retry invoked the model');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · blocked delivery answer').length, 1);
const blockedDeliveryCalls = state().log.filter((call) =>
  call[0] === 'mirror-reply' && call[1].startsWith('assistant-telegram-tg-text-u17-m17-'));
assert.equal(blockedDeliveryCalls.length, 2);
assert.equal(new Set(blockedDeliveryCalls.map((call) => call[1])).size, 1,
  'blocked response retry changed its stable delivery identity');

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
writeFileSync(`${home}/config/telegram-mirror`, 'on\n');
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
FM_CONFIG_OVERRIDE="$override_config" node "$TMP_ROOT/runtime.mjs" \
  "$sdk_path" "$ai_path" "$ROOT" "$ROOT/.pi/extensions/fm-telegram-mirror.ts" \
  "$TMP_ROOT/competing-extension.ts" "$TMP_ROOT/handling-extension.ts" \
  "$home" "$agent_dir" "$session_dir" "$TMP_ROOT/fake-transport.py" "$TMP_ROOT/lock-lib.sh" \
  || fail "installed Pi fake-transport mirror regression failed"

voice_home="$TMP_ROOT/voice-home"
voice_agent_dir="$TMP_ROOT/voice-agent"
voice_session_dir="$TMP_ROOT/voice-sessions"
mkdir -p "$voice_home" "$voice_agent_dir" "$voice_session_dir"
printf 'FM_TELEGRAM_BOT_TOKEN=test-only-token\n' >"$voice_home/.env"
chmod 600 "$voice_home/.env"
printf '[]\n' >"$voice_home/updates.json"
python3 - "$voice_home" <<'PY' &
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
home = Path(sys.argv[1])
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def reply(self, value):
        body = json.dumps({'ok': True, 'result': value}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        params = json.loads(self.rfile.read(size) or b'{}')
        with (home / 'calls.jsonl').open('a') as stream:
            stream.write(json.dumps({'path': self.path, 'params': params}) + '\n')
        method = self.path.rsplit('/', 1)[-1]
        if method == 'getMe': return self.reply({'id': 9901, 'is_bot': True})
        if method == 'getChat': return self.reply({'id': params.get('chat_id'), 'type': 'private'})
        if method == 'getFile': return self.reply({'file_path': 'voice/test.oga'})
        if method == 'getUpdates':
            updates = json.loads((home / 'updates.json').read_text())
            (home / 'updates.json').write_text('[]')
            return self.reply(updates)
        return self.reply({})
    def do_GET(self):
        if '/file/' in self.path:
            body = b'fake voice'
            self.send_response(200); self.send_header('Content-Length', str(len(body)))
            self.end_headers(); self.wfile.write(body); return
        self.send_response(404); self.end_headers()
server = HTTPServer(('127.0.0.1', 0), Handler)
(home / 'port').write_text(str(server.server_port))
(home / 'server.pid').write_text(str(os.getpid()))
server.serve_forever()
PY
VOICE_SERVER_PID=$!
for _ in $(seq 1 100); do [ -s "$voice_home/port" ] && break; sleep .02; done
[ -s "$voice_home/port" ] || fail "voice integration Telegram server did not start"
voice_api="http://127.0.0.1:$(cat "$voice_home/port")"
real_transport="$ROOT/bin/fm-telegram.py"
export FM_TELEGRAM_UNIT_DIR="$TMP_ROOT/systemd-user"
run_voice_transport() {
  FM_HOME="$voice_home" FM_TELEGRAM_TEST_API_BASE="$voice_api" "$real_transport" "$@"
}
run_voice_transport pair --user-id 77 --chat-id 77 >/dev/null \
  || fail "voice integration pairing failed"
printf '[{"update_id":1,"message":{"message_id":1,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"text":"/telegram on"}}]\n' >"$voice_home/updates.json"
run_voice_transport serve --once >/dev/null \
  || fail "voice integration mode command failed"
cat >"$voice_home/transcribe.sh" <<'SH'
#!/usr/bin/env bash
printf 'confirmed voice through Python\n'
SH
chmod +x "$voice_home/transcribe.sh"
python3 - "$voice_home/config/telegram.json" "$voice_home/transcribe.sh" <<'PY'
import json, os, sys
path, command = sys.argv[1:]
data = json.load(open(path)); data['parakeet_command'] = command; data['whisper_command'] = command
json.dump(data, open(path, 'w')); os.chmod(path, 0o600)
PY
printf '[{"update_id":2,"message":{"message_id":2,"date":1,"from":{"id":77},"chat":{"id":77,"type":"private"},"voice":{"file_id":"voice-2","duration":2,"file_size":10}}}]\n' >"$voice_home/updates.json"
run_voice_transport serve --once >/dev/null \
  || fail "voice integration transcription failed"
printf '[{"update_id":3,"callback_query":{"id":"voice-confirm","from":{"id":77},"message":{"message_id":20,"date":1,"chat":{"id":77,"type":"private"},"text":"confirmed voice through Python"},"data":"send:voice-u2-m2:1"}}]\n' >"$voice_home/updates.json"
run_voice_transport serve --once >/dev/null \
  || fail "voice integration confirmation failed"
[ -f "$voice_home/state/telegram/inbox/tg-voice-u2-m2.json" ] \
  || fail "real Python confirmed voice Send did not queue a mirror request"

cat >"$TMP_ROOT/voice-runtime.mjs" <<'JS'
import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const [sdkPath, aiPath, extensionPath, home, agentDir, sessionDir, transport, lockLib, api] = process.argv.slice(2);
process.env.FM_HOME = home;
process.env.FM_CONFIG_OVERRIDE = `${home}/config`;
process.env.FM_TELEGRAM_TRANSPORT = transport;
process.env.FM_TELEGRAM_SESSION_LOCK_LIB = lockLib;
process.env.FM_TELEGRAM_TEST_API_BASE = api;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
writeFileSync(`${home}/state/.primary`, '');
const {
  ModelRuntime, SessionManager, SettingsManager,
  createAgentSessionFromServices, createAgentSessionRuntime, createAgentSessionServices,
} = await import(pathToFileURL(sdkPath).href);
const { fauxAssistantMessage, fauxProvider } = await import(pathToFileURL(aiPath).href);
const faux = fauxProvider({ tokensPerSecond: 100000 });
const modelRuntime = await ModelRuntime.create({
  authPath: `${agentDir}/auth.json`, modelsPath: null,
  modelsStorePath: `${agentDir}/models-store.json`, refreshOnCreate: false,
});
modelRuntime.registerNativeProvider(faux.provider);
faux.setResponses([fauxAssistantMessage('confirmed voice settled answer')]);
const createRuntime = async ({ cwd, sessionManager, sessionStartEvent }) => {
  const services = await createAgentSessionServices({
    cwd, agentDir, modelRuntime,
    settingsManager: SettingsManager.inMemory({
      compaction: { enabled: false }, retry: { enabled: false }, defaultTools: [],
    }),
    resourceLoaderOptions: { additionalExtensionPaths: [extensionPath] },
  });
  const result = await createAgentSessionFromServices({
    services, sessionManager, sessionStartEvent, model: faux.getModel(),
    thinkingLevel: 'off', noTools: 'all',
  });
  return { ...result, services, diagnostics: services.diagnostics };
};
const manager = SessionManager.create(home, sessionDir);
const runtime = await createAgentSessionRuntime(createRuntime, {
  cwd: home, agentDir, sessionManager: manager,
});
await runtime.session.bindExtensions({
  mode: 'json', uiContext: { setStatus() {}, notify() {} },
});
for (let attempt = 0; attempt < 200; attempt += 1) {
  if (existsSync(`${home}/state/telegram/handled/tg-voice-u2-m2.json`) &&
      manager.getEntries().some((entry) => entry.type === 'custom' &&
        entry.customType === 'firstmate-telegram-admission' && entry.data.state === 'completed')) break;
  await new Promise((resolve) => setTimeout(resolve, 25));
}
assert.equal(manager.getEntries().filter((entry) => entry.type === 'message' &&
  entry.message.role === 'user' && entry.message.content.some?.((part) =>
    part.text === 'You · Telegram\n\nconfirmed voice through Python')).length, 1);
const handled = JSON.parse(readFileSync(`${home}/state/telegram/handled/tg-voice-u2-m2.json`, 'utf8'));
assert.equal(handled.status, 'handled');
const calls = readFileSync(`${home}/calls.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
assert.equal(calls.filter((call) => call.path.endsWith('/sendMessage') &&
  call.params.text === 'Firstmate · confirmed voice settled answer').length, 1);
await runtime.dispose();
console.log('pass: confirmed voice Send traversed real Python transport and tracked Pi extension');
JS
node "$TMP_ROOT/voice-runtime.mjs" \
  "$sdk_path" "$ai_path" "$ROOT/.pi/extensions/fm-telegram-mirror.ts" \
  "$voice_home" "$voice_agent_dir" "$voice_session_dir" "$real_transport" \
  "$TMP_ROOT/lock-lib.sh" "$voice_api" \
  || fail "real Python confirmed-voice extension regression failed"
