# browser_review_gate

Keeps human review of a pull request behind a browser run of its browser-visible changes.

- CI reads each PR and decides whether it changes what a person sees or does in a browser. The decision goes into one PR comment, together with the scenarios a browser run must pass and why each one is needed.
- When a run is needed and none is published, reviewer requests are taken back and the PR says which command to run.
- An AI coding agent (Claude Code, Cursor, Codex) runs the scenarios in a real browser with its own browser tool and publishes what it observed, with evidence: screenshots, traces, console errors and failed requests.
- The gem checks the report strictly, compares its cases with CI's list, and opens review only when every scenario has a case that counts.

**What it is not.** The gem is an orchestration and enforcement layer. It does not drive a browser and ships no browser runtime: the agent does the run with Playwright, Chrome DevTools MCP or whatever browser tool it has. The gem decides what must be run, checks what the agent reports, and keeps review on hold until the report covers the change.

## Install

```sh
bundle add browser_review_gate --group development
bundle exec browser-review-gate install
bundle exec browser-review-gate doctor
```

In a Rails app the install step is also `bin/rails generate browser_review_gate:install`.

One run sets up everything and can be repeated after a gem update (it is idempotent and leaves files you wrote alone unless you pass `--force`):

| File | Purpose |
|---|---|
| `.github/workflows/browser-review-gate.yml` | Assesses PRs and takes back premature reviewer requests |
| `.github/browser-review-gate.yml` | Settings (see below) |
| `.github/browser-review-gate/rules.md` | Your application's rules in plain language, read by the model and the agent |
| `docs/browser-review-gate.md` | The playbook every agent follows |
| `.claude/skills/browser-pr-verification/SKILL.md`, hook in `.claude/settings.json` | Claude Code |
| `.cursor/commands/browser-pr-verification.md`, hook in `.cursor/hooks.json` | Cursor |
| Section in `AGENTS.md`, hook in `.codex/hooks.json` | Codex and other agents that read `AGENTS.md` |

The installer detects which agents the project uses and sets up all of them; choose with `--agents claude,cursor,codex`, preview with `--dry-run`.

Then:

1. Add one secret to the repository: `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `GEMINI_API_KEY`.
2. Describe your environments in `.github/browser-review-gate.yml`.
3. Merge to the default branch. The workflow uses `pull_request_target`, so it runs from there.
4. Optionally make the `browser-verification` status a required check so the gate also blocks merging.

`browser-review-gate doctor` checks all of it and says what to fix.

## How a PR goes through

1. The author runs `/browser-pr-verification` (the agent command) on the branch. The agent runs `browser-review-gate verify --json`, which says what to run, in which environment, and whether the app answers.
2. The agent runs the scenarios in its browser tool, writes a report with evidence next to it, and runs `browser-review-gate verify --report PATH`. Before the PR exists the run is saved for that commit; afterwards it is published.
3. When the PR is opened, the agent's post-command hook publishes the saved run.
4. CI assesses the PR, adds the project's mandatory scenarios, and matches the published cases against the list. When every scenario has a counting case, reviewer requests stay; reviewers taken back earlier are asked again automatically.

Later commits keep the verification unless they add a scenario no counting case covers; then only the new scenarios need to run (`scenarios.reuse_passing`).

## Settings

`.github/browser-review-gate.yml`. Every key is optional; an unknown key or a malformed value is an error, never silently ignored. **Enforced** settings are checked by the gem; **agent** settings are instructions the agent receives through `verify` and `status`.

```yaml
environments:
  local:
    url: "http://localhost:3000"     # what the agent opens
    healthcheck: "/up"               # path on url, or a full URL; what verify/doctor ask
    start_command: "bin/dev"         # what the person runs; nothing starts the app automatically
    sign_in: "Use the seed accounts from db/seeds.rb"
  staging:
    url: "https://staging.example.com"
    healthcheck: "/up"

verification:
  environment: local                 # default; override with --environment
  fail_on_console_errors: true       # enforced
  fail_on_network_errors: false      # enforced

evidence:
  screenshots: on_failure            # agent: never | on_failure | always; enforced with gate.require_evidence
  trace: never                       # agent: never | on_failure | always; enforced with gate.require_evidence
  console_logs: true                 # agent; enforced with gate.require_evidence
  network_logs: true                 # agent; enforced with gate.require_evidence
  retention_days: 14                 # enforced: saved runs and kept evidence in .git are pruned
  link_hosts: ["artifacts.example.com"]  # enforced: hosts evidence links may point to

