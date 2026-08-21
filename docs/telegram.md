# Telegram terminal mirror (WSL)

The Telegram mirror puts the one Firstmate terminal conversation on your phone, in both directions.
It is a private Python bot (`bin/fm-telegram.py`) running as a WSL user service beside one Pi extension (`.pi/extensions/fm-telegram-mirror.ts`).
It is WSL only and has no macOS service.

Telegram text reaches Firstmate exactly as terminal text: no origin marker, no hidden provenance, and no Telegram-specific instruction.
Telegram input therefore carries the same authority as anything typed in the terminal, so pair only your own account.
The bot never starts Firstmate, never creates a second session, and contains no model or agent loop.

## Setup

1. Create a bot with Telegram's `@BotFather` and copy its token.
2. Store the token privately (this file is never read by the service unit):

   ```sh
   mkdir -p ~/.firstmate-telegram && chmod 700 ~/.firstmate-telegram
   printf 'TELEGRAM_BOT_TOKEN=%s\n' '<token>' > ~/.firstmate-telegram/env
   chmod 600 ~/.firstmate-telegram/env
   ```

3. Pair one account and one private chat, then message the bot from that account:

   ```sh
   bin/fm-telegram.py pair
   ```

   The pairing identifiers land in `~/.firstmate-telegram/config.json`.
   Messages from any other account or chat are ignored without downloading attachments or forwarding content.

4. Optional: set the local Parakeet command for voice notes in that same file, as `transcribe_command`.
   It defaults to `parakeet-tdt-0.6b-v3`, and the audio path replaces `{audio}` or is appended.
   Transcription is local Parakeet only; there is no Whisper fallback or retry button.

5. Install the WSL user service so the bot starts whenever WSL starts:

   ```sh
   bin/fm-telegram.py install-service   # writes ~/.config/systemd/user/firstmate-telegram.service
   bin/fm-telegram.py status
   ```

   Run `loginctl enable-linger "$USER"` if you want the service to survive after your last WSL shell closes.
   `bin/fm-telegram.py service-unit` prints the unit without installing it, and `uninstall-service` removes it.

The Pi half loads automatically with the other tracked Firstmate extensions in `.pi/extensions/` when Pi runs in a trusted Firstmate home.
It connects to the bot when a Pi session starts and retries on a widening delay while the bot is absent, so a home without the bot pays nothing but an occasional failed connection.

## Mirror mode

Mirror mode starts off every time the bot starts and is never persisted.

In Telegram, these switch it and are never sent to Firstmate as conversation text:

- `/telegram on` - start mirroring in both directions.
- `/telegram off` - stop new mirroring.
- `/telegram status` - report whether mirroring is on and whether Firstmate is connected.

Telegram's own command menu cannot contain a space, so the same three commands are published to the paired chat as `/telegram_on`, `/telegram_off`, and `/telegram_status`.
Both spellings do the same thing; the menu aliases exist so the commands are visible and tappable in Telegram.

In the Pi terminal there are two commands: `/telegram` toggles mirror mode, and `/telegram-settings` opens the settings.

## The terminal footer

Pi's footer shows `telegram: on`, `telegram: off`, or `telegram: unavailable`.
`unavailable` means this Pi session cannot reach the bot service or its local socket, so mirror mode has no reachable owner to report.

The bot owns mirror mode and publishes every change, so the footer updates promptly whether you switch from Telegram or from the terminal, and when the bot starts or stops.

## Settings

`/telegram-settings` opens a settings list with two toggles.

`Display Telegram status` shows or hides the footer item.
It is a terminal-side preference stored as `~/.firstmate-telegram/pi-display-status`, so it survives a restart and still applies while the bot is unavailable.

`Delivery confirmations` is the same setting as the Telegram button described below, and both surfaces always show the same value.
While the bot is unavailable it reads `unavailable` and cannot be changed there, because the bot owns it.

## Delivery confirmations

`Pi · Sent to Firstmate.` is on by default and can be turned off from either surface.
In Telegram, every reply to `/telegram on`, `/telegram off`, or `/telegram status` carries one button that reads `Disable confirmations` while they are on and `Enable confirmations` while they are off; tapping it switches the setting and updates that same message.
In the terminal it is the second toggle in `/telegram-settings`.

The current state is part of the status line, and the choice is stored in `~/.firstmate-telegram/config.json` as `confirmations`, so it survives a bot or WSL restart.
Because the bot owns the setting and publishes every change, the two surfaces cannot drift apart.

