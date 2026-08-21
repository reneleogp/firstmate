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
mkdir -p "$home/config" "$home/state" "$agent_dir/prompts" "$session_dir" "$override_config"
printf '%s\n' 'Expanded slash prompt body' >"$agent_dir/prompts/slash-mirror.md"
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
if command == 'mirror-validate' and (home / 'delay-mirror-validate').exists():
    time.sleep(0.5)
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
state.setdefault('delivery_records', {})
state.setdefault('completion_requests', {})
state.setdefault('represented_requests', {})
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
force_reconcile_failure = False
if command == 'mirror-reconcile' and (home / 'fail-next-reconcile').exists():
    (home / 'fail-next-reconcile').unlink()
    force_reconcile_failure = True
if command == 'mirror-reconcile' and (home / 'reject-mirror-reconcile').exists():
    force_reconcile_failure = True
if force_reconcile_failure:
    code = 1
elif command == 'mirror-open':
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
    for request_id, represented in state['represented_requests'].items():
        if represented.get('status') != 'claimed':
            continue
        if request_id in preserved:
            represented['owner'] = int(option('--owner-pid'))
            print(f"owned\t{request_id}")
        else:
            represented['status'] = 'queued'
            represented.pop('owner', None)
    expired_deliveries = set(state.pop('expire_deliveries', []))
    for delivery_id in expired_deliveries:
        status = state['delivery_records'].pop(delivery_id, None)
        request_id = state['completion_requests'].pop(delivery_id, None)
        state['deliveries'].pop(delivery_id, None)
        state['reservations'].pop(delivery_id, None)
        request = state.get('request')
        if (status in ('rejected', 'delivery_unknown') and request_id and request
                and request.get('id') == request_id and request.get('status') == 'claimed'):
            state['request'] = None
    for delivery_id in options('--report-delivery'):
        status = state['delivery_records'].get(delivery_id)
        if status is None: print(f"delivery-missing\t{delivery_id}")
        else: print(f"delivery\t{delivery_id}\t{status}")
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
    if (home / 'reject-mirror-hold').exists(): code = 1
    elif not request or request.get('id') != rest[0] or request.get('status') not in ('claimed', 'held'): code = 1
    else:
        request['status'] = 'held'; request['turn_id'] = rest[1]; request.pop('owner', None)
elif command == 'mirror-recover':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'held': code = 1
    else:
        request['status'] = 'queued'; request.pop('turn_id', None)
elif command == 'mirror-validate':
    body = sys.stdin.read() if option('--text-file') == '-' else Path(option('--text-file')).read_text()
    units = sum(2 if ord(character) > 0xffff else 1 for character in body)
    chunks = (units + 4095) // 4096
    if (not body or len(body.encode()) > 256 * 1024 or chunks > 64
            or ((home / 'reject-assistant-validation').exists()
                and body.startswith('Firstmate ·'))): code = 1
elif command == 'mirror-reserve':
    delivery_id = rest[0]
    body = sys.stdin.read() if option('--text-file') == '-' else Path(option('--text-file')).read_text()
    if (mode_path().read_text().strip() != 'on' and '--accepted-input' not in rest): code = 1
    elif (home / 'reject-user-reserve').exists(): code = 1
    elif delivery_id in state['reservations'] and state['reservations'][delivery_id] != body: code = 1
    elif delivery_id in state['deliveries'] and state['deliveries'][delivery_id] != body: code = 1
    else:
        state['reservations'][delivery_id] = body
        state['delivery_records'][delivery_id] = 'reserved'
elif command == 'mirror-cancel':
    state['reservations'].pop(rest[0], None)
    state['delivery_records'].pop(rest[0], None)
elif command == 'mirror-delivered':
    request = state.get('request')
    if not request or request.get('id') != rest[0] or request.get('status') != 'claimed': code = 1
    elif (home / 'reject-delivered-receipt').exists():
        state.setdefault('receipt_unknown', []).append(rest[0]); code = 1
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
    state['delivery_records'][delivery_id] = 'rejected' if code != 0 else 'sent'
    request_id = option('--request-id')
    if request_id is not None: state['completion_requests'][delivery_id] = request_id
    if code == 0:
        state['deliveries'][delivery_id] = body
        state['reservations'].pop(delivery_id, None)
        if (home / 'exercise-reply-timeout').exists():
            time.sleep(0.05)
        if body == 'Firstmate · slow settlement A answer' and (home / 'delay-assistant-reply').exists():
            save(); skip_final_save = True
            fcntl.flock(lock, fcntl.LOCK_UN)
            (home / 'assistant-reply-delayed').touch()
            time.sleep(0.6)
            (home / 'assistant-reply-delayed').unlink(missing_ok=True)
elif command == 'mirror-abandon':
    request_id, delivery_id = rest[:2]
    request = state.get('request')
    represented = state['represented_requests'].get(request_id)
    if (home / 'reject-mirror-abandon').exists():
        code = 1
    elif request and request.get('id') == request_id and request.get('status') == 'claimed':
        state.setdefault('handled', []).append(request_id)
        state.setdefault('abandoned', []).append([request_id, delivery_id])
        state['request'] = None
        state['completion_requests'].pop(delivery_id, None)
    elif represented and represented.get('status') == 'claimed':
        state.setdefault('handled', []).append(request_id)
        state.setdefault('abandoned', []).append([request_id, delivery_id])
        del state['represented_requests'][request_id]
    elif request is not None or represented is not None:
        code = 1
elif command == 'mirror-complete':
    request_id, delivery_id = rest[:2]
    request = state.get('request')
    if (not request or request.get('id') != request_id
            or delivery_id not in state['deliveries'] or request.get('status') != 'claimed'):
        code = 1
    else:
        state.setdefault('handled', []).append(request_id); state['request'] = None
        state['completion_requests'].pop(delivery_id, None)
