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
