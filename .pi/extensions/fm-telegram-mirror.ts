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
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { connect, type Socket } from "node:net";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { getSettingsListTheme, type ExtensionAPI, type ExtensionContext }
  from "@earendil-works/pi-coding-agent";
import { Container, type SettingItem, SettingsList, Text } from "@earendil-works/pi-tui";
import { classifyFirstmateOperationalText } from "./lib/fm-operational-input.ts";

type BotFrame = {
  t?: string;
  id?: unknown;
  text?: unknown;
  image?: unknown;
  mirror?: unknown;
  confirmations?: unknown;
};

type QueuedImage = { data: string; mime: string };

type AssistantPart = { type?: unknown; text?: unknown };
type FinalizedMessage = {
  role?: unknown;
  content?: unknown;
  stopReason?: unknown;
};

const RECONNECT_MS = positiveInteger("FM_TELEGRAM_RECONNECT_MS", 2000);
const RECONNECT_MAX_MS = positiveInteger("FM_TELEGRAM_RECONNECT_MAX_MS", 60000);
const COMMAND_TIMEOUT_MS = positiveInteger("FM_TELEGRAM_COMMAND_TIMEOUT_MS", 5000);
// The footer item Pi renders, and the only Pi-side preference: whether that
// item is shown. It is stored beside the bot's private directory so it survives
// a restart and can still be read while the bot is unreachable.
const FOOTER_KEY = "firstmate-telegram";
const DISPLAY_SETTING_FILE = "pi-display-status";

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function botHome(): string {
  return process.env.FM_TELEGRAM_DIR || join(homedir(), ".firstmate-telegram");
}

function botSocketPath(): string {
  return join(botHome(), "bot.sock");
}