elif command == 'mirror-mode':
    action = rest[0]
    preference_path = mode_path()
    if action == 'status' and (home / 'fail-mode-read').exists(): code = 1
    elif action == 'status': print(preference_path.read_text().strip())
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
  const state = globalThis as typeof globalThis & {
    __telegramMirrorSendOtherExtension?: () => void;
  };
  state.__telegramMirrorSendOtherExtension = () => {
    pi.sendUserMessage("other extension competing segment", { deliverAs: "steer" });
  };
  pi.registerTool({
    name: "mirror_test_tool",
    label: "Mirror test tool",
    description: "Return a diagnostic payload for structural mirror exclusion coverage",
    parameters: Type.Object({}),
    async execute() {
      const state = globalThis as typeof globalThis & {
        __telegramMirrorHoldTool?: boolean;
        __telegramMirrorToolStarted?: boolean;
        __telegramMirrorTerminateTool?: boolean;
      };
      state.__telegramMirrorToolStarted = true;
      while (state.__telegramMirrorHoldTool) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      return {
        content: [{ type: "text" as const, text: "tool diagnostic payload" }],
        details: {},
        terminate: state.__telegramMirrorTerminateTool === true,
      };
    },
  });
  pi.on("input", async (event) => {
    const state = globalThis as typeof globalThis & {
      __telegramMirrorInjectNested?: boolean;
      __telegramMirrorInjectNestedSlash?: boolean;
    };
    if (state.__telegramMirrorInjectNested && event.source === "extension" && !nested) {
      nested = true;
      pi.sendUserMessage("nested extension input");
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
    if (state.__telegramMirrorInjectNestedSlash && event.source === "interactive" &&
        event.text.startsWith("/")) {
      pi.sendUserMessage("nested slash extension input");
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
      __telegramMirrorHandledInteractiveCount?: number;
    };
    if (state.__telegramMirrorDelayInteractiveInput && event.source === "interactive") {
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (state.__telegramMirrorHandleExtensionInput && event.source === "extension") {
      return { action: "handled" as const };
    }
    if (state.__telegramMirrorHandleInteractiveInput && event.source === "interactive") {
      state.__telegramMirrorHandledInteractiveCount =
        (state.__telegramMirrorHandledInteractiveCount || 0) + 1;
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
process.env.FM_TELEGRAM_MAX_INPUT_CANDIDATES = '256';
process.env.FM_TELEGRAM_HOLD_RETRY_BACKOFF_MS = '25';
const nativeSetTimeout = globalThis.setTimeout;
const completeMirrorReplyTimeout = (1 + 64 * 3) * 45_000 + 30_000;
globalThis.setTimeout = (callback, delay, ...args) => {
  let effectiveDelay = delay;
  if (existsSync(`${home}/exercise-reply-timeout`) && typeof delay === 'number' && delay > 30_000) {
    effectiveDelay = delay >= completeMirrorReplyTimeout ? 200 : 5;
  } else if (delay === 30_000 && existsSync(`${home}/delay-assistant-reply`)) {
    effectiveDelay = 200;
  }
  return nativeSetTimeout(callback, effectiveDelay, ...args);
};
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

writeFileSync(`${home}/exercise-reply-timeout`, '');
const timeoutBoundaryState = state();
timeoutBoundaryState.request = {
  id: 'tg-text-u32-m32', text: 'exercise complete reply timeout', status: 'queued',
};
save(timeoutBoundaryState);
faux.appendResponses([fauxAssistantMessage('reply completed within the derived timeout')]);
await waitFor(() => state().handled?.includes('tg-text-u32-m32'),
  'complete chunk/authentication timeout budget killed a valid mirror reply');
unlinkSync(`${home}/exercise-reply-timeout`);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · reply completed within the derived timeout').length, 1);

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
const queuedUserBlockA = runtime.session.prompt('queued user block A', {
  source: 'interactive', streamingBehavior: 'followUp',
});
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

const deliveriesBeforeSlash = Object.keys(state().deliveries).length;
globalThis.__telegramMirrorInjectNestedSlash = true;
faux.appendResponses([
  (context) => {
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.equal(user.content.map((part) => part.text || '').join(''), 'nested slash extension input');
    return fauxAssistantMessage('nested slash extension answer');
  },
  (context) => {
    const user = context.messages.findLast((message) => message.role === 'user');
    assert.equal(user.content.map((part) => part.text || '').join(''), 'Expanded slash prompt body\n');
    return fauxAssistantMessage('slash prompt answer');
  },
]);
await runtime.session.prompt('/slash-mirror', { source: 'interactive' });
globalThis.__telegramMirrorInjectNestedSlash = false;
assert.equal(userTexts(initialManager).at(-1), 'Expanded slash prompt body\n');
assert.equal(userTexts(initialManager).includes('nested slash extension input'), true);
assert.equal(Object.keys(state().deliveries).length, deliveriesBeforeSlash,
  'slash or nested extension lifecycle was mirrored');

faux.appendResponses([
  async () => {
    await new Promise((resolve) => setTimeout(resolve, 250));
    return fauxAssistantMessage('terminal answer after excluded bash');
  },
]);
const bashTurn = runtime.session.prompt('terminal turn with excluded bash', { source: 'interactive' });
await waitFor(() => userTexts(initialManager)
  .some((text) => text.includes('terminal turn with excluded bash')),
'terminal turn did not start before user bash');
await runtime.session.extensionRunner.emitUserBash({
  type: 'user_bash', command: 'printf bash-output', excludeFromContext: true, cwd: home,
});
await runtime.session.executeBash('printf bash-output', undefined, { excludeFromContext: true });
await bashTurn;
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\nterminal turn with excluded bash').length, 1);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · terminal answer after excluded bash').length, 1);
assert.equal(Object.values(state().deliveries).some((body) => body.includes('bash-output')), false);

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

const usersBeforeOversizedTerminal = userTexts(initialManager).length;
const callsBeforeOversizedTerminal = faux.state.callCount;
await runtime.session.prompt('x'.repeat(256 * 1024), { source: 'interactive' });
assert.equal(userTexts(initialManager).length, usersBeforeOversizedTerminal,
  'oversized terminal input entered Pi');
assert.equal(faux.state.callCount, callsBeforeOversizedTerminal,
  'oversized terminal input started a model turn');
assert.equal(notices.some(([message]) => message.includes('within its delivery limits')), true);

const oversizedResponse = state();
oversizedResponse.request = {
  id: 'tg-text-u22-m22', text: 'request with oversized assistant response', status: 'queued',
};
save(oversizedResponse);
const callsBeforeOversizedResponse = faux.state.callCount;
writeFileSync(`${home}/reject-assistant-validation`, '');
faux.appendResponses([fauxAssistantMessage('assistant exceeds the configured transport boundary')]);
await waitFor(() => state().abandoned?.some(([id]) => id === 'tg-text-u22-m22'),
  'oversized assistant response did not abandon its admitted request');
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('request with oversized assistant response')).length, 1);
assert.equal(faux.state.callCount, callsBeforeOversizedResponse + 1,
  'oversized assistant response reinjected its Telegram request');
assert.equal(state().log.some((call) => call[0] === 'mirror-reply' &&
  call[1].startsWith('assistant-telegram-tg-text-u22-m22-')), false,
  'oversized assistant body reached Telegram delivery');
await waitFor(() => notices.some(([message]) =>
  message === 'An undeliverable mirror response was abandoned without another model turn.'),
'oversized assistant abandonment was not surfaced locally');
unlinkSync(`${home}/reject-assistant-validation`);

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

const callsBeforeCandidateCap = faux.state.callCount;
globalThis.__telegramMirrorHoldCandidateRoot = true;
globalThis.__telegramMirrorHandledInteractiveCount = 0;
faux.appendResponses([
  async () => {
    while (globalThis.__telegramMirrorHoldCandidateRoot) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    return fauxAssistantMessage('candidate cap root answer');
  },
  fauxAssistantMessage('valid answer after busy handled flood'),
]);
const candidateCapRoot = runtime.session.prompt('candidate cap root', { source: 'rpc' });
await waitFor(() => userTexts(initialManager).some((text) => text.includes('candidate cap root')),
  'candidate cap root did not start');
globalThis.__telegramMirrorHandleInteractiveInput = true;
for (let index = 0; index < 257; index += 1) {
  await runtime.session.prompt(`handled busy candidate ${index}`, {
    source: 'interactive', streamingBehavior: 'followUp',
  });
}
globalThis.__telegramMirrorHandleInteractiveInput = false;
assert.equal(globalThis.__telegramMirrorHandledInteractiveCount, 256,
  'bounded candidate capacity did not reach the later input handler');
assert.equal(faux.state.callCount, callsBeforeCandidateCap + 1,
  'handled busy candidates started model turns');
globalThis.__telegramMirrorHoldCandidateRoot = false;
await candidateCapRoot;
await new Promise((resolve) => setTimeout(resolve, 25));
await runtime.session.prompt('valid terminal after busy handled flood', { source: 'interactive' });
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\nvalid terminal after busy handled flood').length, 1);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · valid answer after busy handled flood').length, 1);
assert.equal(faux.state.callCount, callsBeforeCandidateCap + 2,
  'stale handled candidates suppressed a valid post-settlement turn');
assert.equal(notices.some(([message]) => message.includes('cannot accept another mirrored terminal turn')), true);

writeFileSync(`${home}/delay-assistant-reply`, '');
faux.appendResponses([
  fauxAssistantMessage('slow settlement A answer'),
  fauxAssistantMessage('slow settlement B answer'),
]);
const slowSettlementA = runtime.session.prompt('slow settlement A', { source: 'interactive' });
await waitFor(() => existsSync(`${home}/assistant-reply-delayed`),
  'assistant A delivery did not enter the delayed settlement window');
const slowState = state();
slowState.request = {
  id: 'tg-text-u18-m18', text: 'slow settlement B', status: 'queued',
};
save(slowState);
await slowSettlementA;
await waitFor(() => state().handled?.includes('tg-text-u18-m18'),
  'Telegram B was stranded behind assistant A settlement');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · slow settlement A answer').length, 1);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · slow settlement B answer').length, 1);
unlinkSync(`${home}/delay-assistant-reply`);

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
faux.appendResponses([fauxAssistantMessage('expired blocked terminal answer')]);
await runtime.session.prompt('terminal whose blocked delivery expires', { source: 'interactive' });
await waitFor(() => statuses.at(-1)?.[1] === 'telegram: delivery needs attention',
  'expiring terminal delivery did not enter blocked state');
const expiringDeliveryCall = [...state().log].reverse().find((call) =>
  call[0] === 'mirror-reply' && call[1].startsWith('assistant-terminal-'));
