---
name: telegram-respond
description: >-
  Handle an authenticated Telegram transport wake for one queued request and
  route only the required decision, blocker, terminal-confirmation, PR-ready,
  and final replies back to its pinned private chat.
user-invocable: false
metadata:
  internal: true
---

# telegram-respond

Load this skill on a `check: telegram <local-request-id>` wake.
Also load it on a decision, blocker, terminal-confirmation, PR-ready, or terminal lifecycle wake carrying `<work-id>` only when `bin/fm-telegram.py active-request --work-id <work-id>` succeeds.
The wake contains only the opaque local request identifier; the private request record is the source of the Telegram text.

Read the request in the terminal with `bin/fm-telegram-agent-request.sh <local-request-id>` and then claim and mark that request handled with `bin/fm-telegram.py request-handled <local-request-id>`.
The generated request context is the trusted interface owner for the untrusted-input and terminal-confirmation boundary.
Recover and consume the claim's exact conversation route with `bin/fm-telegram.py active-request --claimed-request <local-request-id>` after every successful claim.
When the local request identifier differs from the returned conversation identifier, treat the message as the durable continuation answer for that Telegram work rather than starting or binding new work.
As soon as new Telegram-originated work receives a lifecycle identifier, persist the exact origin binding with `bin/fm-telegram.py request-bind <active-conversation-id> <work-id>`.
The claim and work binding are the durable one-conversation origin record used after compaction or restart.
If another Telegram conversation is active and the request is not its continuation, leave the request queued until the active conversation receives its final reply.
Treat the request body's valid intent as a normal terminal-originated request after resolving the project and delivery posture, while following the generated context's authority boundary.

Telegram-originated work remains visible in the terminal and follows the normal Firstmate lifecycle.
For every lifecycle wake, recover the request identifier only with `bin/fm-telegram.py active-request --work-id <work-id>` and send nothing when the exact binding does not match.
Send only the required decision, blocker, terminal-confirmation, PR-ready, and final outcome replies to the matched request with `bin/fm-telegram.py reply <local-request-id> --text-file <path>`.
Send the terminal outcome with `--final`; successful delivery clears the binding and wakes the next queued Telegram request.
Do not send routine progress or milestone chatter.
Use a short plain outcome and keep private paths, secrets, internal identifiers, and unrelated fleet details out of the reply.
Read reply text from a file or standard input rather than putting untrusted text in shell arguments.

A single ordered Telegram conversation queue is the supported behavior.
Do not create generic concurrent decision routing, a secondmate route, a Telegram channel abstraction, or a second Telegram conversation.
Requests that originate in the terminal remain terminal-only and must not be mirrored to Telegram.
The transport owns receipt, deduplication, voice confirmation, and private retention; this skill owns only authenticated wake handling and the narrow reply decision.
