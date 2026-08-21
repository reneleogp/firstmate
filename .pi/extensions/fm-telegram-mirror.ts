// One-primary Telegram mirror for the current Firstmate home.
// Python owns Telegram transport, authentication, queueing, voice, retention, and delivery.
// This extension only admits one live Pi conversation turn and fans out its settled body.
import { existsSync, readFileSync, writeFileSync, mkdirSync, unlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Origin = "terminal" | "telegram";
type AssistantMessage = { role?: string; content?: unknown };

const extensionRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const home = resolve(process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || extensionRoot);
const configDir = resolve(process.env.FM_CONFIG_OVERRIDE || resolve(home, "config"));
const stateDir = resolve(home, "state");
const transport = resolve(extensionRoot, "bin", "fm-telegram.py");
const modePath = resolve(configDir, "telegram-mirror");
const sessionLockLib = resolve(extensionRoot, "bin", "fm-session-lock-lib.sh");
const statusKey = "firstmate-telegram";

function mode(): "on" | "off" {
  try {
    return readFileSync(modePath, "utf8").trim() === "on" ? "on" : "off";
  } catch {
    return "off";
  }
}

function ownsHomeLock(): boolean {
  if (!existsSync(resolve(stateDir, ".lock"))) return false;
  try {
    execFileSync(
      "/bin/bash",
      ["-c", '. "$1"; fm_session_lock_owned_by_self "$2"', "fm-telegram-mirror", sessionLockLib, stateDir],
      { stdio: "ignore" },
    );
    return true;
  } catch {
    return false;
  }
}

function textOf(message: AssistantMessage): string {
  if (!Array.isArray(message.content)) return typeof message.content === "string" ? message.content : "";
  return message.content
    .filter((part): part is { type: "text"; text: string } =>
      !!part && typeof part === "object" && (part as { type?: string }).type === "text" &&
      typeof (part as { text?: unknown }).text === "string")
    .map((part) => part.text)
    .join("");
}

export default function (pi: ExtensionAPI) {
  let active = false;
  let activeOrigin: Origin | undefined;
  let activeRequest: string | undefined;
  let injectionToken: { requestId: string } | undefined;
  let lastAssistantBody = "";
  let scanTimer: ReturnType<typeof setInterval> | undefined;
  let drainRunning = false;
  let terminalTurn = 0;

  const exec = async (args: string[], ctx?: ExtensionContext) =>
    pi.exec(transport, ["--home", home, ...args], {
      cwd: home,
      signal: ctx?.signal,
      timeout: 30_000,
    });

  const updateFooter = async (ctx: ExtensionContext): Promise<void> => {
    if (!ownsHomeLock()) {
      ctx.ui.setStatus(statusKey, "telegram: not the primary session");
      return;
    }
    const current = mode();
    let waiting = 0;
    const result = await exec(["mirror-next"]);
    if (result.code === 0) waiting = 1;
    ctx.ui.setStatus(statusKey, current === "on" && waiting ? `telegram: on · queued` : `telegram: ${current}`);
  };

  const drain = async (ctx: ExtensionContext): Promise<void> => {
    if (drainRunning || !ownsHomeLock() || mode() !== "on") return;
    drainRunning = true;
    try {
      await exec(["mirror-reconcile"]);
      if (!ctx.isIdle() || active) return;
      const next = await exec(["mirror-next"]);
      const requestId = next.code === 0 ? next.stdout.trim().split("\n")[0] : "";
      if (!requestId) return;
      const claimed = await exec(["mirror-claim", requestId, "--owner-pid", String(process.pid)]);
      if (claimed.code !== 0) return;
      const body = await exec(["mirror-read", requestId, "--owner-pid", String(process.pid)]);
      if (body.code !== 0) {
        await exec(["mirror-release", requestId, "--owner-pid", String(process.pid)]);
        return;
      }
      active = true;
      activeOrigin = "telegram";
      activeRequest = requestId;
      lastAssistantBody = "";
      injectionToken = { requestId };
      try {
        const deliverAs = ctx.isIdle() ? undefined : "followUp" as const;
        pi.sendUserMessage(body.stdout, deliverAs ? { deliverAs } : undefined);
        await exec(["mirror-delivered", requestId, "--owner-pid", String(process.pid)]);
      } catch {
        injectionToken = undefined;
        active = false;
        activeOrigin = undefined;
        activeRequest = undefined;
        await exec(["mirror-release", requestId, "--owner-pid", String(process.pid)]);
      }
    } finally {
      drainRunning = false;
      await updateFooter(ctx);
    }
  };

  pi.registerCommand("telegram", {
    description: "Toggle the private Telegram mirror: /telegram on | off | status",
    handler: async (args, ctx) => {
      const action = args.trim();
      if (action !== "on" && action !== "off" && action !== "status") {
        ctx.ui.notify("Usage: /telegram on | off | status", "warning");
        return;
      }
      if (!ownsHomeLock()) {
        ctx.ui.notify("This Firstmate session is not the primary home session.", "warning");
        return;
      }
      const result = await exec(["mirror-mode", action, "--owner-pid", String(process.pid)], ctx);
      if (result.code !== 0) {
        ctx.ui.notify("Telegram mirror preference could not be changed.", "error");
        return;
      }
      ctx.ui.notify(action === "status" ? `Telegram mirror is ${result.stdout.trim()}.` : result.stdout.trim(), "info");
      await updateFooter(ctx);
      if (action === "on") void drain(ctx);
    },
  });

  pi.on("session_start", async (_event, ctx) => {
    active = false;
    activeOrigin = undefined;
    activeRequest = undefined;
    injectionToken = undefined;
    lastAssistantBody = "";
    if (ownsHomeLock()) {
      await exec(["mirror-reconcile"]);
      await updateFooter(ctx);
      scanTimer = setInterval(() => void drain(ctx), 750);
      void drain(ctx);
    } else {
      ctx.ui.setStatus(statusKey, "telegram: not the primary session");
    }
  });

  pi.on("session_shutdown", () => {
    if (scanTimer) clearInterval(scanTimer);
    scanTimer = undefined;
    active = false;
    activeOrigin = undefined;
    activeRequest = undefined;
    injectionToken = undefined;
  });

  // Input provenance is supplied by Pi.  The extension token is consumed only
  // for its own admission; body equality is never used to infer origin.
  pi.on("input", (event) => {
    if (event.source === "interactive" && !event.text.startsWith("/")) {
      activeOrigin = "terminal";
      activeRequest = undefined;
      active = true;
      lastAssistantBody = "";
      terminalTurn += 1;
    } else if (event.source === "extension" && injectionToken) {
      activeOrigin = "telegram";
      activeRequest = injectionToken.requestId;
      active = true;
      lastAssistantBody = "";
      injectionToken = undefined;
    }
    return { action: "continue" };
  });

  pi.on("user_bash", () => {
    active = false;
    activeOrigin = undefined;
    activeRequest = undefined;
    lastAssistantBody = "";
  });

  pi.on("message_end", async (event) => {
    const message = event.message as AssistantMessage & { firstmateOrigin?: Origin; stopReason?: string };
    if (message.role === "assistant" && active && message.stopReason !== "aborted" && message.stopReason !== "error") {
      const body = textOf(message);
      if (body) lastAssistantBody = body;
    }
    if (message.role === "user" && activeOrigin) {
      // The marker is presentation/authority metadata, not message body content.
      return { message: { ...message, firstmateOrigin: activeOrigin } as typeof event.message };
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    if (!active || !activeOrigin || !lastAssistantBody || !ownsHomeLock() || mode() !== "on") {
      active = false;
      activeOrigin = undefined;
      activeRequest = undefined;
      void drain(ctx);
      return;
    }
    const origin = activeOrigin;
    const request = activeRequest;
    const sessionId = ctx.sessionManager.getSessionId?.() || "session";
    const leaf = ctx.sessionManager.getLeafId?.() || `turn-${terminalTurn}`;
    const deliveryId = `${origin}-${sessionId}-${leaf}`.replace(/[^A-Za-z0-9._-]/g, "_");
    const bodyPath = resolve(stateDir, `.telegram-mirror-body-${process.pid}`);
    mkdirSync(dirname(bodyPath), { recursive: true, mode: 0o700 });
    writeFileSync(bodyPath, `Firstmate · ${lastAssistantBody}`, { mode: 0o600 });
    await exec(["mirror-reply", deliveryId, "--owner-pid", String(process.pid), "--text-file", bodyPath], ctx);
    try { unlinkSync(bodyPath); } catch { /* private temporary body is best-effort cleaned */ }
    active = false;
    activeOrigin = undefined;
    activeRequest = undefined;
    lastAssistantBody = "";
    await updateFooter(ctx);
    void drain(ctx);
  });
}