assert.ok(expiringDeliveryCall, 'expiring terminal assistant had no stable delivery identity');
const expiringDeliveryId = expiringDeliveryCall[1];
await waitFor(() => state().log.filter((call) =>
  call[0] === 'mirror-reconcile' && call.includes(expiringDeliveryId)).length >= 2,
'expiring terminal delivery was not tracked by reconciliation');
const expiringDeliveryState = state();
expiringDeliveryState.expire_deliveries = [expiringDeliveryId];
save(expiringDeliveryState);
await waitFor(() => notices.some(([message]) =>
  message === 'An expired blocked mirror turn was abandoned without replay.'),
'expired blocked terminal turn was not abandoned visibly');
unlinkSync(`${home}/reject-assistant-reply`);
const expiredDeliveryAttempts = state().log.filter((call) =>
  call[0] === 'mirror-reply' && call[1] === expiringDeliveryId).length;
const callsAfterTerminalDeliveryExpiry = faux.state.callCount;
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await new Promise((resolve) => setTimeout(resolve, 600));
assert.equal(state().log.filter((call) =>
  call[0] === 'mirror-reply' && call[1] === expiringDeliveryId).length, expiredDeliveryAttempts,
'expired terminal delivery was recreated and replayed');
assert.equal(faux.state.callCount, callsAfterTerminalDeliveryExpiry,
  'expired terminal delivery recovery invoked the model');

const expiredTelegram = state();
expiredTelegram.request = {
  id: 'tg-text-u20-m20', text: 'Telegram response whose delivery expires', status: 'queued',
};
save(expiredTelegram);
writeFileSync(`${home}/reject-assistant-reply`, '');
const callsBeforeExpiredTelegram = faux.state.callCount;
faux.appendResponses([fauxAssistantMessage('expired blocked Telegram answer')]);
await waitFor(() => statuses.at(-1)?.[1] === 'telegram: delivery needs attention',
  'expiring Telegram response did not enter blocked state');
const expiredTelegramCall = [...state().log].reverse().find((call) =>
  call[0] === 'mirror-reply' && call[1].startsWith('assistant-telegram-tg-text-u20-m20-'));
assert.ok(expiredTelegramCall, 'expiring Telegram response had no stable delivery identity');
const expiredTelegramDeliveryId = expiredTelegramCall[1];
await waitFor(() => state().log.some((call) =>
  call[0] === 'mirror-reconcile' && call.includes(expiredTelegramDeliveryId)),
'expiring Telegram response was not tracked by reconciliation');
const expiredTelegramState = state();
expiredTelegramState.expire_deliveries = [expiredTelegramDeliveryId];
save(expiredTelegramState);
await waitFor(() => state().request === null,
  'expired failed Telegram response retained its claimed request');
const expiredTelegramAttempts = state().log.filter((call) =>
  call[0] === 'mirror-reply' && call[1] === expiredTelegramDeliveryId).length;
unlinkSync(`${home}/reject-assistant-reply`);
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await new Promise((resolve) => setTimeout(resolve, 600));
assert.equal(state().log.filter((call) =>
  call[0] === 'mirror-reply' && call[1] === expiredTelegramDeliveryId).length,
expiredTelegramAttempts, 'expired Telegram response was recreated and replayed');
assert.equal(faux.state.callCount, callsBeforeExpiredTelegram + 1,
  'expired Telegram response invoked another model pass');
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('Telegram response whose delivery expires')).length, 1);

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

const terminalModeOffCalls = faux.state.callCount;
globalThis.__telegramMirrorHoldTool = true;
globalThis.__telegramMirrorTerminateTool = false;
globalThis.__telegramMirrorToolStarted = false;
faux.appendResponses([
  fauxAssistantMessage([
    fauxToolCall('mirror_test_tool', {}, { id: 'terminal-mode-off-tool-call' }),
  ], { stopReason: 'toolUse' }),
  fauxAssistantMessage('terminal tool loop answer after mode-off refusal'),
]);
const terminalModeOffRoot = runtime.session.prompt('terminal tool loop before mode-off refusal', {
  source: 'interactive',
});
await waitFor(() => globalThis.__telegramMirrorToolStarted === true,
  'terminal mode-off tool loop did not reach tool execution');
await runtime.session.prompt('/telegram off', { source: 'interactive' });
const usersBeforeTerminalModeOffRefusal = userTexts(initialManager).length;
await runtime.session.prompt('local input while terminal mirror turn is active', {
  source: 'interactive', streamingBehavior: 'steer',
});
assert.equal(userTexts(initialManager).length, usersBeforeTerminalModeOffRefusal,
  'mode-off local input reset an accepted terminal mirror turn');
assert.equal(notices.some(([message]) =>
  message === 'Wait for the accepted mirrored turn to settle before continuing locally.'), true,
  'terminal mode-off refusal was not visible');
globalThis.__telegramMirrorHoldTool = false;
await terminalModeOffRoot;
await waitFor(() => Object.values(state().deliveries)
  .some((body) => body === 'Firstmate · terminal tool loop answer after mode-off refusal'),
'accepted terminal tool loop did not settle after mode-off refusal');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\nterminal tool loop before mode-off refusal').length, 1);
assert.equal(faux.state.callCount, terminalModeOffCalls + 2,
  'mode-off terminal refusal added or lost a model pass');
await runtime.session.prompt('/telegram on', { source: 'interactive' });

const terminalModeReadCalls = faux.state.callCount;
globalThis.__telegramMirrorHoldTool = true;
globalThis.__telegramMirrorTerminateTool = false;
globalThis.__telegramMirrorToolStarted = false;
faux.appendResponses([
  fauxAssistantMessage([
    fauxToolCall('mirror_test_tool', {}, { id: 'terminal-mode-read-tool-call' }),
  ], { stopReason: 'toolUse' }),
  fauxAssistantMessage('terminal tool loop answer after mode-read refusal'),
]);
const terminalModeReadRoot = runtime.session.prompt('terminal tool loop before mode-read refusal', {
  source: 'interactive',
});
await waitFor(() => globalThis.__telegramMirrorToolStarted === true,
  'terminal mode-read tool loop did not reach tool execution');
writeFileSync(`${home}/fail-mode-read`, '');
const usersBeforeTerminalModeReadRefusal = userTexts(initialManager).length;
await runtime.session.prompt('local input while mirror preference is unreadable', {
  source: 'interactive', streamingBehavior: 'steer',
});
unlinkSync(`${home}/fail-mode-read`);
assert.equal(userTexts(initialManager).length, usersBeforeTerminalModeReadRefusal,
  'mode-read failure reset an accepted terminal mirror turn');
globalThis.__telegramMirrorHoldTool = false;
await terminalModeReadRoot;
await waitFor(() => Object.values(state().deliveries)
  .some((body) => body === 'Firstmate · terminal tool loop answer after mode-read refusal'),
'accepted terminal tool loop did not settle after mode-read refusal');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\nterminal tool loop before mode-read refusal').length, 1);
assert.equal(faux.state.callCount, terminalModeReadCalls + 2,
  'mode-read terminal refusal added or lost a model pass');

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

writeFileSync(`${home}/fail-mode-read`, '');
const deliveriesBeforeModeReadFailure = Object.keys(state().deliveries).length;
const callsBeforeModeReadFailure = faux.state.callCount;
faux.appendResponses([fauxAssistantMessage('ordinary answer after mode read failure')]);
await runtime.session.prompt('terminal during mode read failure', { source: 'interactive' });
unlinkSync(`${home}/fail-mode-read`);
assert.equal(Object.keys(state().deliveries).length, deliveriesBeforeModeReadFailure,
  'failed mode read reused stale on state for terminal mirroring');
assert.equal(faux.state.callCount, callsBeforeModeReadFailure + 1,
  'failed mode read prevented the ordinary local Pi turn');
assert.equal(userTexts(initialManager).at(-1), 'terminal during mode read failure');
assert.equal(notices.some(([message]) => message.includes('preference could not be read')), true);

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

const steered = state();
steered.request = { id: 'tg-text-u19-m19', text: 'Telegram tool-loop request', status: 'queued' };
save(steered);
globalThis.__telegramMirrorHoldTool = true;
globalThis.__telegramMirrorTerminateTool = true;
globalThis.__telegramMirrorToolStarted = false;
const callsBeforeSteer = faux.state.callCount;
faux.appendResponses([
  fauxAssistantMessage([
    fauxToolCall('mirror_test_tool', {}, { id: 'mirror-steer-tool-call' }),
  ], { stopReason: 'toolUse' }),
  fauxAssistantMessage('answer after terminal steer'),
]);
await waitFor(() => globalThis.__telegramMirrorToolStarted === true,
  'Telegram tool loop did not reach tool execution');
