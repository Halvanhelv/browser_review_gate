# browser_review_gate

Keeps human review of a pull request behind a browser run of its browser-visible changes.

- CI reads each PR and decides whether it changes what a person sees or does in a browser. The decision goes into one PR comment.
- When a run is needed and none is published, reviewer requests are taken back and the PR says which command to run.
- An AI coding agent (Claude Code, Cursor, Codex) runs the scenarios in a real browser and publishes what it observed. A complete passing run adds the `browser-verified` label, and review requests stay.

## Install

```sh
bundle add browser_review_gate --group development
bundle exec browser-review-gate install
```

In a Rails app the same thing is `bin/rails generate browser_review_gate:install`.

One run sets up everything and can be repeated after a gem update:

| File | Purpose |
|---|---|
| `.github/workflows/browser-review-gate.yml` | Assesses PRs and takes back premature reviewer requests |
| `.github/browser-review-gate.yml` | Settings: how to start the app, what is never gated, which paths cannot touch the browser |
| `.github/browser-review-gate/rules.md` | Your application's rules: what always gets checked, scenarios by area |
| `docs/browser-review-gate.md` | The playbook every agent follows |
| `.claude/skills/browser-pr-verification/SKILL.md`, hook in `.claude/settings.json` | Claude Code |
| `.cursor/commands/browser-pr-verification.md`, hook in `.cursor/hooks.json` | Cursor |
| Section in `AGENTS.md`, hook in `.codex/hooks.json` | Codex (the `AGENTS.md` section also serves other agents that read it) |

The installer detects which agents the project uses (`.claude/` or `CLAUDE.md`, `.cursor/` or `.cursorrules`, `.codex/` or `AGENTS.md`) and sets up all of them. Choose explicitly with `--agents claude,cursor,codex`. Preview with `--dry-run`. Files you wrote yourself are never replaced without `--force`.

Then:

1. Add a `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` secret to the repository.
2. Fill `start_command`, `url` and `sign_in` in `.github/browser-review-gate.yml`.
3. Merge to the default branch. The workflow uses `pull_request_target`, so it runs from there.

Until the gem is on RubyGems, CI can take it from a git repository (`--gem-source "git:https://host/owner/browser_review_gate.git#v0.1.0"`) or from a copy kept in the project (`--gem-source path:vendor/browser_review_gate`).

## Fitting it to your application

The gem ships with a general decision policy and a general playbook. There are two ways to make them yours.

**Add rules (recommended).** Write under the headings of `.github/browser-review-gate/rules.md`, in plain language:

- when a browser run is needed in this application;
- what every run always checks, such as roles or window sizes;
- which scenarios each area needs;
- which accounts and data to use.

CI reads the rules when it decides whether a PR needs a run and whether a published run still covers it. The agent reads them when it picks scenarios. The built-in policy stays in force and gets updates with the gem; your rules are added on top and win where they disagree. The generated file contains only commented examples and changes nothing until you write in it.

**Replace the built-in text.** `browser-review-gate eject policy` copies the decision policy to `.github/browser-review-gate/policy.md`; `browser-review-gate eject playbook` hands `docs/browser-review-gate.md` over to the project. From then on the gem uses your copy and stops updating it. The frame around the policy — the model's role, the rule that PR content is data, the answer format — is not ejectable.

CI reads all of these from the base branch, so a pull request cannot loosen its own rules.

## How a PR goes through

1. The author runs `/browser-pr-verification` on the branch before opening the PR. The agent runs the scenarios and saves the results for that commit inside the git directory.
2. The PR is opened. In Claude Code, Cursor and Codex a hook publishes the saved results right after `gh pr create` (Codex asks you to trust the hook once in `/hooks`). Anywhere else, the command from the PR comment publishes them without a new run.
3. CI finds a passing run on the PR's own commit and leaves reviewer requests in place.

If the PR is opened without a run, the comment shows the ready command, for example `/browser-pr-verification 42`.

Later commits keep the label unless they add browser behavior the published run does not cover. Then only the new scenarios need to run.

## Commands

```
browser-review-gate install                     set the project up
browser-review-gate eject policy|playbook       copy a built-in text into the project to rewrite it
browser-review-gate status [--pr N]             what the PR needs and what to do next, as JSON
browser-review-gate publish [--pr N] [--report PATH]
browser-review-gate save --report PATH          keep results until the PR is opened
browser-review-gate request-assessment N        assess a PR that has no decision yet
browser-review-gate hook [claude|cursor|codex]  post-command hook
browser-review-gate ci N                        what the workflow runs
```

Local commands need the `gh` CLI, signed in.

## What it does not do

- It cannot refuse a review request. GitHub has no such switch, so the request is taken back seconds after it is made, and the reviewer may still get a notification.
- It does not block merging. Add your own branch protection for that.
- The model that assesses a PR sees the diff as data, has no tools, and answers in a fixed JSON shape. The gem validates the answer and does every write. PR code is never checked out or run in CI.

## Development

```sh
bundle install
bundle exec rake test
```
