#!/usr/bin/env bash
# Opt-in smoke against the installed Pi runtime.
# It deliberately uses no Telegram token and no real home state.
set -u
if [ "${FM_TELEGRAM_PI_SMOKE:-}" != 1 ]; then
  echo "skip: set FM_TELEGRAM_PI_SMOKE=1 to run the installed Pi lifecycle smoke"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-telegram-smoke.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.pi/extensions" "$TMP/config" "$TMP/state"
cat >"$TMP/.pi/extensions/smoke.ts" <<'TS'
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { appendFileSync } from "node:fs";
export default function (pi: ExtensionAPI) {
  const out = process.env.FM_TELEGRAM_PI_SMOKE_OUT!;
  pi.on("input", (event) => { appendFileSync(out, `input:${event.source}:${event.text}\n`); });
  pi.on("message_end", (event) => { appendFileSync(out, `message:${event.message.role}\n`); });
  pi.on("agent_settled", (event, ctx) => { appendFileSync(out, "agent_settled\n"); ctx.shutdown(); });
  pi.on("session_start", () => { pi.sendUserMessage("telegram-smoke"); });
}
TS
OUT="$TMP/events"
: >"$OUT"
FM_TELEGRAM_PI_SMOKE_OUT="$OUT" pi --no-session --print -e "$TMP/.pi/extensions/smoke.ts" </dev/null >/dev/null 2>&1 || {
  echo "Pi lifecycle smoke failed; inspect the installed Pi/runtime configuration" >&2
  exit 1
}
grep -F 'input:extension:telegram-smoke' "$OUT" >/dev/null || {
  echo "Pi lifecycle smoke did not observe extension input provenance" >&2
  exit 1
}
grep -F 'agent_settled' "$OUT" >/dev/null || {
  echo "Pi lifecycle smoke did not observe agent_settled" >&2
  exit 1
}
echo "pass: installed Pi sendUserMessage input/message lifecycle and agent_settled smoke"
