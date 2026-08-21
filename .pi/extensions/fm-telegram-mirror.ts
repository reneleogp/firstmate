// Firstmate Telegram terminal mirror bridge for Pi.
//
// This extension is the Pi half of the WSL Telegram mirror. bin/fm-telegram.py
// owns Telegram, pairing, mirror mode, the in-memory inbound queue, voice
// transcription, and every Telegram reply. This half only:
//
//   - reports ordinary terminal submissions so the bot can mirror them,
//   - reports Firstmate's final visible reply after each completed run,
//   - submits queued Telegram text through Pi's normal user input, and
//   - confirms to the bot when Pi accepted each Telegram message.
//
// Telegram text reaches Firstmate exactly as terminal text: no origin marker,
// no hidden provenance, and no Telegram-specific instruction. Mirror mode,
// pairing, and all transport policy live in the bot, so this file carries no
// conversation state machine of its own.
//
// The bot owns the Unix socket (bin/fm-telegram.py's "bot.sock") and this
// extension is the client, because the bot outlives every Pi session. The wire
// protocol is stated once in that script's header.
import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { classifyFirstmateOperationalText } from "./lib/fm-operational-input.ts";

type BotFrame = {
  t?: string;
  id?: unknown;
  text?: unknown;
};

type AssistantPart = { type?: unknown; text?: unknown };
type FinalizedMessage = {
  role?: unknown;
  content?: unknown;
  stopReason?: unknown;
};

const RECONNECT_MS = positiveInteger("FM_TELEGRAM_RECONNECT_MS", 2000);
const RECONNECT_MAX_MS = positiveInteger("FM_TELEGRAM_RECONNECT_MAX_MS", 60000);
const COMMAND_TIMEOUT_MS = positiveInteger("FM_TELEGRAM_COMMAND_TIMEOUT_MS", 5000);
const MIRROR_COMMANDS = ["on", "off", "status"];

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function botSocketPath(): string {
  const home = process.env.FM_TELEGRAM_DIR || join(homedir(), ".firstmate-telegram");
  return join(home, "bot.sock");
}

function assistantText(message: unknown): string {
  const content = (message as { role?: string; content?: unknown } | undefined)?.content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((part): part is { type: "text"; text: string } =>
      typeof part === "object" && part !== null &&
      (part as { type?: unknown }).type === "text" &&
      typeof (part as { text?: unknown }).text === "string")
    .map((part) => part.text)
    .join("")
    .trim();
}

// The one white reply Pi shows the captain at the end of a response, and nothing
// else. Thinking blocks are not text parts, so they never reach here. A message
// carrying tool calls is the narration Pi prints beside its tool activity rather
// than the answer, and Pi's agent loop follows it with another assistant
// message. "stop" and "length" are the two ways a model actually ends a
// response; "toolUse", "aborted", "error", "pending", and "deferred" are not
// completed answers.
//
// This is decided per finalized message rather than when the agent settles.
// Pi runs back-to-back submissions as one continuous run, so five queued
// messages produce five visible replies but only one settle. Flushing one
// remembered reply at settle mirrored the last one and silently lost the rest,
// whatever origin the submissions came from.
function finalVisibleReply(message: unknown): string {
  const finalized = message as FinalizedMessage | undefined;
  if (finalized?.role !== "assistant") return "";
  const content = finalized.content;
  if (!Array.isArray(content)) return "";
  if (content.some((part: AssistantPart) => part?.type === "toolCall")) return "";
  if (finalized.stopReason !== "stop" && finalized.stopReason !== "length") return "";
  return assistantText(message);
}

