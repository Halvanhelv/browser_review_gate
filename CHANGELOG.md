# Changelog

## 0.2.1

- A reviewer who approved or asked for changes on the latest commit while their request was paused
  is not asked again once the browser run is published. The notice names them instead. Someone whose
  review is on an older commit, or who only commented, is still asked again.

## 0.2.0

Re-run `browser-review-gate install` after updating: the workflow and the playbook change.

- CI names the scenarios a browser run must pass and writes them in the PR comment. `status` hands them
  to the agent, and each case is reported under its scenario's id. A run that leaves one out does not
  open review, whatever `coverage_complete` says. Runs made before the PR existed are matched against
  the list when CI first sees them.
- Every submitted case must say where it was exercised (`url`) and what was observed (`details`).
  Reports already published are not affected.
- A browser report counts only from someone who can push to the repository.
- Draft PRs are not assessed until they are marked ready for review. `request-assessment` still
  assesses a draft on demand.
- The assessment can run on the OpenAI or Gemini API, or on the Anthropic API without the Claude Code
  CLI: see `provider` and `model` in the settings file. Nothing changes for a project that keeps its
  `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` secret.
- `stats` counts what the gate did on recent PRs: how many needed a run, were verified, were waived,
  still owe one, and had a run that found a failing case.
- Commands find the settings and the rules from any directory of the repository.

## 0.1.2

- Nothing holds a command back any more. The before-command hooks of 0.1.1, which stopped
  `gh pr create` and review requests while a run was owed, are removed: running the verification is
  the author's choice, and only CI decides whether a review request stays. The installer deletes the
  old hook entries; until then they do nothing.

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