Turning it off hides only the receipt.
Messages still reach Firstmate exactly as before, and an accepted message still leaves the queue, so nothing is delivered twice.

While mirror mode is off, an ordinary Telegram message is answered with `Telegram mirror is off. Send /telegram on to enable it.` and never reaches Pi.

While mirror mode is on:

- each ordinary submission typed in the Pi terminal appears in Telegram as a `You · Terminal` message,
- every completed reply appears as Firstmate finishes it, and
- gray thinking, tool calls, tool results, shell output, and system, developer, extension, or operational messages never appear.

Messages sent back-to-back often join one continuous run, so Firstmate can answer several times before it goes idle.
Each of those replies is mirrored on its own, as it completes, rather than only the last one.

A message typed in Telegram is already visible there, so it is not echoed back as a duplicate.

## Sending to Firstmate

Telegram text enters an in-memory FIFO in arrival order and is submitted through Pi's normal user input.
Messages sent back-to-back while Pi is working steer the run exactly like typing them in the terminal, so Pi keeps its own batching and continuation behavior.
When Pi accepts a message, `Pi · Sent to Firstmate.` replies to that exact message; that means Pi accepted the input, not that Firstmate finished answering.
That receipt can be switched off (see Delivery confirmations).

If Firstmate is not running, the reply is `Firstmate is not running. Your message is queued until it starts.` and the text waits in memory until the one Pi session connects.

**There is no durable queue, expiry system, replay journal, or retention subsystem.**
A queued message that has not reached Pi is lost if the bot restarts or WSL stops.
If Pi disappears between accepting a message and confirming it, that one message is sent again when the session returns.
Both are deliberate limitations of this version rather than bugs.

## Reply threading

Every status the bot itself produces replies to the exact Telegram message it describes: `Transcribing…`, the transcript card, `Pi · Sent to Firstmate.`, and the mirror-off and offline notices.

Firstmate's own replies are always sent as ordinary unthreaded messages.
Pi batches back-to-back submissions into one run, so a reply belongs to no single source message, and threading it would attach answers to the wrong one.
This supersedes the original design note that a Telegram-originated message should receive its reply threaded; the captain approved always-unthreaded replies after live testing.
Threading is presentation only either way, and never changes what Firstmate sees or how Pi processes input.

## Voice notes

1. Send a voice note; the bot replies `Transcribing…` to it.
2. The audio is downloaded to owner-only temporary storage under `~/.firstmate-telegram/audio/` and transcribed with the local Parakeet command.
3. The transcript replies to the voice note with `Send to Firstmate`, `Edit`, and `Cancel`.
4. Nothing reaches Pi until you tap `Send to Firstmate`.

`Edit` replaces the buttons with `Copy text` and `Back` and opens a reply prompt bound to that transcript.
Copy the text, paste it into the reply, correct it, and send: the original transcript message updates and the main buttons return, as often as you like.
`Back` leaves the transcript unchanged and restores the main buttons.
Telegram limits a copy button to 256 characters, so a longer transcript shows only `Back`; copy that text from the transcript message itself.

`Send to Firstmate` removes the buttons, marks the transcript `Sent to Firstmate`, queues the current text through the same path as ordinary Telegram text, and deletes the temporary audio.
The `Pi · Sent to Firstmate.` confirmation replies to the original voice note.
`Cancel` removes the buttons, marks the transcript `Cancelled`, sends nothing, and deletes the temporary audio and transcript state.

Every button action is bound to the current transcript revision, so a stale or repeated tap is refused instead of sending the same transcript twice.

## Boundaries

- One paired account, one private chat, one Firstmate session.
- The bot owns mirror mode and delivery confirmations for both surfaces; the terminal only shows and changes what the bot publishes.
- Transport statuses stay attached to the exact message they describe, while Firstmate's replies are never threaded (see Reply threading).
- The service unit holds no token and no message content; the token stays in `~/.firstmate-telegram/env` and pairing stays in `config.json`.
- Temporary voice audio is owner-only and is deleted after send, cancel, failure, and at bot start and stop.
- `FM_TELEGRAM_DIR` moves the private directory; `bin/fm-telegram.py --help` owns the remaining flags and environment.

The wire protocol between the bot and the Pi extension is stated once in `bin/fm-telegram.py`'s header.

Regression entry points:

```sh
tests/fm-telegram-mirror.test.sh
tests/fm-telegram-extension.test.sh
tests/fm-pi-primary-types.test.sh
FM_TELEGRAM_LIVE_E2E=1 tests/fm-telegram-mirror-live-e2e.test.sh
```