const terminalSteer = runtime.session.prompt('terminal steer during Telegram tool loop', {
  source: 'interactive', streamingBehavior: 'steer',
});
await new Promise((resolve) => setTimeout(resolve, 50));
globalThis.__telegramMirrorHoldTool = false;
await terminalSteer;
globalThis.__telegramMirrorTerminateTool = false;
await waitFor(() => state().handled?.includes('tg-text-u19-m19'),
  'terminal steer did not complete the original Telegram request');
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('Telegram tool-loop request')).length, 1);
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('terminal steer during Telegram tool loop')).length, 1);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\nterminal steer during Telegram tool loop').length, 1,
  'terminal steer was not mirrored');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · answer after terminal steer').length, 1);
assert.equal(faux.state.callCount, callsBeforeSteer + 2,
  'terminal steer reinjected the original Telegram request');
assert.equal(initialManager.getEntries().some((entry) =>
  entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission'
    && entry.data.requestId === 'tg-text-u19-m19' && entry.data.state === 'interrupted'), false);
assert.equal(initialManager.getEntries().some((entry) =>
  entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission'
    && entry.data.requestId === 'tg-text-u19-m19' && entry.data.state === 'carried'), true);

const modeOffSteered = state();
modeOffSteered.request = {
  id: 'tg-text-u31-m31', text: 'Telegram tool loop before mode-off local steer', status: 'queued',
};
save(modeOffSteered);
globalThis.__telegramMirrorHoldTool = true;
globalThis.__telegramMirrorTerminateTool = false;
globalThis.__telegramMirrorToolStarted = false;
const callsBeforeModeOffSteer = faux.state.callCount;
const deliveriesBeforeModeOffSteer = Object.keys(state().deliveries).length;
faux.appendResponses([
  fauxAssistantMessage([
    fauxToolCall('mirror_test_tool', {}, { id: 'mirror-mode-off-steer-tool-call' }),
  ], { stopReason: 'toolUse' }),
  fauxAssistantMessage('accepted Telegram answer after mode-off refusal'),
]);
await waitFor(() => globalThis.__telegramMirrorToolStarted === true,
  'mode-off steer Telegram tool loop did not reach tool execution');
const usersBeforeModeOffSteer = userTexts(initialManager).length;
await runtime.session.prompt('/telegram off', { source: 'interactive' });
await runtime.session.prompt('ordinary local steer while mirror is off', {
  source: 'interactive', streamingBehavior: 'steer',
});
assert.equal(userTexts(initialManager).length, usersBeforeModeOffSteer,
  'mode-off local continuation entered Pi before the accepted Telegram turn settled');
assert.equal(notices.some(([message]) =>
  message === 'Wait for the accepted mirrored turn to settle before continuing locally.'), true,
  'mode-off local continuation refusal was not visible');
globalThis.__telegramMirrorHoldTool = false;
await waitFor(() => state().handled?.includes('tg-text-u31-m31'),
  'mode-off refusal prevented the accepted Telegram response from settling');
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('Telegram tool loop before mode-off local steer')).length, 1);
assert.equal(userTexts(initialManager)
  .some((text) => text === 'ordinary local steer while mirror is off'), false);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · accepted Telegram answer after mode-off refusal').length, 1);
assert.equal(Object.keys(state().deliveries).length, deliveriesBeforeModeOffSteer + 1,
  'accepted Telegram response did not fan out after mode-off continuation refusal');
assert.equal(faux.state.callCount, callsBeforeModeOffSteer + 2,
  'mode-off local steer added an unexpected model pass');
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await new Promise((resolve) => setTimeout(resolve, 300));
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('Telegram tool loop before mode-off local steer')).length, 1,
  'mode-on reinjected the accepted Telegram request after a local mode-off steer');
assert.equal(faux.state.callCount, callsBeforeModeOffSteer + 2,
  'mode-on reran the model after a local mode-off steer');

const carriedModeOffState = state();
carriedModeOffState.request = {
  id: 'tg-text-u33-m33', text: 'Telegram tool loop carried by terminal steer', status: 'queued',
};
save(carriedModeOffState);
globalThis.__telegramMirrorHoldTool = true;
globalThis.__telegramMirrorHoldProvider = true;
globalThis.__telegramMirrorTerminateTool = true;
globalThis.__telegramMirrorToolStarted = false;
const callsBeforeCarriedModeOff = faux.state.callCount;
faux.appendResponses([
  fauxAssistantMessage([
    fauxToolCall('mirror_test_tool', {}, { id: 'mirror-carried-mode-off-root-tool' }),
  ], { stopReason: 'toolUse' }),
  async (context) => {
    assert.match(context.systemPrompt + JSON.stringify(context.messages),
      /conversation segment originated from the authenticated Telegram mirror/);
    assert.match(context.systemPrompt + JSON.stringify(context.messages),
      /terminal steer authorizes only the concrete action it explicitly confirms/);
    while (globalThis.__telegramMirrorHoldProvider) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    return fauxAssistantMessage('accepted carried answer after mode-off refusal');
  },
]);
await waitFor(() => globalThis.__telegramMirrorToolStarted === true,
  'carried mode-off root did not reach tool execution');
const carriedSteer = runtime.session.prompt('terminal steer carrying Telegram request', {
  source: 'interactive', streamingBehavior: 'steer',
});
globalThis.__telegramMirrorHoldTool = false;
await waitFor(() => userTexts(initialManager)
  .some((text) => text.includes('terminal steer carrying Telegram request')),
  'carrying terminal steer did not enter Pi');
globalThis.__telegramMirrorTerminateTool = false;
await runtime.session.prompt('/telegram off', { source: 'interactive' });
const usersBeforeCarriedRefusal = userTexts(initialManager).length;
await runtime.session.prompt('local mode-off steer after carried request', {
  source: 'interactive', streamingBehavior: 'steer',
});
assert.equal(userTexts(initialManager).length, usersBeforeCarriedRefusal,
  'mode-off local continuation entered Pi while a carried request was active');
globalThis.__telegramMirrorHoldProvider = false;
await carriedSteer;
await waitFor(() => state().handled?.includes('tg-text-u33-m33'),
  'carried Telegram request did not settle after mode-off refusal');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · accepted carried answer after mode-off refusal').length, 1);
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await new Promise((resolve) => setTimeout(resolve, 300));
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('Telegram tool loop carried by terminal steer')).length, 1);
assert.equal(faux.state.callCount, callsBeforeCarriedModeOff + 2,
  'carried request was reinjected after mode-off refusal');

const slashSteered = state();
slashSteered.request = {
  id: 'tg-text-u27-m27', text: 'Telegram tool loop before excluded slash', status: 'queued',
};
save(slashSteered);
globalThis.__telegramMirrorHoldTool = true;
globalThis.__telegramMirrorTerminateTool = true;
globalThis.__telegramMirrorToolStarted = false;
const callsBeforeSlashSteer = faux.state.callCount;
const deliveriesBeforeSlashSteer = Object.keys(state().deliveries).length;
faux.appendResponses([
  fauxAssistantMessage([
    fauxToolCall('mirror_test_tool', {}, { id: 'mirror-slash-steer-tool-call' }),
  ], { stopReason: 'toolUse' }),
  fauxAssistantMessage('answer after excluded slash steer'),
]);
await waitFor(() => globalThis.__telegramMirrorToolStarted === true,
  'Telegram slash-steer tool loop did not reach tool execution');
const slashSteer = runtime.session.prompt('/slash-mirror', {
  source: 'interactive', streamingBehavior: 'steer',
});
await new Promise((resolve) => setTimeout(resolve, 50));
globalThis.__telegramMirrorHoldTool = false;
await slashSteer;
globalThis.__telegramMirrorTerminateTool = false;
await waitFor(() => state().handled?.includes('tg-text-u27-m27'),
  'excluded slash steer did not settle the original Telegram request');
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('Telegram tool loop before excluded slash')).length, 1);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · answer after excluded slash steer').length, 1);
assert.equal(Object.keys(state().deliveries).length, deliveriesBeforeSlashSteer + 1,
  'excluded slash lifecycle was mirrored');