export default function (pi: ExtensionAPI) {
  const socketPath = botSocketPath();
  let socket: Socket | null = null;
  let buffer = "";
  let stopped = false;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectDelay = RECONNECT_MS;
  let deliveries: Promise<void> = Promise.resolve();
  let commandSequence = 0;
  const commandWaiters = new Map<number, (text: string) => void>();

  function write(frame: Record<string, unknown>): boolean {
    if (!socket || socket.destroyed) return false;
    try {
      socket.write(`${JSON.stringify(frame)}\n`);
      return true;
    } catch {
      return false;
    }
  }

  // A home that never installed the bot retries on a widening delay rather than
  // hammering a socket that will never exist, and a real connection resets it.
  function scheduleReconnect(): void {
    if (stopped || reconnectTimer) return;
    const delay = reconnectDelay;
    reconnectDelay = Math.min(RECONNECT_MAX_MS, reconnectDelay * 2);
    const timer = setTimeout(() => {
      reconnectTimer = null;
      openSocket();
    }, delay);
    timer.unref?.();
    reconnectTimer = timer;
  }

  function closeSocket(): void {
    const current = socket;
    socket = null;
    buffer = "";
    if (current) {
      current.removeAllListeners();
      current.destroy();
    }
  }

  function openSocket(): void {
    if (stopped || socket) return;
    const client = connect(socketPath);
    socket = client;
    client.on("connect", () => {
      reconnectDelay = RECONNECT_MS;
      write({ t: "hello" });
    });
    client.on("data", (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      let index = buffer.indexOf("\n");
      while (index >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (line.trim()) handleFrame(line);
        index = buffer.indexOf("\n");
      }
    });
    const drop = (): void => {
      if (socket !== client) return;
      closeSocket();
      scheduleReconnect();
    };
    client.on("error", drop);
    client.on("close", drop);
  }

  function handleFrame(line: string): void {
    let frame: BotFrame;
    try {
      frame = JSON.parse(line) as BotFrame;
    } catch {
      return;
    }
    if (frame.t === "deliver" && typeof frame.text === "string" && typeof frame.id === "string") {
      queueDelivery(frame.id, frame.text);
      return;
    }
    if (frame.t === "command_result" && typeof frame.id === "number") {
      const waiter = commandWaiters.get(frame.id);
      if (waiter) {
        commandWaiters.delete(frame.id);
        waiter(typeof frame.text === "string" ? frame.text : "");
      }
    }
  }

  // Telegram arrival order is the socket's order, so each delivery is submitted
  // on one chain, in that order. Pi keeps its own batching, steering, and
  // continuation behavior from there. "steer" is what Pi's own terminal uses
  // for text submitted while a run is streaming, and Pi ignores it when idle,
  // so this is the same path as typing the message in the terminal.
  function queueDelivery(id: string, text: string): void {
    deliveries = deliveries.then(async () => {
      await pi.sendUserMessage(text, { deliverAs: "steer" });
      write({ t: "accepted", id });
    }).catch((error: unknown) => {
      const detail = error instanceof Error ? error.message : String(error);
      console.error(`fm-telegram-mirror: could not submit a Telegram message: ${detail}`);
    });
  }

  function sendCommand(command: string): Promise<string> {
    if (!socket || socket.destroyed) {
      return Promise.resolve("Telegram mirror bot is not running.");
    }
    commandSequence += 1;
    const id = commandSequence;
    return new Promise<string>((resolveCommand) => {
      const timer = setTimeout(() => {
        commandWaiters.delete(id);
        resolveCommand("Telegram mirror bot did not answer.");
      }, COMMAND_TIMEOUT_MS);
      timer.unref?.();
      commandWaiters.set(id, (text) => {
        clearTimeout(timer);
        resolveCommand(text || "Telegram mirror bot returned no status.");
      });
      if (!write({ t: "command", id, command })) {
        clearTimeout(timer);
        commandWaiters.delete(id);
        resolveCommand("Telegram mirror bot is not running.");
      }
    });
  }

  pi.on?.("session_start", () => {
    stopped = false;
    reconnectDelay = RECONNECT_MS;
    openSocket();
  });

  pi.on?.("session_shutdown", () => {
    stopped = true;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = null;
    closeSocket();
  });

  // Ordinary captain submissions typed in the terminal. Telegram-originated
  // text arrives as source "extension" and is already visible in Telegram, so
  // it is never echoed back, and Firstmate's own operational input is never
  // mirrored at all.
  pi.on?.("input", (event) => {
    if (event.source !== "interactive") return;
    if (typeof event.text !== "string" || !event.text.trim()) return;
    if (classifyFirstmateOperationalText(event.text) !== undefined) return;
    write({ t: "terminal", text: event.text });
  });

  // Every completed reply is mirrored as Pi finalizes it, exactly once.
  pi.on?.("message_end", (event) => {
    const text = finalVisibleReply(event.message);
    if (text) write({ t: "reply", text });
  });

  pi.registerCommand?.("telegram", {
    description: "Turn the Telegram terminal mirror on or off, or show its status.",
    getArgumentCompletions: (prefix: string) => {
      const items = MIRROR_COMMANDS
        .filter((value) => value.startsWith(prefix))
        .map((value) => ({ value, label: value }));
      return items.length > 0 ? items : null;
    },
    handler: async (args, ctx) => {
      const command = (args || "").trim().split(/\s+/)[0] || "status";
      if (!MIRROR_COMMANDS.includes(command)) {
        ctx.ui.notify("Usage: /telegram on | off | status", "warning");
        return;
      }
      ctx.ui.notify(await sendCommand(command), "info");
    },
  });
}
