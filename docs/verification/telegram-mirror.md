# Telegram mirror verification

This record covers the bounded issue-5 architecture and is maintained with the real-extension fake-transport regression.

## 2026-08-21

The installed Pi package was version `0.84.2` and was inspected against its extension, session-format, and TUI contracts before implementation.
The exact focused verification transcript was:

```text
$ pi --version
0.84.2
$ bash tests/fm-telegram-mirror.test.sh
ok - bounded mirror queue, mode preference, and single-primary claim interface
$ FM_TELEGRAM_MIRROR_LIVE_E2E=1 bash tests/fm-telegram-mirror-live-e2e.test.sh
pass: installed Pi runtime mirror admission, persistence, reload, replacement, preflight, fan-out, exclusions, lock, and crash contract
pass: confirmed voice Send traversed real Python transport and tracked Pi extension
$ bash tests/fm-telegram.test.sh
ok - Telegram mode, queue, voice, chunked delivery, completion, uncertainty, migration, and admission races
```

The live lifecycle regression loads the tracked project extension through the installed Pi SDK runtime with its faux model provider and an executable fake transport, without a Telegram token or real home state.
It proves lock-owned admission, invocation-specific Telegram provenance under nested extension input, consumed-input capacity isolation, a hard live-segment cap, pre-acceptance delivery-limit refusal, durable session provenance, live origin labels, delayed-preflight and busy follow-up admission, ordered slow and blocked response settlement, post-acceptance terminal delivery holds, mode-off preservation of accepted turns, the generated Telegram authority boundary, custom operational and thinking exclusions, terminal and assistant fan-out, confirmed-voice settlement, one bounded provider-error hold with explicit recovery, definitive completion, fresh extension reload and session replacement reconciliation, no terminal history replay, and the accepted acceptance-before-persistence anomaly.
The Python transport regression proves mode-on confirmed-voice queueing, mode-off callback refusal with Cancel cleanup, read-only delivery validation, no operational Telegram wake publication, process-start-bound claim recovery across PID reuse, Unicode-safe chunk delivery, bounded rejection retries, delivery-unknown non-retry, a hard paired-delivery cap across pending and terminal records, completion-bound delivery retention, handled completion, and recurring legacy wake retirement.
