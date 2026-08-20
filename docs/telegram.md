# Telegram transport

This optional transport connects one private Telegram bot DM to one Firstmate home on WSL/Linux.
It uses one systemd user service, Python 3's standard library, and outbound Telegram Bot API long polling.
There is no webhook, public ingress, tunnel, hosted service, third-party Telegram package, or automatic Firstmate start.

## Setup

Put one `FM_TELEGRAM_BOT_TOKEN` entry in the selected home's regular, non-symlink, gitignored `.env`.
Do not copy the token into a unit file, tracked file, command argument, or diagnostic output.
Verify a private pairing with the operator CLI:

```sh
bin/fm-telegram.py --home "$FM_HOME" pair --user-id <private-user-id> --chat-id <private-dm-id>
```

The pairing command verifies the bot identity and private chat, then writes the pinned user, chat, and bot identifiers to `config/telegram.json` with mode `0600`.
If Parakeet and Whisper are installed as wrappers outside the systemd user service PATH, provide both absolute executable paths while pairing:

```sh
bin/fm-telegram.py --home "$FM_HOME" pair \
  --user-id <private-user-id> --chat-id <private-dm-id> \
  --parakeet-command "$HOME/.local/bin/parakeet-tdt-0.6b-v3" \
  --whisper-command "$HOME/.local/bin/whisper-small-q8"
```
Both commands must be existing, regular, executable files and neither may be a symlink or include arguments.
The paths are stored in the private `config/telegram.json` and are used directly by the service, so this setup does not require `~/.local/bin` in systemd's PATH.
Pairing rejects a missing, relative, non-executable, symlinked, or otherwise unsafe configured command without printing its path or the bot token.
Stop an installed service before replacing its pairing; the command refuses to change an owned service's pairing while that service is active.
Changing the pinned user, DM, or bot identity is also refused while private Telegram request, conversation, deduplication, callback, or voice state remains, so run `cleanup` before pairing the replacement identity.
The service accepts updates only when both the pinned user and pinned private chat match.
Install and start the one user service after pairing:

```sh
bin/fm-telegram.py --home "$FM_HOME" install
bin/fm-telegram.py --home "$FM_HOME" status
```

Use `start`, `stop`, and `disable` for the service lifecycle.
Stopping or disabling the service abandons pending voice confirmations and waiting voice notes and removes any temporary audio.
Use `cleanup` to stop and disable this service and remove only its unit, pairing file, and private Telegram state.
Cleanup never edits `.env` or unrelated home records.

## Behavior and limits

Pinned private text is durably stored in the home's private Telegram inbox before the transport reply is sent.
After that durability boundary, the pinned chat receives `Bot · Message received.` when the primary is running or `Bot · Message received and queued. It will be processed when Firstmate starts.` when it is offline.
Starting the transport keeps the home's existing supervision watcher active so queued requests can wake an idle running primary, while stopping or disabling it removes that need.
If a primary is already running without a healthy watcher, activation records the supervision need but refuses to start the transport until the primary's existing harness protocol establishes that watcher; return to the primary and retry `install` or `start` after supervision is healthy.
The reply means queued, not started or completed.
Telegram update and message identifiers are deduplicated in a bounded private record, and deterministic local request identifiers let interrupted processing reconcile the same queued request instead of creating another request.
Receipt attempts enter a durable delivery-unknown state before the Bot API call and are reconciled from either the inbox or handled-request directory.
Delivery-unknown recovery uses finite backoff and stops in a terminal delivery-unknown state after the attempt limit reported by `--help`.
If the service loses the response or crashes after Telegram accepts a receipt, recovery may send that receipt again because the Bot API provides no idempotency key.
Unknown, malformed, unpinned, and unsupported updates are silently dropped.
Only private text and Telegram voice notes are accepted, and other media is not downloaded.