scenarios:
  max_count: 12                      # enforced: most scenarios the model may ask for (1-30)
  reuse_passing: true                # enforced: earlier passing cases on PR commits keep counting
  mandatory:                         # enforced: added by the gem, not proposed by the model
    - id: SIGN-IN
      name: Sign in and land on the dashboard
      why: Authentication changes must keep sign-in working.
      paths: ["app/controllers/sessions_controller.rb", "app/views/sessions/**"]
      matrix: true
  matrix:                            # enforced: at most 24 mandatory cases after expansion
    role: [admin, member]
    viewport: [desktop, mobile]

gate:
  require_evidence: false            # enforced: passing cases need the evidence asked for above
  block_on_failure: true             # enforced: any failing case keeps review on hold

provenance:
  trace: "off"                       # enforced: off | warn | require (see "Checking that a run happened")
  revision_header: "X-App-Revision"
  check_pages: true
  clock_skew_seconds: 300
```

Other keys: `provider` and `model` (who assesses, see below), `workflow`, `label`, `waiver_label`, `waiver_by_author`, `status_context`, `command`, `skip_authors`, `skip_branch_prefixes`, `ignore_paths`.

**Environments.** A local agent uses `local`. A cloud agent cannot reach `localhost`: give it an environment it can reach (staging, a preview deployment) and run `verify --environment staging`. `url` is what the agent opens; `healthcheck` may point elsewhere, for example a full health URL behind the same host. Put no credentials in this file: it is in the repository, and its values appear in `verify` output.

**Mandatory scenarios and matrices.** A mandatory entry with `paths` makes a run required whenever the change touches those paths, whatever the model decides. Without `paths` it is added to every run that is required. `matrix: true` repeats it for every combination of the matrix, as ids such as `SIGN-IN.admin.mobile`, so the gate can tell exactly which combination is missing.

**Not configurable on purpose.** Run timeouts and retries are not settings: the browser run happens in the agent, and the gem cannot enforce them. Tell the agent in `rules.md` if you have expectations.

## Checking that a run happened

Off by default. A report is the agent's account; `provenance.trace` lets the gem check it against a Playwright trace instead of taking it on trust.

1. Make the app name the commit it serves, in development only:

   ```ruby
   # config/environments/development.rb
   config.middleware.use BrowserReviewGate::RevisionHeader
   ```

   It adds `X-App-Revision: <HEAD SHA>` to every response and follows new commits without a restart. Any other way of sending the header works too; name it in `provenance.revision_header`.
2. Set `provenance.trace` to `warn` (results shown in the PR) or `require` (a passing case counts only with a verified trace). `doctor` checks that the app sends the header and that it matches the checkout.
3. The agent records a Playwright trace (`.zip`) or a HAR network log (`.har`) per case and lists it as `evidence.trace`. HAR is a standard format that Playwright, Chrome DevTools ("Save all as HAR") and many other tools write, so the check does not need Playwright itself. A browser tool that can save neither cannot satisfy `require`; `doctor` and `verify` warn about it before a run.

When the run is published, the gem opens each trace (a zip, or HAR JSON; read in memory with size, entry and compression-ratio caps, no extra dependency) and checks its network log: a response carried the revision header with the tested commit, the case's page was requested, and the request times fall within `started_at`..`finished_at` (± `clock_skew_seconds`). The PR shows "trace verified" or what was wrong.

What it catches: an agent that reports a run it did not do, ran against another commit or a stale server, or ran a different page. What it does not catch: someone who builds a trace by hand. It is a check on agents, not an attestation.

## Reports

A report is JSON in the shape the playbook describes (`schema_version: 2`): the tested commit (full SHA), the environment, the browser tool and its capabilities, start and finish times, and one case per scenario with `result` (`pass`, `fail`, `blocked`, `skipped`), the page, what was observed, and evidence.

- Screenshots (`.png`, `.jpg`, `.webp`) and traces (`.zip` Playwright traces or `.har` network logs) are read from the report's directory. Paths that leave it, links, wrong file types (checked by content, not just name) and files over 20 MB are refused. Accepted files are hashed and kept in the git directory; the PR shows their names, sizes and SHA-256 digests, not the files.
- Console errors and failed requests are trimmed, query strings are dropped, and values that look like credentials are masked.
- Evidence links are accepted only on hosts listed in `evidence.link_hosts`; use them to point reviewers at screenshots you uploaded to your own artifact store.
- A case counts when it passes, breaks no enforced policy, and was tested on a commit of the PR.

The PR comment shows every scenario as passed, failed, blocked, skipped, missing or stale, the environment and tool, the tested commit of each case, and the evidence. It says plainly that observations are the agent's account.

## Commands

```
browser-review-gate install [--agents LIST] [--gem-source SOURCE] [--workflow NAME] [--force] [--dry-run]
browser-review-gate eject policy|playbook       copy a built-in text into the project to rewrite it
browser-review-gate doctor [--json]             check the setup; PASS, WARN, FAIL or SKIP with a fix
browser-review-gate verify [--pr N] [--environment NAME] [--report PATH] [--no-request] [--json]
browser-review-gate status [--pr N] [--environment NAME]   the raw facts verify works from, as JSON
browser-review-gate publish [--pr N] [--report PATH]
browser-review-gate save --report PATH
browser-review-gate request-assessment N
browser-review-gate hook claude|cursor|codex    post-command hook
browser-review-gate ci N                        what the workflow runs
browser-review-gate stats [--days N] [--json]   what the gate did on recent PRs
```

`verify` exit statuses: 0 nothing to do or published and verified; 2 a run is needed; 3 the environment does not answer; 4 an assessment was requested or is missing; 5 check out the PR head, or open the PR; 6 a saved run waits; 7 published but not verified; 1 error.

`doctor` checks Ruby, the executable, the repository, the settings, `gh` and its sign-in, your push access, each environment's health check, agent files and hooks, a browser tool configured in the project, the workflow and its version, whether the status is a required check, and whether a model secret exists (by name). What it cannot see from your machine is SKIP, never PASS.

`stats` counts PRs assessed, needing a run, verified, waived and still owing one; published runs and runs with a failure; scenarios that are failing; the median time from opening a PR to its verified run; and the token usage and cost of the latest assessment of each PR, only as the provider reported them. The Claude Code CLI reports cost; the APIs report tokens only, so no cost is shown for them.

Local commands need the `gh` CLI, signed in.

## Who assesses a PR

The assessment is one model call without tools. Which model makes it follows from the secret you added:

| Secret | What runs |
|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` | The Claude Code CLI |
| only `OPENAI_API_KEY` | The OpenAI API; set `model` |
| only `GEMINI_API_KEY` | The Gemini API; set `model` |