// Only the one Firstmate session the captain is talking to may mirror. Every
// crewmate and scout is a Pi session too, and a globally installed copy of this
// extension loads in all of them, so without this gate a worker's brief, its
// replies and its tool activity would flow into the captain's private chat the
// moment it connected. Primacy is decided the way the tracked watcher extension
// decides it: the Firstmate home's session lock names the live session, and only
// a process inside that session's own ancestry owns it.
function firstmateHome(): string {
  return process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE ||
    resolve(dirname(fileURLToPath(import.meta.url)), "../..");
}

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function ownsSessionLock(): boolean {
  const stateDir = process.env.FM_STATE_OVERRIDE || join(firstmateHome(), "state");
  let lockPid = "";
  try {
    lockPid = readFileSync(join(stateDir, ".lock"), "utf8").trim();
  } catch {
    return false;
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return false;
  let pid = String(process.pid);
  for (let step = 0; step < 8; step += 1) {
    if (pid === lockPid) return true;
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return false;
}

function readDisplayStatus(): boolean {
  try {
    return readFileSync(join(botHome(), DISPLAY_SETTING_FILE), "utf8").trim() !== "off";
  } catch {
    return true;
  }
}

function writeDisplayStatus(shown: boolean): void {
  try {
    const home = botHome();
    if (!existsSync(home)) mkdirSync(home, { recursive: true, mode: 0o700 });
    writeFileSync(join(home, DISPLAY_SETTING_FILE), shown ? "on\n" : "off\n", { mode: 0o600 });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(`fm-telegram-mirror: could not persist the status display choice: ${detail}`);
  }
}

function asQueuedImage(value: unknown): QueuedImage | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const candidate = value as { data?: unknown; mime?: unknown };
  if (typeof candidate.data !== "string" || typeof candidate.mime !== "string") return undefined;
  return { data: candidate.data, mime: candidate.mime };
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
  // A worker session stays completely inert: no socket, no footer, no commands.
  if (!ownsSessionLock()) return;
  const socketPath = botSocketPath();
  let socket: Socket | null = null;
  let buffer = "";
  let stopped = false;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let reconnectDelay = RECONNECT_MS;
  let deliveries: Promise<void> = Promise.resolve();
  let commandSequence = 0;
  const commandWaiters = new Map<number, (text: string) => void>();

  // Footer state. "unavailable" is the honest answer whenever the bot's socket
  // is not connected, because mirror mode then has no reachable owner.
  let activeCtx: ExtensionContext | null = null;
  let connected = false;
  let mirrorOn = false;
  let confirmations = true;
  let displayStatus = readDisplayStatus();

  function footerText(): string {
    if (!connected) return "telegram: unavailable";
    return mirrorOn ? "telegram: on" : "telegram: off";
  }

  function refreshFooter(): void {
    activeCtx?.ui?.setStatus?.(FOOTER_KEY, displayStatus ? footerText() : undefined);
  }

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
      connected = true;
      refreshFooter();
      // The bot sends only what this bridge announces it can deliver, so an
      // older bridge never receives an image it would silently drop.
      write({ t: "hello", features: ["image"] });
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
      connected = false;
      refreshFooter();
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
      queueDelivery(frame.id, frame.text, asQueuedImage(frame.image));
      return;
    }
    if (frame.t === "state") {
      if (typeof frame.mirror === "boolean") mirrorOn = frame.mirror;
      if (typeof frame.confirmations === "boolean") confirmations = frame.confirmations;
      refreshFooter();
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
  //
  // A screenshot travels the same way, as Pi's own image content, so Firstmate
  // receives exactly what pasting it into the terminal would send.
  function queueDelivery(id: string, text: string, image?: QueuedImage): void {
    deliveries = deliveries.then(async () => {
      if (image) {
        const content: Array<Record<string, unknown>> = [];
        if (text.trim()) content.push({ type: "text", text });
        content.push({ type: "image", data: image.data, mimeType: image.mime });
        await pi.sendUserMessage(content as never, { deliverAs: "steer" });
      } else {
        await pi.sendUserMessage(text, { deliverAs: "steer" });
      }
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

  pi.on?.("session_start", (_event, ctx) => {
    activeCtx = ctx;
    stopped = false;
    reconnectDelay = RECONNECT_MS;
    displayStatus = readDisplayStatus();
    refreshFooter();
    openSocket();
  });

  pi.on?.("session_shutdown", () => {
    stopped = true;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = null;
    closeSocket();
    connected = false;
    activeCtx?.ui?.setStatus?.(FOOTER_KEY, undefined);
    activeCtx = null;
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
    description: "Toggle the Telegram terminal mirror.",
    handler: async (_args, ctx) => {
      activeCtx = ctx;
      ctx.ui.notify(await sendCommand("toggle"), "info");
    },
  });

  pi.registerCommand?.("telegram-settings", {
    description: "Show and change the Telegram mirror settings.",
    handler: async (_args, ctx) => {
      activeCtx = ctx;
      if (ctx.mode !== "tui") {
        ctx.ui.notify(
          `Telegram settings: display status ${displayStatus ? "on" : "off"}, ` +
          `delivery confirmations ${connected ? (confirmations ? "on" : "off") : "unavailable"}.`,
          "info",
        );
        return;
      }
      const items: SettingItem[] = [
        {
          id: "display",
          label: "Display Telegram status",
          currentValue: displayStatus ? "on" : "off",
          values: ["on", "off"],
        },
        {
          id: "confirmations",
          label: "Delivery confirmations",
          currentValue: connected ? (confirmations ? "on" : "off") : "unavailable",
          values: connected ? ["on", "off"] : ["unavailable"],
        },
      ];
      await ctx.ui.custom((_tui, theme, _keybindings, done) => {
        const container = new Container();
        container.addChild(new Text(theme.fg("accent", theme.bold("Telegram mirror")), 1, 1));
        const list = new SettingsList(
          items,
          Math.min(items.length + 2, 15),
          getSettingsListTheme(),
          (id, value) => {
            if (id === "display") {
              displayStatus = value === "on";
              writeDisplayStatus(displayStatus);
              refreshFooter();
              return;
            }
            if (id === "confirmations") {
              if (!connected) {
                ctx.ui.notify("The Telegram mirror bot is not running.", "warning");
                return;
              }
              // The bot owns this setting for both surfaces; its state frame is
              // what updates the local copy.
              write({ t: "set", setting: "confirmations", value: value === "on" });
            }
          },
          () => done(undefined),
          { enableSearch: false },
        );
        container.addChild(list);
        return {
          render: (width: number) => container.render(width),
          invalidate: () => container.invalidate(),
          handleInput: (data: string) => list.handleInput?.(data),
        };
      });
    },
  });
}
