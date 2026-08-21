# Telegram mirror verification

This record covers the bounded issue-5 architecture and is maintained with the opt-in smoke.

## 2026-08-21

The installed Pi package was inspected against its extension, RPC, session-format, and TUI contracts before implementation.
The portable checks are `bash tests/fm-telegram-mirror.test.sh` and `bash tests/fm-telegram.test.sh`.
The opt-in installed-runtime check is `FM_TELEGRAM_PI_SMOKE=1 bash tests/fm-telegram-mirror-live-e2e.test.sh`.
The smoke requires a usable installed Pi runtime and does not read a Telegram token or real home state.
The smoke must observe source=`extension`, user and assistant message lifecycle events, and `agent_settled` before this dated record is refreshed.
