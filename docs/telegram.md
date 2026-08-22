# Telegram terminal mirror

The Telegram mirror puts the one Firstmate terminal conversation on your phone, in both directions.
It is a private Python bot (`bin/fm-telegram.py`) running as a per-user service beside one Pi extension (`.pi/extensions/fm-telegram-mirror.ts`).
It runs on WSL as a systemd user unit and on macOS as a LaunchAgent, and nowhere else.

Everything you can see and do is the same on both: mirror mode, the commands, the terminal footer and settings, voice notes, screenshots, formatting, and every limit below.
Only the service manager differs, so this page splits only where the setup commands genuinely differ.

Telegram text reaches Firstmate exactly as terminal text: no origin marker, no hidden provenance, and no Telegram-specific instruction.
Telegram input therefore carries the same authority as anything typed in the terminal, so pair only your own account.
The bot never starts Firstmate, never creates a second session, and contains no model or agent loop.

## Setup

1. Create a bot with Telegram's `@BotFather` and copy its token.
2. Store the token privately (this file is never read by the service):

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

4. Set the local Parakeet command for voice notes in that same file, as `transcribe_command`.
   It defaults to `parakeet-tdt-0.6b-v3`, and the audio path replaces `{audio}` or is appended.
   A service manager's `PATH` is not your login shell's, so give it as an absolute path whenever the command lives outside `/usr/bin` and `/bin`.
   On Apple Silicon that is the normal case, because a local Parakeet installed by Homebrew or `pip --user` sits under `/opt/homebrew/bin` or `~/.local/bin`:

   ```json
   { "transcribe_command": "/opt/homebrew/bin/parakeet-mlx {audio}" }
   ```

   `bin/fm-telegram.py status` prints that command and says plainly when it cannot be found.
   Transcription is local Parakeet only; there is no Whisper fallback or retry button.

5. Install the Markdown parser used to format Firstmate's replies, into the same Python that will run the bot:

   ```sh
   sudo apt install python3-mistune       # WSL
   python3 -m pip install --user mistune  # macOS
   ```

   Without it the mirror still works and simply sends every reply as plain text.

6. Install the user service so the bot starts whenever you log in:

   ```sh
   bin/fm-telegram.py install-service
   bin/fm-telegram.py status
   ```

   On WSL that writes `~/.config/systemd/user/firstmate-telegram.service`.
   Run `loginctl enable-linger "$USER"` if you want the service to survive after your last WSL shell closes.

   On macOS it writes `~/Library/LaunchAgents/com.firstmate.telegram.plist` and loads it, so the bot starts at every login.
   Run `install-service` with the same `python3` you installed `mistune` into, because that interpreter is the one recorded in the LaunchAgent.

The Pi half loads automatically with the other tracked Firstmate extensions in `.pi/extensions/` when Pi runs in a trusted Firstmate home.
It connects to the bot when a Pi session starts and retries on a widening delay while the bot is absent, so a home without the bot pays nothing but an occasional failed connection.

## Running the service

The same commands drive the service on both platforms:

| Command | What it does |
| --- | --- |
| `install-service` | Install or update the service, start it, and wait until that new process is actually serving |
| `restart-service` | Republish the definition and relaunch it, again waiting for the new process |
| `stop-service` | Stop it within a bounded time, leaving it installed |
| `disable-service` | Stop it and keep it from starting at the next login |
| `uninstall-service` | Stop and remove it |
| `service-unit` | Print the service definition without installing anything |
| `status` | Print pairing, transcription command, socket, and service state |

Each of those owns exactly one installation: the one whose definition names your private directory.
A definition that names another directory, and a running job that macOS loaded from another file or whose file has since been deleted, are reported with the command that inspects them and are otherwise left exactly as they are.
If an install fails, the previous definition and its login state are put back, so a failed install never leaves something new starting at your next login.

On macOS the service's own output goes to `~/.firstmate-telegram/service.log`, which is where `install-service` points you when a start fails.
That file carries the same transport diagnostics the bot prints, and never a token, a paired identifier, or message content.

## Only your own session is mirrored

Workers are Pi sessions too.
If this extension is installed globally, it loads in every crewmate and scout as well, and without a gate one of their conversations could become the mirrored session and push its instructions, replies, and tool activity into your private chat.

Two independent rules prevent that:

- The extension mirrors only from the session that holds the Firstmate home's session lock, checked against the running process's own ancestry.
  Every other Pi session stays completely inert: no connection, no footer, no commands.
