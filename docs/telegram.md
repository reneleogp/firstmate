# Telegram mirror mode

This optional Linux/WSL transport connects one pinned private Telegram bot DM to one Firstmate home.
It uses one Python systemd user service and one project-local Pi extension.
The service uses Python's standard library and outbound Telegram Bot API long polling, with no webhook, public ingress, tunnel, hosted service, or third-party Telegram package.
Python owns pairing, authentication, deduplication, voice confirmation, offline queueing, retention, service lifecycle, and Telegram delivery.
The extension acts only in the current Pi process that owns the exact home session lock.
Its private transport commands require a per-process capability passed on an inherited file descriptor, so model tools and accidental shell calls cannot claim or deliver mirror traffic.
A deliberately hostile same-UID process is outside this boundary.
Telegram never starts or hosts a second Pi, RPC or SDK agent, Telegram agent, shadow orchestrator, secondmate route, or fallback model.

## Setup

Put one `FM_TELEGRAM_BOT_TOKEN` entry in the selected home's regular, non-symlink, gitignored `.env`.
Do not copy the token into a unit file, tracked file, command argument, or diagnostic output.
Pair one private user and chat with `bin/fm-telegram.py --home "$FM_HOME" pair --user-id <private-user-id> --chat-id <private-dm-id>`.
Pairing verifies the bot identity and private chat, then stores the pinned user, chat, and bot identifiers in private `config/telegram.json`.
Use both `pair` transcriber options together when Parakeet and Whisper wrappers are outside the systemd service PATH; `--help` owns their exact flags and constraints.
Stop the installed service before replacing its pairing, and run `cleanup` first when changing an identity that still has private Telegram state.
Install and start the service with `bin/fm-telegram.py --home "$FM_HOME" install`.
When the exactly owned unit is already active, `install` rewrites the unit, reloads systemd, and restarts that service so the running process uses the current tracked transport bytes.
It refuses a unit owned by another home or installation and never restarts a foreign service.
Use `start`, `stop`, `status`, `disable`, and `cleanup` for the service lifecycle.
Stopping or disabling abandons pending voice confirmations and waiting voice notes and removes temporary audio.
Cleanup removes this service's unit, pairing, preference, and private Telegram state without editing `.env` or unrelated home records.
The service may run while Pi is absent and queues authenticated content until the lock-owning primary extension is live.

## Mirror mode

Mirror mode is off until enabled and the preference is private, atomic, and persistent per home.
Use the exact project-local Pi commands `/telegram on`, `/telegram off`, and `/telegram status`.
The pinned bot recognizes those exact commands without an LLM, even when mode is off or Pi is not running.
Ordinary Telegram input while mode is off receives a deterministic refusal and is not queued or processed.
A healthy primary Pi footer shows `telegram: on`, `telegram: on · queued`, or `telegram: off`; non-primary, unavailable transport, recovery, and blocked-delivery states are surfaced explicitly.

When mode is on, authenticated text and confirmed voice transcripts enter Pi through `pi.sendUserMessage()` as one visible `You · Telegram` user turn.
Ordinary non-command interactive terminal input remains `You · Terminal` and is mirrored to Telegram as one user message.
Slash commands and their expanded prompt lifecycles are excluded from mirroring.
A self-identifying slash-continuation marker is stripped from the accepted user content while preserving an already-active mirrored tool loop through that excluded lifecycle.
Input handling attaches only a live provenance marker, and the exact user-message lifecycle creates the bounded transport reservation and sends it after Pi accepts the turn.
Turning mirror mode off blocks future admissions without discarding an already accepted turn or its pending response delivery.
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

