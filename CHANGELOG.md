# Changelog

## 0.1.1

- Agent hooks stay silent on a machine where the gem is not installed.
- The paused-review notice says when a published run no longer covers the latest commits.
- The generated workflow uses `actions/checkout@v7`.

## 0.1.0

- CI assessment and review gate in one command (`ci`).
- Local `status`, `save`, `publish`, `request-assessment` and `hook` commands.
- Installer and Rails generator with detection of Claude Code, Cursor and Codex.