Set `provider` to `claude-cli`, `anthropic`, `openai` or `gemini` to choose explicitly. When the call fails, review stays on hold.

## Fitting it to your application

**Add rules.** Write under the headings of `.github/browser-review-gate/rules.md` in plain language: when a run is needed, what every run checks, which scenarios each area needs, which accounts and data to use. The model reads them when it assesses; the agent reads them when it picks scenarios. Use `scenarios.mandatory` and `scenarios.matrix` for anything that must not depend on a model following instructions.

**Replace the built-in text.** `eject policy` copies the decision policy to `.github/browser-review-gate/policy.md`; `eject playbook` hands `docs/browser-review-gate.md` over to the project.

## Security

- The workflow runs on `pull_request_target` from the base branch with `contents: read`, `issues: write`, `pull-requests: write` and `statuses: write`. PR code is never checked out or executed; the diff is read through the API as data. Only the PR number reaches the shell.
- Settings, rules and the policy are read from the base branch in CI, so a PR cannot change the rules of its own assessment. Local commands read the settings from `origin/HEAD` when it has them, so a PR branch cannot point the agent at another URL or loosen the policy for its own run (`settings_source` in `verify --json` says which was used).
- The assessing model gets the PR as escaped data with no tools and answers in a fixed JSON schema; the gem validates the answer and does every write. An invalid answer or a failed call keeps review on hold.
- The decision comment counts only from `github-actions[bot]`; a report counts only from someone with push access. Anyone else's comments are ignored as evidence.
- Reports are validated strictly; evidence paths are confined to the report directory, symbolic links are refused, file types are checked by content, and logged URLs and messages are scrubbed.
- Health checks go only to http(s) URLs from the settings, with a HEAD request, short timeouts and no redirects.

Residual risks, stated plainly:

- **A report is the agent's account, not an attestation.** Someone with push access can publish a passing report for a run that did not happen. With `provenance.trace: require` an agent cannot do so by accident or by guessing, but a hand-built trace still passes. Human review remains the control.
- **Evidence files stay local.** Reviewers see digests, not screenshots, unless you upload them and link them through `evidence.link_hosts`.
- **Scrubbing is pattern-based.** It catches common credential shapes, not everything. Agents are told not to record secrets; screenshots and traces are never inspected.
- **A taken-back review request may still notify the reviewer**, because GitHub has no way to refuse a request.
- **GitHub lists at most 250 commits of a PR**; on longer PRs, cases from older commits stop counting.
- **The gate does not block merging by itself.** Make the status a required check for that.

## Upgrading from 0.2

0.3 changes the report format and the settings; nothing from 0.2 is read.

- Move `url`, `start_command` and `sign_in` under `environments.local`.
- Re-run `browser-review-gate install` to update the workflow, the playbook and the agent files.
- Reports published by 0.2 do not count any more: PRs that were verified with one need a new run, or a waiver.

## Development

```sh
bundle install
bundle exec rake test
```