assert.equal(faux.state.callCount, callsBeforeSlashSteer + 2,
  'excluded slash steer reinjected the original Telegram request');
assert.equal(initialManager.getEntries().some((entry) =>
  entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission'
    && entry.data.requestId === 'tg-text-u27-m27' && entry.data.state === 'interrupted'), false);
const persistedSlash = initialManager.getEntries().findLast((entry) =>
  entry.type === 'message' && entry.message.role === 'user' &&
  entry.message.content.map?.((part) => part.text || '').join('') === 'Expanded slash prompt body\n');
assert.match(persistedSlash?.message.firstmateExcludedSlash || '', /^[a-f0-9]{128}$/,
  'excluded slash lifecycle did not persist self-identifying provenance');

const terminalSlashDeliveries = Object.keys(state().deliveries).length;
globalThis.__telegramMirrorHoldTool = true;
globalThis.__telegramMirrorTerminateTool = true;
globalThis.__telegramMirrorToolStarted = false;
faux.appendResponses([
  fauxAssistantMessage([
    fauxToolCall('mirror_test_tool', {}, { id: 'terminal-slash-tool-call' }),
  ], { stopReason: 'toolUse' }),
  fauxAssistantMessage('terminal answer after excluded slash'),
]);
const terminalSlashRoot = runtime.session.prompt('terminal tool loop before excluded slash', {
  source: 'interactive',
});
await waitFor(() => globalThis.__telegramMirrorToolStarted === true,
  'terminal slash tool loop did not reach tool execution');
const terminalSlash = runtime.session.prompt('/slash-mirror', {
  source: 'interactive', streamingBehavior: 'steer',
});
globalThis.__telegramMirrorHoldTool = false;
await Promise.all([terminalSlashRoot, terminalSlash]);
globalThis.__telegramMirrorTerminateTool = false;
await waitFor(() => Object.values(state().deliveries)
  .some((body) => body === 'Firstmate · terminal answer after excluded slash'),
'excluded slash did not preserve the terminal-origin tool loop');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'You · Terminal\n\nterminal tool loop before excluded slash').length, 1);
assert.equal(Object.keys(state().deliveries).length, terminalSlashDeliveries + 2,
  'excluded slash lifecycle was mirrored during a terminal-origin tool loop');

const competingState = state();
competingState.request = {
  id: 'tg-text-u29-m29', text: 'Telegram tool loop before other extension', status: 'queued',
};
save(competingState);
globalThis.__telegramMirrorHoldTool = true;
globalThis.__telegramMirrorTerminateTool = true;
globalThis.__telegramMirrorToolStarted = false;
const competingDeliveries = Object.keys(state().deliveries).length;
const competingCalls = faux.state.callCount;
faux.appendResponses([
  fauxAssistantMessage([
    fauxToolCall('mirror_test_tool', {}, { id: 'other-extension-tool-call' }),
  ], { stopReason: 'toolUse' }),
  fauxAssistantMessage('other extension answer must stay local'),
]);
await waitFor(() => globalThis.__telegramMirrorToolStarted === true,
  'other-extension exclusion tool loop did not reach tool execution');
globalThis.__telegramMirrorSendOtherExtension();
globalThis.__telegramMirrorHoldTool = false;
globalThis.__telegramMirrorTerminateTool = false;
await waitFor(() => state().request?.status === 'held',
  'unmarked other-extension lifecycle did not freeze Telegram capture');
await waitFor(() => faux.state.callCount === competingCalls + 2,
  'other-extension lifecycle did not finish its model turn');
await runtime.session.waitForIdle();
assert.equal(Object.values(state().deliveries)
  .some((body) => body.includes('other extension answer must stay local')), false,
  'other-extension assistant was mirrored as the Telegram response');
assert.equal(Object.keys(state().deliveries).length, competingDeliveries,
  'other-extension lifecycle produced mirror delivery');
const clearedCompetingState = state();
clearedCompetingState.request = null;
save(clearedCompetingState);
await runtime.session.reload();

const expiringSteer = state();
expiringSteer.request = {
  id: 'tg-text-u23-m23', text: 'Telegram request with expiring terminal steer', status: 'queued',
};
save(expiringSteer);
writeFileSync(`${home}/reject-user-reply`, '');
globalThis.__telegramMirrorHoldTool = true;
globalThis.__telegramMirrorTerminateTool = true;
globalThis.__telegramMirrorToolStarted = false;
const callsBeforeExpiringSteer = faux.state.callCount;
faux.appendResponses([
  fauxAssistantMessage([
    fauxToolCall('mirror_test_tool', {}, { id: 'mirror-expiring-steer-tool-call' }),
  ], { stopReason: 'toolUse' }),
  fauxAssistantMessage('answer paired with expiring terminal steer'),
]);
await waitFor(() => globalThis.__telegramMirrorToolStarted === true,
  'expiring terminal steer did not reach tool execution');
const expiringSteerPrompt = runtime.session.prompt('terminal steer whose delivery expires', {
  source: 'interactive', streamingBehavior: 'steer',
});
await new Promise((resolve) => setTimeout(resolve, 50));
globalThis.__telegramMirrorHoldTool = false;
await expiringSteerPrompt;
globalThis.__telegramMirrorTerminateTool = false;
await waitFor(() => statuses.at(-1)?.[1] === 'telegram: delivery needs attention',
  'expiring carried terminal delivery did not block settlement');
const expiringSteerDelivery = [...state().log].reverse().find((call) =>
  call[0] === 'mirror-reply' && call[1].startsWith('user-terminal-') &&
  state().delivery_records[call[1]] === 'rejected');
assert.ok(expiringSteerDelivery, 'expiring carried terminal delivery had no stable identity');
const expiringSteerId = expiringSteerDelivery[1];
const expireSteerState = state();
expireSteerState.expire_deliveries = [expiringSteerId];
save(expireSteerState);
await waitFor(() => state().abandoned?.some(([id]) => id === 'tg-text-u23-m23'),
  'expired carried terminal delivery did not abandon its Telegram request');
unlinkSync(`${home}/reject-user-reply`);
const expiringSteerAttempts = state().log.filter((call) =>
  call[0] === 'mirror-reply' && call[1] === expiringSteerId).length;
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await new Promise((resolve) => setTimeout(resolve, 600));
assert.equal(state().log.filter((call) =>
  call[0] === 'mirror-reply' && call[1] === expiringSteerId).length, expiringSteerAttempts,
  'expired carried terminal delivery replayed history');
assert.equal(faux.state.callCount, callsBeforeExpiringSteer + 2,
  'expired carried terminal delivery reinjected its Telegram request');

const competingRequest = { id: 'tg-text-u9-m9', text: 'paired Telegram request', status: 'queued' };
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
await waitFor(() => {
  const observed = state();
  if (observed.request?.id === competingRequest.id || observed.handled?.includes(competingRequest.id)) {
    return true;
  }
  observed.request = competingRequest;
  save(observed);
  return false;
}, 'competing Telegram request was not retained for admission');
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

const preflightSettlement = state();
preflightSettlement.request = {
  id: 'tg-text-u21-m21', text: 'response settles during unrelated preflight', status: 'queued',
};
save(preflightSettlement);
const callsBeforePreflightSettlement = faux.state.callCount;
faux.appendResponses([
  async () => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    return fauxAssistantMessage('response settled during handled preflight');
  },
]);
await waitFor(() => userTexts(initialManager)
  .some((text) => text.includes('response settles during unrelated preflight')),
'preflight settlement Telegram turn did not start');
writeFileSync(`${home}/delay-mirror-validate`, '');
globalThis.__telegramMirrorDelayInteractiveInput = true;
globalThis.__telegramMirrorHandleInteractiveInput = true;
const handledDuringSettlement = runtime.session.prompt('handled while prior response settles', {
  source: 'interactive', streamingBehavior: 'followUp',
});
await handledDuringSettlement;
unlinkSync(`${home}/delay-mirror-validate`);
globalThis.__telegramMirrorDelayInteractiveInput = false;
globalThis.__telegramMirrorHandleInteractiveInput = false;
await waitFor(() => state().handled?.includes('tg-text-u21-m21'),
  'handled unrelated preflight stranded the finalized Telegram response');
