# Telegram mirror verification

This record covers the bounded issue-5 architecture and is maintained with focused mirror, transport, and session-start regressions.

## 2026-08-21

The installed Pi package was version `0.84.2` and was inspected against its extension, session-format, and TUI contracts before implementation.
The exact focused verification transcript was:

```text
$ pi --version
0.84.2
$ bash tests/fm-telegram-mirror.test.sh
ok - bounded mirror queue, mode preference, single-primary claim, and legacy migration
$ FM_TELEGRAM_MIRROR_LIVE_E2E=1 bash tests/fm-telegram-mirror-live-e2e.test.sh
pass: installed Pi runtime mirror admission, persistence, reload, replacement, preflight, fan-out, exclusions, lock, and crash contract
pass: confirmed voice Send traversed real Python transport and tracked Pi extension
$ bash tests/fm-telegram.test.sh
ok - Telegram mode, queue, voice, chunked delivery, install restart, and migration
$ bash tests/fm-telegram-reply-links.test.sh
ok - Telegram reply fallbacks, voice transitions, replay, ordering, and progress settlement
$ FM_TELEGRAM_MIRROR_LIVE_E2E=1 FM_TELEGRAM_BASIC_TERMINAL_ONLY=1 FM_TELEGRAM_BASIC_TERMINAL_REARM=1 bash tests/fm-telegram-mirror-live-e2e.test.sh
pass: terminal assistant settlement with immediate operational re-arm (enabled)
pass: confirmed voice Send traversed real Python transport and tracked Pi extension
$ FM_TELEGRAM_MIRROR_LIVE_E2E=1 FM_TELEGRAM_BASIC_TERMINAL_ONLY=1 FM_TELEGRAM_BASIC_TERMINAL_REARM=0 bash tests/fm-telegram-mirror-live-e2e.test.sh
pass: terminal assistant settlement with immediate operational re-arm (counterfactual disabled)
pass: confirmed voice Send traversed real Python transport and tracked Pi extension
```

The live lifecycle regression loads the tracked project extension through the installed Pi SDK runtime with its faux model provider and an executable fake transport, without a Telegram token or real home state.
It proves lock-owned admission, invocation-specific Telegram provenance under nested extension input, consumed-input capacity isolation, a hard live-segment cap, pre-acceptance delivery-limit refusal, durable session provenance, live origin labels, delayed-preflight and busy follow-up admission, ordered slow and blocked response settlement, post-acceptance terminal delivery holds, unfinished terminal-turn abandonment without replay or fabricated fallback, mode-off preservation of accepted turns, the generated Telegram authority boundary, custom operational and thinking exclusions, terminal and assistant fan-out, confirmed-voice settlement, one bounded provider-error hold with explicit recovery, carried-turn fallback recovery, definitive completion, fresh extension reload and session replacement reconciliation, no terminal history replay, and the accepted acceptance-before-persistence anomaly.
The Python transport regression proves mode-on confirmed-voice queueing, mode-off callback refusal with Cancel cleanup, source-bound Pi delivery, an exact-source first-response attempt with unthreaded rejection fallback, exact returned-ID chaining for every later response chunk, crash reconciliation from a definitive per-chunk Bot API acknowledgement, read-only delivery validation, no operational Telegram wake publication, process-start-bound claim recovery across PID reuse, Unicode-safe chunk delivery, bounded rejection retries, delivery-unknown non-retry, a hard paired-delivery cap across pending and terminal records, superseded and orphaned completion cleanup, completion-bound delivery retention, handled completion, and recurring legacy wake retirement.
The native reply regression uses an executable fake Bot API and proves exact source targets for text, voice queue notices, transcribing status, transcript controls, and copyable transcript fallback; source-then-unthreaded deleted-target fallback without fallback retries for rate-limit, authentication, markup, or content errors; outbound-ID journaling; per-source queued voice ordering and promotion; edit/copy_text/ForceReply transitions; retry success and visible failure recovery; acknowledged stale Send, Edit, and Retry revisions; bounded delivery-unknown Cancel cleanup with disabled controls and a source fallback; transcribing settlement before local transcription; and both mode-off cancellation reconciliation and callback race refusal.
The installed-runtime terminal settlement regression uses a disposable fake home and the real Pi extension to compare a basic terminal turn with and without an immediate operational re-arm follow-up.
Both variants produce exactly one terminal user delivery and one paired assistant delivery, while the operational assistant remains excluded.
The focused runtime path therefore does not reproduce the reported missing assistant delivery; the full historical live suite retains separate unrelated coverage and must not be represented by this focused result.
The transport regression also verifies that `install` restarts an exactly owned active unit and refuses a foreign unit, so an updated tracked transport cannot remain hidden behind an older service process.
The session-start migration coverage entry point is `bash tests/fm-session-start.test.sh`; its assertions cover primary-only retirement of legacy Telegram wake rows from the effective wake queue before normal draining while preserving queued request bodies and unrelated wakes.
