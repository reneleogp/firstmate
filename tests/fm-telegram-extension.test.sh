#!/usr/bin/env bash
# Focused behavior checks for the Pi half of the Telegram terminal mirror:
# what it mirrors, what it never mirrors, and how queued Telegram text reaches
# Pi's own user-input path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Telegram mirror extension test"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-telegram-extension)
trap fm_test_cleanup EXIT

printf 'const value: number = 1;\nexport default value;\n' >"$TMP_ROOT/probe.ts"
if ! node -e 'import(process.argv[1]).catch(() => process.exit(1))' "$TMP_ROOT/probe.ts" >/dev/null 2>&1; then
  echo "skip: this node does not strip TypeScript types"
  exit 0
fi

# The settings UI imports Pi's own TUI components, so the extension runs from a
# fixture whose node_modules point at the installed Pi package, the same way the
# tracked Pi extensions resolve them in a real session.
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}
if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
  echo "skip: installed @earendil-works/pi-coding-agent package not found"
  exit 0
fi
FIXTURE="$TMP_ROOT/ext"
mkdir -p "$FIXTURE/lib" "$FIXTURE/node_modules/@earendil-works"
# This node process stands in for the one live Firstmate session: the bridge
# only mirrors when it runs inside the session that holds the home's lock.
mkdir -p "$TMP_ROOT/fmhome/state" "$TMP_ROOT/workerhome/state"
cp "$ROOT/.pi/extensions/fm-telegram-mirror.ts" "$FIXTURE/fm-telegram-mirror.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$FIXTURE/lib/fm-operational-input.ts"
ln -s "$PI_PACKAGE_DIR" "$FIXTURE/node_modules/@earendil-works/pi-coding-agent"
ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-tui" "$FIXTURE/node_modules/@earendil-works/pi-tui"
printf '%s\n' '{"type":"module"}' >"$FIXTURE/package.json"

OUT="$TMP_ROOT/node-output"
if ! (cd "$FIXTURE" && \
  timeout 90 env \
  EXT="$FIXTURE/fm-telegram-mirror.ts" \
  OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh" \
  FM_OPERATIONAL_INPUT_SCRIPT="$ROOT/bin/fm-operational-input.sh" \
  FM_TELEGRAM_DIR="$TMP_ROOT/home" \
  FM_HOME="$TMP_ROOT/fmhome" \
  WORKER_HOME="$TMP_ROOT/workerhome" \
  node --input-type=module >"$OUT" 2>&1) <<'JS'
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const home = process.env.FM_TELEGRAM_DIR;
mkdirSync(home, { recursive: true });
const socketPath = join(home, "bot.sock");

// Bounded by construction: if any await below never settles, this fixture
// fails loudly instead of hanging the suite.
const watchdog = setTimeout(() => {
  console.error("fm-telegram-mirror fixture timed out before completing its checks");
  process.exit(3);
}, 45000);

const received = [];
let connections = 0;
let botWrite = null;
let onFrame = () => {};

const server = createServer((socket) => {
  connections += 1;
  botWrite = (frame) => socket.write(`${JSON.stringify(frame)}\n`);
  let buffer = "";
  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let index = buffer.indexOf("\n");
    while (index >= 0) {
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      if (line.trim()) {
        const frame = JSON.parse(line);
        received.push(frame);
        onFrame(frame);
      }
      index = buffer.indexOf("\n");
    }
  });
});
await new Promise((resolve) => server.listen(socketPath, resolve));

// Fake Pi: records exactly what the agent would have been asked to do.
const submissions = [];
const notifications = [];
const handlers = new Map();
let commandDefinition;
let settingsDefinition;
let idle = true;
const footer = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand(name, definition) {
    if (name === "telegram") commandDefinition = definition;
    if (name === "telegram-settings") settingsDefinition = definition;
  },
  sendUserMessage(content, options) {
    submissions.push({ content, options });
  },
};
const ctx = {
  isIdle: () => idle,
  mode: "print",
  ui: {
    notify: (message, level) => notifications.push({ message, level }),
    setStatus: (key, value) => {
      if (value === undefined) footer.delete(key);
      else footer.set(key, value);
    },
  },
};
const footerText = () => footer.get("firstmate-telegram");

// The live session's lock names this process, so this instance is the primary.
writeFileSync(join(process.env.FM_HOME, "state", ".lock"), `${process.pid}\n`);
const extension = await import(pathToFileURL(process.env.EXT).href);
extension.default(pi);
handlers.get("session_start")({ reason: "startup" }, ctx);

function fail(message) {
  throw new Error(message);
}

async function waitFor(predicate, description) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  fail(`timed out waiting for ${description}; frames=${JSON.stringify(received)}`);
}

await waitFor(() => botWrite !== null, "the extension to connect to the bot socket");
await waitFor(() => received.some((frame) => frame.t === "hello"), "a hello frame");

