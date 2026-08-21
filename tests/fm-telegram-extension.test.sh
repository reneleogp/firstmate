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

OUT="$TMP_ROOT/node-output"
if ! (cd "$TMP_ROOT" && \
  EXT="$ROOT/.pi/extensions/fm-telegram-mirror.ts" \
  OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh" \
  FM_TELEGRAM_DIR="$TMP_ROOT/home" \
  node --input-type=module >"$OUT" 2>&1) <<'JS'
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const home = process.env.FM_TELEGRAM_DIR;
mkdirSync(home, { recursive: true });
const socketPath = join(home, "bot.sock");

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
let idle = true;
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand(name, definition) {
    if (name === "telegram") commandDefinition = definition;
  },
  sendUserMessage(content, options) {
    submissions.push({ content, options });
  },
};
const ctx = {
  isIdle: () => idle,
  ui: { notify: (message, level) => notifications.push({ message, level }) },
};

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

// 2. Only the final visible assistant text is mirrored, once the run settles.
const assistantMessage = (content) => ({ message: { role: "assistant", content } });
handlers.get("message_end")(assistantMessage([
  { type: "thinking", thinking: "internal reasoning" },
  { type: "text", text: "Looking into it." },
  { type: "toolCall", id: "1", name: "bash", arguments: { command: "ls" } },
]), ctx);
handlers.get("message_end")({ message: { role: "toolResult", content: "shell output" } }, ctx);
handlers.get("message_end")(assistantMessage([
  { type: "thinking", thinking: "more internal reasoning" },
  { type: "text", text: "The test fails on the release branch." },
]), ctx);
if (received.some((frame) => frame.t === "reply")) {
  fail("a reply was mirrored before the run settled");
}
handlers.get("agent_settled")({}, ctx);
await waitFor(() => received.some((frame) => frame.t === "reply"), "a reply frame");
const replies = received.filter((frame) => frame.t === "reply");
if (replies.length !== 1 || replies[0].text !== "The test fails on the release branch.") {
  fail(`unexpected reply mirroring: ${JSON.stringify(replies)}`);
}
handlers.get("agent_settled")({}, ctx);
await new Promise((resolve) => setTimeout(resolve, 100));
if (received.filter((frame) => frame.t === "reply").length !== 1) {
  fail("a settled run with no new assistant text mirrored a stale reply");
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

// 5. /telegram from Pi is transport, never conversation text.
const submissionsBeforeCommand = submissions.length;
onFrame = (frame) => {
  if (frame.t === "command") botWrite({ t: "command_result", id: frame.id, text: "Mirror is on. Firstmate is connected." });
};
await commandDefinition.handler("status", ctx);
const command = received.find((frame) => frame.t === "command");
if (!command || command.command !== "status") {
  fail(`the /telegram command did not reach the bot: ${JSON.stringify(received)}`);
}
if (submissions.length !== submissionsBeforeCommand) {
  fail("/telegram was sent to Firstmate as conversation text");
}
if (notifications.at(-1)?.message !== "Mirror is on. Firstmate is connected.") {
  fail(`the bot status was not reported in Pi: ${JSON.stringify(notifications)}`);
}

// 6. Shutdown releases the connection and stops reconnecting, and a later
//    session start (/new, /resume, /fork, reload) reconnects.
handlers.get("session_shutdown")({ reason: "quit" }, ctx);
await new Promise((resolve) => setTimeout(resolve, 100));
const connectionsAfterShutdown = connections;
await new Promise((resolve) => setTimeout(resolve, 400));
if (connections !== connectionsAfterShutdown) {
  fail("the bridge reconnected after the session shut down");
}
handlers.get("session_start")({ reason: "resume" }, ctx);
await waitFor(() => connections > connectionsAfterShutdown, "a reconnect on the next session");
handlers.get("session_shutdown")({ reason: "quit" }, ctx);
server.close();
JS
then
  fail "Telegram mirror extension checks failed: $(cat "$OUT")"
fi
[ -s "$OUT" ] && fail "Telegram mirror extension test printed output: $(cat "$OUT")"

pass "the Pi mirror bridge mirrors terminal submissions and final replies only, hides thinking, tools, and operational input, and submits queued Telegram text through Pi's own input path in order"