`Bot · Queued for Firstmate.` means the authenticated request is durably queued and replies to the exact inbound message that created it.
`Pi · Delivered to Firstmate.` means the lock-owning Pi extension accepted it through `sendUserMessage()` and replies to that request's source message.
`Bot · Voice note queued.` and `Bot · Transcribing…` retain the original voice-note message as their native Telegram reply target, including when several notes are waiting.
The first `Firstmate ·` response replies to its source request, and subsequent chunks form a bounded reply chain when Telegram returns stable outbound message IDs.
Every target is validated against the pinned private chat, and a deleted target falls back first to the exact triggering inbound message and then to an unthreaded send so content is not lost.
These statuses are zero-token transport messages and do not enter the conversation.
Stable request, session, delivery, and bounded reply-journal identities prevent ordinary duplicate injection and delivery outside the accepted crash boundary below.
A successful Telegram-origin request moves to bounded handled state only after every Unicode-safe chunk of its assistant response is definitively sent.
An oversized, malformed, or definitely rejected Telegram-origin response is instead abandoned without another model turn; a retryable or delivery-unknown response remains blocked for explicit recovery.
Definite Telegram rejection is retried at most three times, while delivery-unknown chunks are not resent or marked complete automatically.
If a terminal-origin finalized response exceeds the transport limit or is definitely content-rejected, Telegram receives one stable non-model fallback directing the user to the terminal; a retryable or unknown fallback remains in the same bounded blocked turn.
A terminal mirror turn interrupted before it has a finalized assistant body is abandoned without fabricating a fallback or replaying its blocked user delivery.
Startup, reload, session replacement, and a bounded rescan reconcile missed notifications from extension-owned session admission entries.
A provider failure moves that admission into one bounded interrupted hold, blocks later Telegram admissions, and retries only after the operator explicitly sends `/telegram on`.
If both bounded hold and abandonment writes fail because local state storage is unavailable, the extension stops new admission and further retries, preserves the live claim, and requires storage repair plus a Pi restart.
Telegram transport state alone never requires or routes through the Firstmate watcher.
Terminal mirroring is live-only and never replays historical messages after startup, resume, clone, or retention expiry.

## Accepted crash boundary

The normal live contract above applies outside this boundary.
If Pi or its host crashes after `sendUserMessage()` acceptance but before durable session persistence, that request may be delayed, absent from that interrupted session, or injected again after restart.
No cross-store exactly-once protocol is added to remove this accepted anomaly.
The Bot API delivery-unknown window can also repeat a transport message after Telegram accepted it but before local delivery state settled.

## Voice confirmation

Voice confirmation controls are revision-bound and are removed or replaced as soon as an action starts.
Send shows `Sent to Firstmate` only after the transcript is durably admitted, while Cancel shows `Cancelled` and removes temporary audio and pending state.
If a Cancel edit has delivery-unknown status, the transport disables its controls when possible and waits through three bounded reconciliation attempts before using one journaled `Cancelled` reply to the original voice and completing cleanup.
Edit shows `Editing transcript…`, offers Telegram's `copy_text` button when supported, and sends a `ForceReply` prompt with the placeholder `Paste and edit the transcript`.
The bot cannot prefill the ordinary Telegram composer, so it does not add a Web App or inline-mode subsystem.
If a client does not support `copy_text`, the transcript remains available as copyable fallback text alongside the ForceReply prompt.
Retry shows `Retrying with Whisper…` and either presents fresh revision-bound controls or a recoverable failure state.
Only a reply to the active ForceReply prompt is accepted as corrected text, and stale or duplicate revisions never enqueue unconfirmed text.

## Voice and retention

Only authenticated private text and voice notes are accepted.
Voice notes are downloaded only after pin verification, transcribed locally, and require explicit confirmation before admission.
Queued and interrupted requests, handled identities, voice confirmations, and paired delivery metadata and body records are bounded by the executable's private retention limits.
Temporary audio is deleted after sending, cancellation, expiry, failed initial transcription, service stop, disable, or cleanup.
Raw request bodies do not enter wake rows, unit files, command arguments, diagnostics, or tracked files.
Telegram can retain unconsumed bot updates for only about 24 hours, so a longer laptop or service outage can lose requests before this service queues them.
The executable's `--help` output owns supported command flags, operator-visible size, count, and retention limits, and transcriber overrides.

## Migration and follow-up work

The one-time mirror migration removes obsolete routed conversation and response-journal state while preserving queued user content.
Every primary session start and bounded extension reconciliation also retires obsolete Telegram wake rows without reading Telegram request bodies.
If session-start wake migration fails, the effective wake queue remains undrained so an obsolete Telegram wake cannot be presented as model work.
There is no permanent fallback route or AI-facing Telegram response choreography.
Native reply and status UX is implemented by the bounded Python transport and is covered by the fake-Telegram verification below.
macOS support is reserved for issue 4.
One-primary auto-start is reserved for issue 7.