// 1. Ordinary terminal submissions are mirrored; Telegram-injected text and
//    Firstmate's own operational input are not.
handlers.get("input")({ text: "check the failing test", source: "interactive" }, ctx);
handlers.get("input")({ text: "queued from telegram", source: "extension" }, ctx);
const operational = execFileSync(process.env.OPERATIONAL_INPUT, ["encode", "watcher"], {
  input: "FIRSTMATE WATCHER WAKE: signal: probe",
  encoding: "utf8",
});
handlers.get("input")({ text: operational, source: "interactive" }, ctx);
await waitFor(() => received.some((frame) => frame.t === "terminal"), "a terminal frame");
await new Promise((resolve) => setTimeout(resolve, 200));
const terminalFrames = received.filter((frame) => frame.t === "terminal");
if (terminalFrames.length !== 1 || terminalFrames[0].text !== "check the failing test") {
  fail(`unexpected terminal mirroring: ${JSON.stringify(terminalFrames)}`);
}

// 2. Every completed reply is mirrored exactly once, as Pi finalizes it, while
//    thinking, tool narration, and tool results are never mirrored. The five
//    queued messages below are one continuous run with a single settle: the
//    regression this pins is Pi visibly answering five times while Telegram
//    received only the last reply.
const assistantMessage = (content, stopReason = "stop") =>
  ({ message: { role: "assistant", content, stopReason } });
const replyTexts = () => received.filter((frame) => frame.t === "reply").map((frame) => frame.text);

handlers.get("message_end")(assistantMessage([
  { type: "thinking", thinking: "internal reasoning" },
  { type: "text", text: "Looking into it." },
  { type: "toolCall", id: "1", name: "bash", arguments: { command: "ls" } },
], "toolUse"), ctx);
handlers.get("message_end")({ message: { role: "toolResult", content: "shell output" } }, ctx);
handlers.get("message_end")(assistantMessage([
  { type: "thinking", thinking: "more internal reasoning" },
  { type: "text", text: "Reply 1" },
]), ctx);
await waitFor(() => replyTexts().length === 1, "the first completed reply");
if (replyTexts()[0] !== "Reply 1") {
  fail(`mirrored the wrong text for the first reply: ${JSON.stringify(replyTexts())}`);
}

// Replies 2 to 5 finalize inside the same continuous run, before any settle.
for (const text of ["Reply 2", "Reply 3", "Reply 4", "Reply 5"]) {
  handlers.get("message_end")(assistantMessage([{ type: "text", text }]), ctx);
}
await waitFor(() => replyTexts().length === 5, "all five completed replies");
if (JSON.stringify(replyTexts())
    !== JSON.stringify(["Reply 1", "Reply 2", "Reply 3", "Reply 4", "Reply 5"])) {
  fail(`queued replies were lost or reordered: ${JSON.stringify(replyTexts())}`);
}

// The single settle that ends the whole continuous run must add nothing.
handlers.get("agent_settled")?.({}, ctx);
await new Promise((resolve) => setTimeout(resolve, 200));
if (replyTexts().length !== 5) {
  fail(`settling the continuous run duplicated a reply: ${JSON.stringify(replyTexts())}`);
}

// Interrupted, failed, and still-streaming messages are not completed answers.
for (const stopReason of ["aborted", "error", "pending", "deferred"]) {
  handlers.get("message_end")(assistantMessage([{ type: "text", text: `partial ${stopReason}` }], stopReason), ctx);
}
await new Promise((resolve) => setTimeout(resolve, 200));
if (replyTexts().length !== 5) {
  fail(`an uncompleted response was mirrored: ${JSON.stringify(replyTexts())}`);
}

// 3. Queued Telegram text enters Pi's own input path in arrival order, with no
//    origin marker, and each one is confirmed back to the bot.
botWrite({ t: "deliver", id: "m1", text: "first telegram message" });
botWrite({ t: "deliver", id: "m2", text: "second telegram message" });
await waitFor(
  () => received.filter((frame) => frame.t === "accepted").length === 2,
  "two accepted frames",
);
const accepted = received.filter((frame) => frame.t === "accepted").map((frame) => frame.id);
if (JSON.stringify(accepted) !== JSON.stringify(["m1", "m2"])) {
  fail(`accepted frames were out of order: ${JSON.stringify(accepted)}`);
}
if (JSON.stringify(submissions.map((entry) => entry.content))
    !== JSON.stringify(["first telegram message", "second telegram message"])) {
  fail(`Firstmate saw altered text: ${JSON.stringify(submissions)}`);
}
if (submissions.some((entry) => entry.options?.deliverAs !== "steer")) {
  fail(`a submission did not use Pi's own terminal steering path: ${JSON.stringify(submissions)}`);
}

// 4. Messages sent while Pi is working take the same path, so three sent
//    back-to-back reach Pi in arrival order instead of one per model run.
idle = false;
botWrite({ t: "deliver", id: "m3", text: "and one more while busy" });
await waitFor(() => submissions.length === 3, "the busy submission");
if (submissions[2].content !== "and one more while busy"
    || submissions[2].options?.deliverAs !== "steer") {
  fail(`busy submission did not use Pi's own steering: ${JSON.stringify(submissions[2])}`);
}
await waitFor(
  () => received.filter((frame) => frame.t === "accepted").length === 3,
  "the third accepted frame",
);
idle = true;