assert.equal(userTexts(initialManager)
  .some((text) => text.includes('handled while prior response settles')), false);
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · response settled during handled preflight').length, 1);
assert.equal(faux.state.callCount, callsBeforePreflightSettlement + 1,
  'handled unrelated preflight caused another model pass');

const deferredFailure = state();
deferredFailure.request = {
  id: 'tg-text-u26-m26', text: 'provider failure during input preflight', status: 'queued',
};
save(deferredFailure);
faux.appendResponses([
  async () => {
    await new Promise((resolve) => setTimeout(resolve, 100));
    return fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'provider failed during preflight' });
  },
]);
await waitFor(() => userTexts(initialManager)
  .some((text) => text.includes('provider failure during input preflight')),
'provider-failure preflight request did not start');
writeFileSync(`${home}/delay-mirror-validate`, '');
globalThis.__telegramMirrorHandleInteractiveInput = true;
const usersBeforeDeferredHandled = userTexts(initialManager).length;
await runtime.session.prompt('handled preflight after provider failure', {
  source: 'interactive', streamingBehavior: 'followUp',
});
globalThis.__telegramMirrorHandleInteractiveInput = false;
unlinkSync(`${home}/delay-mirror-validate`);
await waitFor(() => state().request?.status === 'held' && initialManager.getEntries().some((entry) =>
  entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission'
    && entry.data.requestId === 'tg-text-u26-m26' && entry.data.state === 'interrupted'),
'handled preflight stranded the finalized no-body Telegram request');
assert.equal(userTexts(initialManager).length, usersBeforeDeferredHandled,
  'handled provider-failure preflight entered Pi');
faux.appendResponses([fauxAssistantMessage('explicit deferred failure recovery')]);
await runtime.session.prompt('/telegram on', { source: 'interactive' });
await waitFor(() => state().handled?.includes('tg-text-u26-m26'),
  'explicit recovery did not settle the deferred provider failure');

const failedHold = state();
failedHold.request = { id: 'tg-text-u30-m30', text: 'provider failure with bounded hold', status: 'queued' };
save(failedHold);
writeFileSync(`${home}/reject-mirror-hold`, '');
const callsBeforeFailedHold = faux.state.callCount;
const holdsBeforeFailure = state().log.filter((call) => call[0] === 'mirror-hold').length;
faux.appendResponses([
  fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'provider failed before hold transition' }),
]);
await waitFor(() => state().abandoned?.some(([id]) => id === 'tg-text-u30-m30') &&
  initialManager.getEntries().some((entry) =>
    entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission' &&
      entry.data.requestId === 'tg-text-u30-m30' && entry.data.state === 'abandoned'),
  'persistent hold failure did not reach a bounded non-requeue outcome');
unlinkSync(`${home}/reject-mirror-hold`);
const boundedHoldAttempts = state().log.filter((call) => call[0] === 'mirror-hold').length - holdsBeforeFailure;
assert.equal(boundedHoldAttempts, 3, 'persistent hold failure did not use the bounded retry budget');
assert.equal(initialManager.getEntries().some((entry) =>
  entry.type === 'custom' && entry.customType === 'firstmate-telegram-admission'
    && entry.data.requestId === 'tg-text-u30-m30' && entry.data.state === 'abandoned'), true,
'persistent hold failure did not persist its non-requeue outcome');
assert.equal(userTexts(initialManager)
  .filter((text) => text.includes('provider failure with bounded hold')).length, 1);
assert.equal(faux.state.callCount, callsBeforeFailedHold + 1,
  'persistent hold failure reinjected the accepted Telegram request');
await new Promise((resolve) => setTimeout(resolve, 500));
assert.equal(state().log.filter((call) => call[0] === 'mirror-hold').length - holdsBeforeFailure, 3,
  'persistent hold failure kept retrying after its bounded outcome');

const fatalHold = state();
fatalHold.request = {
  id: 'tg-text-u34-m34', text: 'provider failure with unavailable state storage', status: 'queued',
};
save(fatalHold);
writeFileSync(`${home}/reject-mirror-hold`, '');
writeFileSync(`${home}/reject-mirror-abandon`, '');
const callsBeforeFatalHold = faux.state.callCount;
const holdsBeforeFatal = state().log.filter((call) => call[0] === 'mirror-hold').length;
const abandonsBeforeFatal = state().log.filter((call) => call[0] === 'mirror-abandon').length;
faux.appendResponses([
  fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'provider and state storage failed' }),
]);
await waitFor(() =>
  state().log.filter((call) => call[0] === 'mirror-hold').length - holdsBeforeFatal === 3 &&
  state().log.filter((call) => call[0] === 'mirror-abandon').length - abandonsBeforeFatal === 1,
'persistent state-storage failure did not exhaust its bounded transition budget');
await new Promise((resolve) => setTimeout(resolve, 500));
assert.equal(state().log.filter((call) => call[0] === 'mirror-hold').length - holdsBeforeFatal, 3,
  'fatal state-storage failure kept retrying mirror-hold');
assert.equal(state().log.filter((call) => call[0] === 'mirror-abandon').length - abandonsBeforeFatal, 1,
  'fatal state-storage failure kept retrying mirror-abandon');
assert.equal(state().request?.status, 'claimed',
  'fatal state-storage failure released the accepted claim without a durable transition');
assert.equal(statuses.at(-1)?.[1], 'telegram: state storage needs recovery');
assert.equal(notices.filter(([message]) =>
  message === 'Telegram mirror state storage is unavailable; restore it and restart Pi before continuing.'
).length, 1, 'fatal state-storage failure did not notify exactly once');
const usersBeforeFatalRefusal = userTexts(initialManager).length;
await runtime.session.prompt('local input during fatal mirror storage error', { source: 'interactive' });
assert.equal(userTexts(initialManager).length, usersBeforeFatalRefusal,
  'fatal state-storage failure admitted new local mirror work');
assert.equal(faux.state.callCount, callsBeforeFatalHold + 1,
  'fatal state-storage failure ran another model turn');
unlinkSync(`${home}/reject-mirror-hold`);
unlinkSync(`${home}/reject-mirror-abandon`);
await runtime.session.reload();
await waitFor(() => state().handled?.includes('tg-text-u34-m34'),
  'storage recovery did not resolve the preserved fatal claim');

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

const providerFailureLogStart = state().log.length;
faux.appendResponses(Array.from({ length: 12 }, () =>
  fauxAssistantMessage([], { stopReason: 'error', errorMessage: 'terminal provider failed' })));
for (let index = 0; index < 12; index += 1) {
  await runtime.session.prompt(`terminal provider failure ${index}`, { source: 'interactive' });
}
await new Promise((resolve) => setTimeout(resolve, 700));
const providerFailureReconciles = state().log.slice(providerFailureLogStart)
  .filter((call) => call[0] === 'mirror-reconcile');
assert.ok(providerFailureReconciles.length > 0, 'terminal provider failures were not reconciled');
assert.equal(providerFailureReconciles.every((call) =>
  call.filter((argument) => argument === '--report-delivery').length <= 1), true,
  'interrupted terminal delivery identities accumulated in reconciliation');

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
replacement.represented_requests['tg-text-stale-current'] = { status: 'claimed', owner: process.pid };
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
writeFileSync(`${home}/reject-mirror-abandon`, '');
const extraRecoveryAbandonsBefore = state().log.filter((call) =>
  call[0] === 'mirror-abandon' && call[1] === 'tg-text-stale-current').length;
const extraRecoveryCallsBefore = faux.state.callCount;
const fatalNoticesBeforeExtraRecovery = notices.filter(([message]) =>
  message === 'Telegram mirror state storage is unavailable; restore it and restart Pi before continuing.').length;