- The bot serves one session at a time and refuses a second connection instead of handing the chat over to it.
  When your session ends, the next one may take over.

If you install the extension globally, keep it out of auto-discovery for worker sessions unless you want to rely on the gate alone.

## Mirror mode

Mirror mode starts off every time the bot starts and is never persisted.

In Telegram, these switch it and are never sent to Firstmate as conversation text:

- `/telegram on` - start mirroring in both directions.
- `/telegram off` - stop new mirroring.
- `/telegram status` - report mirroring, whether Firstmate is connected, and whether confirmations are on.

Telegram's own command menu cannot contain a space, so `/telegram on`, `/telegram off`, and `/telegram status` are also published as `/telegram_on`, `/telegram_off`, and `/telegram_status`.
The menu also publishes `/telegram_confirmations_on` and `/telegram_confirmations_off`.
The aliases exist so every Telegram command is visible and tappable.

While mirror mode is off, an ordinary message is answered with `Telegram mirror is off. Send /telegram_on to enable it.`, naming a command you can tap straight from the menu.

In the Pi terminal there are two commands: `/telegram` toggles mirror mode, and `/telegram-settings` opens the settings.

## The terminal footer

Pi's footer shows `telegram: on`, `telegram: off`, or `telegram: unavailable`.
`unavailable` means this Pi session cannot reach the bot service or its local socket, so mirror mode has no reachable owner to report.

The bot owns mirror mode and publishes every change, so the footer updates promptly whether you switch from Telegram or from the terminal, and when the bot starts or stops.

## Settings

`/telegram-settings` opens a settings list with two toggles.

`Display Telegram status` shows or hides the footer item.
It is a terminal-side preference stored as `~/.firstmate-telegram/pi-display-status`, so it survives a restart and still applies while the bot is unavailable.

`Delivery confirmations` is the same setting as the Telegram commands described below, and both surfaces always show the same value.
While the bot is unavailable it reads `unavailable` and cannot be changed there, because the bot owns it.

## Delivery confirmations

`Pi · Sent to Firstmate.` is on by default and can be turned off from either surface.
In Telegram, use `/telegram_confirmations_on` and `/telegram_confirmations_off` from the command menu.
In the terminal, use the second toggle in `/telegram-settings`.

The current state is part of the status line, and the choice is stored in `~/.firstmate-telegram/config.json` as `confirmations`, so it survives a bot or machine restart.
Because the bot owns the setting and publishes every change, the two surfaces cannot drift apart.

Turning it off hides only the receipt.
Messages still reach Firstmate exactly as before, and an accepted message still leaves the queue, so nothing is delivered twice.

## Screenshots and images

Images travel both ways.

Paste or attach an image in the terminal and it appears in Telegram as real, viewable media rather than a local path: one photo on its own, or an album that keeps the order you sent.
Pi's own paste writes the image into the temp directory and puts that path in your message, so the mirror recognises exactly that artifact: Pi's own file name in Pi's own temp directory, a regular file this account owns, of an accepted type whose actual bytes match.
Only a path proven to be a canonical Pi clipboard artifact is removed from the phone caption, including when that proven artifact exceeds a media limit.
Any arbitrary path or path that fails the identity, ownership, file-type, symlink, image-magic, or existence checks remains ordinary mirrored captain text and is never uploaded.
The mirror only reads proven clipboard artifacts and never deletes them; Pi continues to own their cleanup.
Pasting two images at once runs them together with no space between, which is recognised as two pictures while a path glued to anything else stays ordinary text.
Your terminal text rides along as the caption when it fits, and is sent as its own `You · Terminal` message when it is too long for one.
An image-only submission still arrives, captioned `You · Terminal`.
Images that are the wrong type or too large are skipped with a short note saying how many, and if Telegram rejects an upload you are told plainly; a failed album is never re-sent, so nothing arrives twice.

Send a screenshot from the paired chat and Firstmate receives it exactly as an image pasted into the terminal, with nothing saying it came from Telegram.
A caption travels with it as the text of the same message.
Because the terminal shows no preview of an attached image, the message also carries a plain `[Image attached]` line so you can see one arrived; with a caption it reads as the caption followed by that line, and without one it is that line alone.

- Photos and image files are accepted as PNG, JPEG, or WebP; downloaded bytes must match the declared type, and anything else is refused.
- Telegram sends several renditions of a photo, and the sharpest one is used.
- Images over 10 MB are refused, as is a backlog of queued images past 32 MB.
- Images keep their place in the queue alongside text and confirmed voice notes, and produce the same `Pi · Sent to Firstmate.` reply on the original message when confirmations are on.