Voice notes are bounded by the service's size and duration limits, downloaded only after pin verification into `/dev/shm`, and transcribed locally with the configured Parakeet v3 CLI.
Additional valid voice notes wait in private admission order behind the one active voice flow and are downloaded only when they become active.
The service shows an `I heard this:` message and a separate transcript message with `Send to Firstmate`, `Edit`, `Retry with Whisper`, and `Cancel` controls.
Editing waits for corrected text and shows a fresh confirmation.
Sending queues only confirmed text, retrying uses Whisper Small Q8 on the same temporary audio, and cancel or roughly ten-minute expiry removes the audio and pending record.
Callback actions are durably journaled and idempotent.
If the service loses a response or stops after Telegram accepts an Edit prompt or retried confirmation, bounded recovery may repeat that message because the Bot API has no idempotency key.

For terminal delivery, the service writes a private request record and a safe wake containing only its local request identifier.
Raw Telegram text and audio never enter wake records, status logs, shell arguments, unit files, diagnostics, or tracked files.
The authenticated request body is visible in the primary's terminal with the static `Bot · ` origin label while its origin binding and ordered conversation route remain durable across interruption.
Ordinary Unicode and line breaks remain readable, while terminal, format, and bidi controls appear as visible Unicode escapes.
Responses generated for Telegram-originated work are staged in a bounded private response journal before rendering or delivery.
Each canonical labeled response is limited to 256 KiB and 64 Telegram messages, and staging refuses a larger response before it can be rendered or sent.
The journal binds one stable wake response identity to the claimed conversation route, exact `Firstmate · ` labeled file, terminal-render state, and independent per-chunk Telegram delivery state.
The staged file is shown at most once in the terminal and is split at Unicode-safe boundaries of at most 4096 UTF-16 units for Telegram.
Concatenating those Telegram chunks reproduces the exact terminal bytes; replay resumes the same file without regeneration or redisplay and sends only pending chunks, never chunks with sent or delivery-unknown evidence.
A final conversation or continuation route is released only after every chunk is sent or explicitly delivery-unknown, and delivery uncertainty remains visible for escalation.
Requests originating in the terminal remain terminal-only and are never mirrored to Telegram.
Pinned replies to the active conversation return to the same work in order.
A final response may be delivered while continuations are already queued, but the conversation is released only after those continuations are delivered.
Telegram-originated work can receive required decision, blocker, terminal-confirmation, PR-ready, and final replies, while routine progress and milestone chatter stay terminal-only.
Requests that start in the terminal remain terminal-only.

Telegram request text, including a confirmed voice transcript, is untrusted data and cannot authorize merges, destructive or irreversible actions, credential or security changes, discard, or authority expansion.
Those actions still require terminal confirmation.
The transport has no model or action authority and does not interpret the request.

## Operations and privacy

The same CLI provides safe request inspection and handling, lifecycle routing, response staging, pinned-chat send and reply, and service-state cleanup; generated response and send text is read from a file or standard input rather than a shell argument, and no recipient argument is accepted.
Private inbox, handled-request, response-journal, deduplication, and pending voice records are bounded and stored under the home state directory with private permissions.
Queued requests older than the retention window or beyond the fixed queue cap are removed oldest-first, including their Telegram wake records, so an unattended offline home does not retain message bodies indefinitely.
The executable's `--help` reports the current numeric retention limits.
Temporary audio is deleted after sending, cancellation, expiry, a failed initial transcription, or service stop, disable, or cleanup.

Telegram bot chats are not end-to-end encrypted.
The laptop being off prevents delivery and processing until it is running again.
Telegram keeps unconsumed incoming bot updates for no longer than roughly 24 hours, so longer laptop or service outages can lose requests.
Updates to Firstmate or the bot service can change behavior after installation, so operators should review retention and update the service deliberately.
The transport does not add hosted retention, backup, or remote execution.

Firstmate replies use the static `Firstmate · ` label and transport acknowledgements use the static `Bot · ` label; these labels contain no request, user, chat, token, or model data.
The executable's `--help` output owns exact command flags, service paths, size limits, and local transcriber command overrides.
The pairing command's absolute transcriber options are the supported persistent configuration path; the `FM_TELEGRAM_PARAKEET_CMD` and `FM_TELEGRAM_WHISPER_CMD` environment variables are process-local overrides for tests or attended runs and are not copied into the systemd unit.