await runtime.newSession({
  parentSession: previousFile,
  setup: async (manager) => {
    manager.appendCustomEntry('firstmate-telegram-admission', {
      requestId: 'tg-text-stale-current', turnId: 'telegram-stale-current',
      sessionId: manager.getSessionId(), state: 'admitted',
    });
    manager.appendMessage({
      role: 'user', content: [{ type: 'text', text: 'You · Telegram\n\nstale current admission' }],
      timestamp: Date.now(),
    });
  },
});
await waitFor(() => state().handled?.includes('tg-text-u2-m2'), 'session replacement did not reconcile persisted admission provenance');
assert.equal(userTexts(runtime.session.sessionManager)
  .filter((text) => text.includes('replacement request')).length, 0,
'session replacement reinjected represented Telegram input');
assert.equal(Object.values(state().deliveries).filter((body) => body === 'Firstmate · replacement answer').length, 1);
assert.equal(Object.values(state().deliveries).some((body) => body.includes('later operational answer')), false);
await waitFor(() => state().log.filter((call) =>
  call[0] === 'mirror-abandon' && call[1] === 'tg-text-stale-current').length -
  extraRecoveryAbandonsBefore === 3,
'failed extra startup abandonment did not exhaust its bounded retry budget');
await new Promise((resolve) => setTimeout(resolve, 700));
assert.equal(state().log.filter((call) =>
  call[0] === 'mirror-abandon' && call[1] === 'tg-text-stale-current').length -
  extraRecoveryAbandonsBefore, 3,
  'failed extra startup abandonment kept retrying');
assert.equal(state().represented_requests['tg-text-stale-current']?.status, 'claimed',
  'failed extra startup abandonment discarded its recovery evidence');
assert.equal(statuses.at(-1)?.[1], 'telegram: state storage needs recovery');
assert.equal(notices.filter(([message]) =>
  message === 'Telegram mirror state storage is unavailable; restore it and restart Pi before continuing.').length,
  fatalNoticesBeforeExtraRecovery + 1,
  'failed extra startup abandonment did not enter the fatal storage boundary exactly once');
assert.equal(faux.state.callCount, extraRecoveryCallsBefore,
  'failed extra startup abandonment ran another model turn');
assert.equal(userTexts(runtime.session.sessionManager)
  .some((text) => text.includes('stale current admission')), true,
  'current represented admission unexpectedly disappeared from persisted history');
unlinkSync(`${home}/reject-mirror-abandon`);
await runtime.session.reload();
await waitFor(() => state().abandoned?.some(([id]) => id === 'tg-text-stale-current'),
  'storage recovery did not abandon the extra represented admission');

const primaryRecoveryRequestId = 'tg-text-startup-abandon-primary';
const primaryRecoveryTurnId = 'telegram-startup-abandon-primary';
const primaryRecoveryState = state();
primaryRecoveryState.request = {
  id: primaryRecoveryRequestId, text: 'persisted provider failure requiring startup abandonment',
  status: 'claimed', owner: process.pid,
};
save(primaryRecoveryState);
writeFileSync(`${home}/reject-mirror-abandon`, '');
const primaryRecoveryAbandonsBefore = state().log.filter((call) =>
  call[0] === 'mirror-abandon' && call[1] === primaryRecoveryRequestId).length;
const primaryRecoveryCallsBefore = faux.state.callCount;
const fatalNoticesBeforePrimaryRecovery = notices.filter(([message]) =>
  message === 'Telegram mirror state storage is unavailable; restore it and restart Pi before continuing.').length;
await runtime.newSession({
  setup: async (manager) => {
    manager.appendCustomEntry('firstmate-telegram-admission', {
      requestId: primaryRecoveryRequestId, turnId: primaryRecoveryTurnId,
      sessionId: manager.getSessionId(), state: 'admitted',
    });
    manager.appendMessage({
      role: 'user', content: [{ type: 'text', text: 'You · Telegram\n\npersisted provider failure requiring startup abandonment' }],
      timestamp: Date.now(),
    });
  },
});
await waitFor(() => state().log.filter((call) =>
  call[0] === 'mirror-abandon' && call[1] === primaryRecoveryRequestId).length -
  primaryRecoveryAbandonsBefore === 3,
'failed primary startup abandonment did not exhaust its bounded retry budget');
await new Promise((resolve) => setTimeout(resolve, 700));
assert.equal(state().log.filter((call) =>
  call[0] === 'mirror-abandon' && call[1] === primaryRecoveryRequestId).length -
  primaryRecoveryAbandonsBefore, 3,
  'failed primary startup abandonment kept retrying');
assert.equal(state().request?.id, primaryRecoveryRequestId,
  'failed primary startup abandonment discarded its recovery evidence');
assert.equal(statuses.at(-1)?.[1], 'telegram: state storage needs recovery');
assert.equal(notices.filter(([message]) =>
  message === 'Telegram mirror state storage is unavailable; restore it and restart Pi before continuing.').length,
  fatalNoticesBeforePrimaryRecovery + 1,
  'failed primary startup abandonment did not enter the fatal storage boundary exactly once');
assert.equal(faux.state.callCount, primaryRecoveryCallsBefore,
  'failed primary startup abandonment ran another model turn');
unlinkSync(`${home}/reject-mirror-abandon`);
await runtime.session.reload();
await waitFor(() => state().abandoned?.some(([id]) => id === primaryRecoveryRequestId),
  'storage recovery did not abandon the primary represented admission');

const transientReconcileRequestId = 'tg-text-transient-reconcile';
const transientReconcileTurnId = 'telegram-transient-reconcile';
const transientReconcileState = state();
transientReconcileState.request = {
  id: transientReconcileRequestId, text: 'persisted request across transient reconciliation failure',
  status: 'claimed', owner: process.pid,
};
save(transientReconcileState);
writeFileSync(`${home}/fail-next-reconcile`, '');
const transientReconcileCallsBefore = state().log.filter((call) =>
  call[0] === 'mirror-reconcile' && call.includes(transientReconcileRequestId)).length;
const modelCallsBeforeTransientReconcile = faux.state.callCount;
await runtime.newSession({
  setup: async (manager) => {
    manager.appendCustomEntry('firstmate-telegram-admission', {
      requestId: transientReconcileRequestId, turnId: transientReconcileTurnId,
      sessionId: manager.getSessionId(), state: 'admitted',
    });
    manager.appendMessage({
      role: 'user', content: [{ type: 'text', text: 'You · Telegram\n\npersisted request across transient reconciliation failure' }],
      timestamp: Date.now(),
    });
    manager.appendMessage(fauxAssistantMessage('persisted answer after transient reconciliation failure'));
  },
});
await waitFor(() => state().handled?.includes(transientReconcileRequestId),
  'transient startup reconciliation failure did not recover durable admission ownership');
assert.ok(state().log.filter((call) =>
  call[0] === 'mirror-reconcile' && call.includes(transientReconcileRequestId)).length -
  transientReconcileCallsBefore >= 2,
  'transient startup reconciliation failure did not retry with preserved provenance');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · persisted answer after transient reconciliation failure').length, 1);
assert.equal(faux.state.callCount, modelCallsBeforeTransientReconcile,
  'transient startup reconciliation failure reinjected durable Telegram input');

const permanentReconcileRequestId = 'tg-text-permanent-reconcile';
const permanentReconcileTurnId = 'telegram-permanent-reconcile';
const permanentReconcileState = state();
permanentReconcileState.request = {
  id: permanentReconcileRequestId, text: 'persisted request during unavailable state storage',
  status: 'claimed', owner: process.pid,
};
save(permanentReconcileState);
writeFileSync(`${home}/reject-mirror-reconcile`, '');
const permanentReconcilesBefore = state().log.filter((call) =>
  call[0] === 'mirror-reconcile' && call.includes(permanentReconcileRequestId)).length;
const modelCallsBeforePermanentReconcile = faux.state.callCount;
const fatalNoticesBeforePermanentReconcile = notices.filter(([message]) =>
  message === 'Telegram mirror state storage is unavailable; restore it and restart Pi before continuing.').length;
await runtime.newSession({
  setup: async (manager) => {
    manager.appendCustomEntry('firstmate-telegram-admission', {
      requestId: permanentReconcileRequestId, turnId: permanentReconcileTurnId,
      sessionId: manager.getSessionId(), state: 'admitted',
    });
    manager.appendMessage({
      role: 'user', content: [{ type: 'text', text: 'You · Telegram\n\npersisted request during unavailable state storage' }],
      timestamp: Date.now(),
    });
  },
});
await waitFor(() => state().log.filter((call) =>
  call[0] === 'mirror-reconcile' && call.includes(permanentReconcileRequestId)).length -
  permanentReconcilesBefore === 3,
'persistent startup reconciliation failure did not exhaust its bounded retry budget');
assert.equal(statuses.at(-1)?.[1], 'telegram: state storage needs recovery',
  'persistent startup reconciliation failure did not reach fatal storage recovery');
