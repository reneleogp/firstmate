# Telegram mirror mode

This optional transport connects one pinned private Telegram bot DM to one Firstmate home.
It uses one Python systemd user service and one project-local Pi extension.
Python owns pairing, authentication, deduplication, voice confirmation, offline queueing, retention, service lifecycle, and Telegram delivery.
The extension acts only in the current Pi process that owns the exact home session lock.
Its private transport commands require a per-process capability passed on an inherited file descriptor, so model tools and accidental shell calls cannot claim or deliver mirror traffic.
A deliberately hostile same-UID process is outside this boundary.
Telegram never starts or hosts a second Pi, RPC or SDK agent, Telegram agent, shadow orchestrator, secondmate route, or fallback model.

## Setup

Put one `FM_TELEGRAM_BOT_TOKEN` entry in the selected home's regular, non-symlink, gitignored `.env`.
Do not copy the token into a unit file, tracked file, command argument, or diagnostic output.
Pair one private user and chat with `bin/fm-telegram.py --home "$FM_HOME" pair --user-id <private-user-id> --chat-id <private-dm-id>`.
Install and start the service with `bin/fm-telegram.py --home "$FM_HOME" install`.
Use `start`, `stop`, `status`, `disable`, and `cleanup` for the service lifecycle.
The service may run while Pi is absent and queues authenticated content until the lock-owning primary extension is live.

## Mirror mode

Mirror mode is off until enabled and the preference is private, atomic, and persistent per home.
Use the exact project-local Pi commands `/telegram on`, `/telegram off`, and `/telegram status`.
The pinned bot recognizes those exact commands without an LLM, even when mode is off or Pi is not running.
Ordinary Telegram input while mode is off receives a deterministic refusal and is not queued or processed.
The Pi footer shows `telegram: on`, `telegram: off`, or a non-primary warning.

When mode is on, authenticated text and confirmed voice transcripts enter Pi through `pi.sendUserMessage()` as one visible `You · Telegram` user turn.
Interactive terminal input remains `You · Terminal` and is mirrored to Telegram as one user message.
After `agent_settled`, one finalized user-facing assistant body is delivered as `Firstmate ·`.
Normal live operation is one Telegram message, one Pi turn, and one response.
No Telegram model tool, second model pass, summary, regeneration, or transport implementation in TypeScript is used.

Only live input provenance permits mirroring.
The extension admits source=`interactive` terminal input and its own authenticated Telegram admission.
RPC input, other extension injections, operational messages, worker mechanics, system and developer messages, thinking, tool calls, tool results, and diagnostics are never mirrored.
The extension does not compare message bodies to infer provenance.
Telegram-origin authority remains restricted for merges, destructive or irreversible operations, discard, credentials and security changes, and authority expansion.

Telegram bot chats are not end-to-end encrypted.
Eligible ordinary text is mirrored exactly without a secret classifier, redaction, summary, or heuristic suppression.
Turn mode off whenever content should remain local.

## Delivery states

`Bot · Queued for Firstmate.` means the authenticated request is durably queued.
`Pi · Delivered to Firstmate.` means the lock-owning Pi extension accepted it through `sendUserMessage()`.
`Bot · Transcribing…` is sent only when that exact voice note starts local transcription.
These statuses are zero-token transport messages and do not enter the conversation.
Stable request and message identities prevent ordinary duplicate injection and delivery within one live process.
A request moves to bounded handled state only after every Unicode-safe Telegram chunk of its assistant response is definitively sent.
Definite Telegram rejection is retried at most three times, while delivery-unknown state is not resent or marked complete automatically.
Startup, reload, session replacement, and a bounded rescan reconcile missed notifications from extension-owned session admission entries.
Telegram transport state alone never requires or routes through the Firstmate watcher.
Terminal mirroring is live-only and never replays historical messages after startup, resume, clone, or retention expiry.

## Accepted crash boundary

Normal live operation is one Telegram message, one Pi turn, one response.
If Pi or WSL crashes after `sendUserMessage()` acceptance but before durable session persistence, that request may be delayed, absent from that interrupted session, or injected again after restart.
Terminal mirroring is live-only and never replays historical messages on startup, resume, or clone.
No cross-store exactly-once protocol is added to remove this accepted anomaly.
The Bot API delivery-unknown window can also repeat a transport message after Telegram accepted it but before local delivery state settled.

## Voice and retention

Only authenticated private text and voice notes are accepted.
Voice notes are downloaded only after pin verification, transcribed locally, and require explicit confirmation before admission.
Queued requests, handled identities, voice confirmations, and paired delivery metadata and body records are bounded and retained only for the documented transport windows.
The executable's `--help` output owns exact numeric limits, service paths, and transcriber overrides.

## Migration and follow-up work

The one-time migration removes obsolete routed conversation and response-journal state while preserving queued user content.
There is no permanent fallback route or AI-facing Telegram response choreography.
Native reply and status UX is reserved for issue 6.
macOS support is reserved for issue 4.
One-primary auto-start is reserved for issue 7.
