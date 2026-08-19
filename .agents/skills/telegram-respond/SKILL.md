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
Recover the claim's exact conversation route with `bin/fm-telegram.py active-request --claimed-request <local-request-id>` after every successful claim.
An initial claim returns its active conversation identifier alone and remains durably wakeable until its lifecycle identifier is persisted with `request-bind`, so repeat delivery after an interruption resumes the same claim rather than starting duplicate work.
A continuation claim returns its active conversation identifier and exact bound work identifier as two tab-separated fields; deliver the answer only to that returned work rather than starting or binding new work.
Only after that continuation has been delivered to the returned active work, acknowledge its durable route with `bin/fm-telegram.py continuation-handled <local-request-id>`; interruption before this acknowledgement leaves the same route recoverable.
Before launching or otherwise acting on new Telegram-originated work, select its exact lifecycle identifier and persist the origin binding with `bin/fm-telegram.py request-bind <active-conversation-id> <work-id>`.
For dispatched work, create its durable work record first, bind that chosen identifier, and only then invoke `fm-spawn.sh`.
If binding fails, do not launch or act; if launch fails after binding, keep the same binding and report the launch failure through that lifecycle rather than selecting or starting different work.
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