await new Promise((resolve) => setTimeout(resolve, 700));
assert.equal(state().log.filter((call) =>
  call[0] === 'mirror-reconcile' && call.includes(permanentReconcileRequestId)).length -
  permanentReconcilesBefore, 3,
  'persistent startup reconciliation failure kept polling after its bounded budget');
assert.equal(state().request?.id, permanentReconcileRequestId,
  'persistent startup reconciliation failure discarded durable admission evidence');
assert.equal(faux.state.callCount, modelCallsBeforePermanentReconcile,
  'persistent startup reconciliation failure ran another model turn');
assert.equal(notices.filter(([message]) =>
  message === 'Telegram mirror state storage is unavailable; restore it and restart Pi before continuing.').length,
  fatalNoticesBeforePermanentReconcile + 1,
  'persistent startup reconciliation failure did not notify exactly once');
unlinkSync(`${home}/reject-mirror-reconcile`);
await runtime.session.reload();
await waitFor(() => state().abandoned?.some(([id]) => id === permanentReconcileRequestId),
  'storage recovery did not abandon the preserved reconciliation-failure admission');

const receiptFailureManager = runtime.session.sessionManager;
const receiptFailureRequestId = 'tg-text-u28-m28';
const receiptFailureTurnId = 'telegram-tg-text-u28-m28-persisted';
const receiptFailureState = state();
receiptFailureState.request = {
  id: receiptFailureRequestId, text: 'persisted request with failed admission receipt',
  status: 'claimed', owner: process.pid,
};
save(receiptFailureState);
receiptFailureManager.appendCustomEntry('firstmate-telegram-admission', {
  requestId: receiptFailureRequestId, turnId: receiptFailureTurnId,
  sessionId: receiptFailureManager.getSessionId(), state: 'admitted',
});
receiptFailureManager.appendMessage({
  role: 'user', content: [{ type: 'text', text: 'You · Telegram\n\npersisted request with failed admission receipt' }],
  timestamp: Date.now(),
});
receiptFailureManager.appendMessage(fauxAssistantMessage('persisted answer despite failed admission receipt'));
writeFileSync(`${home}/reject-delivered-receipt`, '');
const callsBeforeReceiptFailureRestart = faux.state.callCount;
await runtime.newSession({ parentSession: receiptFailureManager.getSessionFile() });
await waitFor(() => state().handled?.includes(receiptFailureRequestId),
  'failed admission receipt released durable Telegram provenance');
unlinkSync(`${home}/reject-delivered-receipt`);
assert.equal(userTexts(runtime.session.sessionManager).length, 0,
  'failed admission receipt reinjected the persisted Telegram request');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · persisted answer despite failed admission receipt').length, 1);
assert.equal(state().receipt_unknown?.filter((id) => id === receiptFailureRequestId).length, 1);
assert.equal(faux.state.callCount, callsBeforeReceiptFailureRestart,
  'failed admission receipt started a second model pass');

const slashRecoveryManager = runtime.session.sessionManager;
const slashRecoveryRequestId = 'tg-text-u30-m30';
const slashRecoveryTurnId = 'telegram-tg-text-u30-m30-persisted';
const slashRecoveryState = state();
slashRecoveryState.request = {
  id: slashRecoveryRequestId, text: 'persisted Telegram before excluded slash',
  status: 'claimed', owner: process.pid,
};
save(slashRecoveryState);
slashRecoveryManager.appendCustomEntry('firstmate-telegram-admission', {
  requestId: slashRecoveryRequestId, turnId: slashRecoveryTurnId,
  sessionId: slashRecoveryManager.getSessionId(), state: 'admitted',
});
slashRecoveryManager.appendMessage({
  role: 'user', content: [{ type: 'text', text: 'You · Telegram\n\npersisted Telegram before excluded slash' }],
  timestamp: Date.now(),
});
slashRecoveryManager.appendMessage(fauxAssistantMessage([
  fauxToolCall('mirror_test_tool', {}, { id: 'persisted-slash-tool-call' }),
], { stopReason: 'toolUse' }));
slashRecoveryManager.appendMessage({
  role: 'user', content: [{ type: 'text', text: 'Expanded slash prompt body\n' }],
  firstmateExcludedSlash: persistedSlash.message.firstmateExcludedSlash,
  timestamp: Date.now(),
});
slashRecoveryManager.appendMessage(fauxAssistantMessage('persisted answer after excluded slash'));
const callsBeforeSlashRecovery = faux.state.callCount;
await runtime.newSession({ parentSession: slashRecoveryManager.getSessionFile() });
await waitFor(() => state().handled?.includes(slashRecoveryRequestId),
  'restart did not settle a persisted response after an excluded slash continuation');
assert.equal(userTexts(runtime.session.sessionManager).length, 0,
  'restart reinjected a persisted Telegram conversation with an excluded slash continuation');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · persisted answer after excluded slash').length, 1);
assert.equal(faux.state.callCount, callsBeforeSlashRecovery,
  'restart ran the model for a persisted excluded-slash conversation');

const carriedManager = runtime.session.sessionManager;
const carriedRequestId = 'tg-text-u24-m24';
const carriedTurnId = 'terminal-persisted-carried-turn';
const carriedState = state();
carriedState.request = {
  id: carriedRequestId, text: 'persisted Telegram before terminal steer',
  status: 'claimed', owner: process.pid,
};
save(carriedState);
carriedManager.appendCustomEntry('firstmate-telegram-admission', {
  requestId: carriedRequestId, turnId: carriedTurnId,
  sessionId: carriedManager.getSessionId(), state: 'carried',
});
carriedManager.appendMessage({
  role: 'user', content: [{ type: 'text', text: 'You · Terminal\n\npersisted terminal steer' }],
  timestamp: Date.now(),
});
carriedManager.appendMessage(fauxAssistantMessage('persisted answer after terminal steer'));
const callsBeforeCarriedRestart = faux.state.callCount;
await runtime.newSession({ parentSession: carriedManager.getSessionFile() });
await waitFor(() => state().handled?.includes(carriedRequestId),
  'restart did not settle a persisted Telegram request carried by a terminal steer');
assert.equal(userTexts(runtime.session.sessionManager).length, 0,
  'restart reinjected a persisted carried Telegram conversation');
assert.equal(Object.values(state().deliveries)
  .filter((body) => body === 'Firstmate · persisted answer after terminal steer').length, 1);
assert.equal(faux.state.callCount, callsBeforeCarriedRestart,
  'restart ran the model for a persisted carried Telegram conversation');

const unmatchedCarriedManager = runtime.session.sessionManager;
const unmatchedCarriedRequestId = 'tg-text-u25-m25';
const unmatchedCarriedState = state();
unmatchedCarriedState.request = {
  id: unmatchedCarriedRequestId, text: 'durable Telegram before unmatched terminal steer',
  status: 'claimed', owner: process.pid,
};
save(unmatchedCarriedState);
unmatchedCarriedManager.appendCustomEntry('firstmate-telegram-admission', {
  requestId: unmatchedCarriedRequestId, turnId: 'durable-telegram-before-unmatched-carried',
  sessionId: unmatchedCarriedManager.getSessionId(), state: 'admitted',
});
unmatchedCarriedManager.appendMessage({
  role: 'user', content: [{ type: 'text', text: 'You · Telegram\n\ndurable Telegram before unmatched terminal steer' }],
  timestamp: Date.now(),
});
unmatchedCarriedManager.appendMessage(fauxAssistantMessage([], { stopReason: 'toolUse' }));
unmatchedCarriedManager.appendCustomEntry('firstmate-telegram-admission', {
  requestId: unmatchedCarriedRequestId, turnId: 'unmatched-carried-terminal-turn',
  sessionId: unmatchedCarriedManager.getSessionId(), state: 'carried',
});
const callsBeforeUnmatchedCarriedRestart = faux.state.callCount;
await runtime.newSession({ parentSession: unmatchedCarriedManager.getSessionFile() });
await waitFor(() => state().handled?.includes(unmatchedCarriedRequestId),
  'restart did not abandon a durable admission hidden by an unmatched carried marker');
assert.equal(userTexts(runtime.session.sessionManager).length, 0,
  'restart reinjected a durable admission hidden by an unmatched carried marker');
assert.equal(faux.state.callCount, callsBeforeUnmatchedCarriedRestart,
  'restart ran the model after an unmatched carried marker hid a durable admission');

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