// 5. /telegram is transport, never conversation text: bare, it toggles.
const submissionsBeforeCommand = submissions.length;
onFrame = (frame) => {
  if (frame.t === "command") botWrite({ t: "command_result", id: frame.id, text: "Mirror is on. Firstmate is connected. Confirmations are on." });
};
await commandDefinition.handler("", ctx);
const command = received.find((frame) => frame.t === "command");
if (!command || command.command !== "toggle") {
  fail(`bare /telegram did not toggle through the bot: ${JSON.stringify(received)}`);
}
if (submissions.length !== submissionsBeforeCommand) {
  fail("/telegram was sent to Firstmate as conversation text");
}
if (notifications.at(-1)?.message !== "Mirror is on. Firstmate is connected. Confirmations are on.") {
  fail(`the bot status was not reported in Pi: ${JSON.stringify(notifications)}`);
}

// 6. The footer tracks whatever the bot last published, from either surface.
if (footerText() !== "telegram: off") {
  fail(`the footer did not start from the bot's state: ${footerText()}`);
}
botWrite({ t: "state", mirror: true, confirmations: true });
await waitFor(() => footerText() === "telegram: on", "the footer to follow a mirror change");
botWrite({ t: "state", mirror: false, confirmations: false });
await waitFor(() => footerText() === "telegram: off", "the footer to follow a mirror change back");

// The settings surface reads the same published values, with no Pi command for
// the individual mirror states any more.
if (commandDefinition.getArgumentCompletions) {
  fail("/telegram still advertises on/off/status arguments");
}
if (!settingsDefinition) fail("/telegram-settings was not registered");
await settingsDefinition.handler("", ctx);
if (!notifications.at(-1)?.message.includes("delivery confirmations off")) {
  fail(`settings did not report the published confirmations value: ${JSON.stringify(notifications.at(-1))}`);
}

// 7. Shutdown releases the connection and stops reconnecting, and a later
//    session start (/new, /resume, /fork, reload) reconnects.
handlers.get("session_shutdown")({ reason: "quit" }, ctx);
await new Promise((resolve) => setTimeout(resolve, 100));
if (footerText() !== undefined) {
  fail(`the footer survived session shutdown: ${footerText()}`);
}
const connectionsAfterShutdown = connections;
await new Promise((resolve) => setTimeout(resolve, 400));
if (connections !== connectionsAfterShutdown) {
  fail("the bridge reconnected after the session shut down");
}
handlers.get("session_start")({ reason: "resume" }, ctx);
await waitFor(() => connections > connectionsAfterShutdown, "a reconnect on the next session");

// 8. A worker session is inert. Crewmates and scouts are Pi sessions too, and a
//    globally installed copy of this bridge loads in every one of them; only
//    the session that holds the Firstmate home's lock may mirror.
const connectionsBeforeWorker = connections;
mkdirSync(join(process.env.WORKER_HOME, "state"), { recursive: true });
// A live pid that is not this process's ancestor: exactly a crewmate's shape.
writeFileSync(join(process.env.WORKER_HOME, "state", ".lock"), "1\n");
process.env.FM_HOME = process.env.WORKER_HOME;
const workerHandlers = new Map();
const workerCommands = [];
const workerFooter = new Map();
const worker = await import(`${pathToFileURL(process.env.EXT).href}?worker=${Date.now()}`);
worker.default({
  on: (event, handler) => workerHandlers.set(event, handler),
  registerCommand: (name) => workerCommands.push(name),
  sendUserMessage: () => fail("a worker session submitted text to Pi"),
});
if (workerHandlers.size !== 0 || workerCommands.length !== 0) {
  fail(`a worker session registered ${workerCommands.length} command(s) and ${workerHandlers.size} handler(s)`);
}
await new Promise((resolve) => setTimeout(resolve, 600));
if (connections !== connectionsBeforeWorker) {
  fail("a worker session connected to the Telegram bot");
}
if (workerFooter.size !== 0) {
  fail("a worker session published a Telegram footer");
}
process.env.FM_HOME = process.env.WORKER_HOME.replace("workerhome", "fmhome");

handlers.get("session_shutdown")({ reason: "quit" }, ctx);
await new Promise((resolve) => setTimeout(resolve, 50));
await new Promise((resolve) => server.close(resolve));
clearTimeout(watchdog);
JS
then
  fail "Telegram mirror extension checks failed: $(cat "$OUT")"
fi
[ -s "$OUT" ] && fail "Telegram mirror extension test printed output: $(cat "$OUT")"

pass "the Pi mirror bridge mirrors only the live session's terminal submissions and final replies, hides thinking, tools, and operational input, submits queued Telegram text through Pi's own input path in order, toggles with bare /telegram, keeps the footer on the bot's published state, and stays completely inert in a worker session"
