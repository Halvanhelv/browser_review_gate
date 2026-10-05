# Changelog

## 0.1.1

- Reviewers whose requests were taken back are asked again automatically once the run is published.
  The workflow now also runs when the `browser-verified` or waiver label is added.
- A waiver label lets someone other than the author open review without a browser run.
- The state is shown as a commit status next to the other checks.
- Before `gh pr create` or a review request, the agent hook says when a browser run is still owed.
- The agent no longer starts the app: `status` reports whether it answers, and the playbook tells the
  agent to ask the person.
- One notice comment per PR instead of one per commit.
- Comments that ask for a browser run mention whoever pushed the commit and the PR author. A new commit
  that owes a run gets a new comment instead of an edit, so the mention notifies.
- Project rules in `.github/browser-review-gate/rules.md`: what the application always checks and which
  scenarios its areas need. CI and the agent both read them.
- `eject policy` and `eject playbook` copy the built-in texts into the project for full rewriting.
- Agent hooks stay silent on a machine where the gem is not installed.
- The paused-review notice says when a published run no longer covers the latest commits.
- The generated workflow uses `actions/checkout@v7`.

## 0.1.0

- CI assessment and review gate in one command (`ci`).
- Local `status`, `save`, `publish`, `request-assessment` and `hook` commands.
- Installer and Rails generator with detection of Claude Code, Cursor and Codex.