The terminal side tells the bot what it can render when it connects, so a Pi session running an older copy of the extension is told plainly that it cannot receive images instead of quietly turning your screenshot into a text-only message.
If you see that reply, update the extension and `/reload` Pi.

An image waiting for Firstmate is held in memory only, exactly like queued text, and is dropped when it is accepted or when the bot stops.
The no-durable-queue limitation therefore covers screenshots too: an image that has not reached Firstmate is lost if the bot restarts.

While mirror mode is off, an ordinary Telegram message is answered with `Telegram mirror is off. Send /telegram_on to enable it.` and never reaches Pi.

While mirror mode is on:

- each ordinary submission typed in the Pi terminal appears in Telegram as a `You · Terminal` message, images included,
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
A queued message that has not reached Pi is lost if the bot restarts or your machine stops.
If Pi disappears between accepting a message and confirming it, that one message is sent again when the session returns.
Both are deliberate limitations of this version rather than bugs.

## Formatting

Firstmate's replies are converted to Telegram's own HTML, so code blocks, inline code, bold, links, quotes, and lists render the way they do in the terminal.
Numbered lists keep their numbering and bulleted lists their dashes, with items kept compact rather than spread across blank lines.
Only `<`, `>`, and `&` need escaping, and the converter can only emit tags Telegram documents, so nothing else in a reply can turn into markup.

Long replies are split before conversion, never after, because cutting converted markup in half makes Telegram reject the whole message.
A code block that spans a split is closed and reopened so each part still reads as code.

If Telegram refuses the markup anyway, that message is sent again immediately as plain text.
A refusal means Telegram sent nothing, so the retry cannot double-post.

## Reply threading

Every status the bot itself produces replies to the exact Telegram message it describes: `Transcribing…`, the transcript card, `Pi · Sent to Firstmate.`, and the mirror-off and offline notices.

Firstmate's own replies are always sent as ordinary unthreaded messages.
Pi batches back-to-back submissions into one run, so a reply belongs to no single source message, and threading it would attach answers to the wrong one.
Threading is presentation only and never changes what Firstmate sees or how Pi processes input.

## Voice notes

1. Send a voice note; the bot replies `Transcribing…` to it.
2. The audio is downloaded to owner-only temporary storage under `~/.firstmate-telegram/audio/` and transcribed with the local Parakeet command.
3. The transcript replies to the voice note with `Send to Firstmate`, `Edit`, and `Cancel`.
4. Nothing reaches Pi until you tap `Send to Firstmate`.

`Edit` replaces the buttons with `Copy text` and `Back` and opens a reply prompt bound to that transcript.
Copy the text, paste it into the reply, correct it, and send: the original transcript message updates and the main buttons return, as often as you like.
A transcript card is limited to 3,800 characters so it always remains one editable message; longer transcriptions are refused and their temporary audio is removed.
`Back` leaves the transcript unchanged and restores the main buttons.
Telegram limits a copy button to 256 characters, so a longer transcript shows only `Back`; copy that text from the transcript message itself.

`Send to Firstmate` removes the buttons, marks the transcript `Sent to Firstmate`, queues the current text through the same path as ordinary Telegram text, and deletes the temporary audio.
The `Pi · Sent to Firstmate.` confirmation replies to the original voice note.
`Cancel` removes the buttons, marks the transcript `Cancelled`, sends nothing, and deletes the temporary audio and transcript state.

Every button action is bound to the current transcript revision, so a stale or repeated tap is refused instead of sending the same transcript twice.

## Boundaries

- One paired account, one private chat, one Firstmate session; a second session is refused rather than promoted (see Only your own session is mirrored).
- Firstmate's replies are rendered as Telegram HTML so code, commands, and emphasis stay readable; if Telegram refuses the markup, the same text is sent again as plain text rather than lost.
  Formatting needs `python3-mistune` (`sudo apt install python3-mistune`); without it every reply is simply sent plain.
- Transport statuses, terminal echoes, and voice transcripts are sent as plain text, so they arrive exactly as written.
- Only the paired chat can send images, and the primary-session rule covers them: a worker session can neither receive nor deliver one.
- The bot owns mirror mode and delivery confirmations for both surfaces; the terminal only shows and changes what the bot publishes.
- Stopping or restarting the service is bounded: a running transcription and everything it started are ended, the connected terminal session is released, and the bot exits rather than waiting on work it cannot interrupt.
  The installed service gives it a matching grace, and a stop that the service still ignores is escalated rather than reported as done.
- Starting the service is bounded the other way: `install-service` and `restart-service` wait for the process they just started to be serving, for longer than any wait the bot itself can take on the network, and never accept a leftover signal from the process being replaced.
- On macOS exactly one process runs the service; the install starts it once and never starts a second alongside it.
- At most 32 untouched voice transcripts are kept; older ones are dropped with their temporary audio, so cards you never answer cannot pile up.
- Transport statuses stay attached to the exact message they describe, while Firstmate's replies are never threaded (see Reply threading).
- The service definition holds no token and no message content; the token stays in `~/.firstmate-telegram/env` and pairing stays in `config.json`.
  On macOS the LaunchAgent's environment is only the two local directory paths and one random identifier for the launch it started.
- Temporary voice audio is owner-only and is deleted after send, cancel, failure, and at bot start and stop; images are never written to disk at all.
  The private directory itself must be a real directory this account owns, not a symlink, on either platform.
- Transcription memory belongs to the local speech model rather than the bot process, and the service's memory accounting includes the transcriber and its children.
- `FM_TELEGRAM_DIR` moves the private directory; `bin/fm-telegram.py --help` owns the remaining flags and environment.

The wire protocol between the bot and the Pi extension is stated once in `bin/fm-telegram.py`'s header.

## What still needs your Mac

The regressions below run on any host, and the macOS service tests drive the real service commands against a stand-in for launchd where the host has none.
That proves the lifecycle decisions - what is started, what is waited for, what is refused, and what is rolled back - but it cannot prove the things only macOS itself supplies.
Until the checklist below has been run on your Mac, treat macOS support as implemented and unverified rather than accepted:

- Real `launchctl`: whether `bootstrap`, `bootout`, `enable`, `disable`, `print`, and `print-disabled` behave in your login session as modelled, including the exit codes and the `gui/<uid>` domain.
- Real `plutil`: whether it accepts the generated LaunchAgent.
- macOS peer identity: whether the bot can read the connected Pi session's account and process from the socket, which uses macOS's own local-peer options rather than the Linux ones.
- Real Apple Silicon Parakeet: whether your configured command transcribes a voice note under the LaunchAgent's own environment.

A GitHub macOS runner cannot stand in for this, because it has no logged-in GUI session for the LaunchAgent to load into.

### Checklist for your Mac

Each step is one command and one thing to look for.

1. `bin/fm-telegram.py install-service` then `bin/fm-telegram.py status` - it reports the definition as `owned`, enabled, and running with a pid.
2. `launchctl print gui/$(id -u)/com.firstmate.telegram` - one job, one pid, loaded from the file `status` named.
3. `plutil -lint ~/Library/LaunchAgents/com.firstmate.telegram.plist` - it reports OK, and `grep` finds neither your token nor your paired ids in that file.
4. Start Pi in your Firstmate home, then `/telegram` in the terminal - the footer stops saying `unavailable` and the bot answers, which is the peer identity working.
5. Send `/telegram_on` from your phone, type a message in the terminal, and send one from Telegram - both directions arrive, and the Telegram one is confirmed.
6. Send a screenshot from Telegram and paste one into the terminal - each arrives as a real image at the other end.
7. Send a voice note and tap `Send to Firstmate` - it transcribes with your local command, and `~/.firstmate-telegram/audio/` is empty afterwards.
8. `bin/fm-telegram.py restart-service` while that Pi session is up - it returns success, `status` shows a new pid, and the footer recovers on its own.
9. `bin/fm-telegram.py disable-service`, then log out and back in - the bot does not come back, and `launchctl print-disabled gui/$(id -u)` lists it as disabled.
10. `bin/fm-telegram.py install-service` again, then log out and back in - the bot is running before you touch anything.
11. `bin/fm-telegram.py uninstall-service` - the LaunchAgent file is gone, `launchctl print` no longer finds the job, and nothing starts at the next login.

Regression entry points:

```sh
tests/fm-telegram-mirror.test.sh
tests/fm-telegram-macos-service.test.sh
tests/fm-telegram-extension.test.sh
tests/fm-session-lock-ancestry.test.sh
tests/fm-pi-primary-types.test.sh
FM_TELEGRAM_LIVE_E2E=1 tests/fm-telegram-mirror-live-e2e.test.sh
```
