---
name: pr-reviewer
description: Review a selected pull request against its Jira requirements. Lists open PRs on request, gathers PR and Jira context through the local integrators, and writes concise local review artifacts without posting comments.
---

# Jira-linked PR reviewer

Review only the selected pull request and its linked Jira issue. Report findings and verdicts; do not add greetings, praise, filler, or unrelated refactor suggestions.

## Allowed integrations

Use only these scripts for remote data:

- `.github/skills/github-integrator/integrator.ps1`
- `.github/skills/jira-integrator/integrator.ps1`

Do not use GitHub or Jira MCP, `gh`, browser login, direct HTTP requests, or any other remote access method. Do not post, edit, or delete GitHub or Jira comments. `comments.json` is a proposal for a later, explicit GitHub-integrator action.

## Workflow

1. When asked for open PRs, run `list-open-prs` and return only the PR number, title, and URL for each result.
2. When the user selects PR `<number>`, run both `get-pr-details -PrNumber <number>` and `get-pr-code-changes -PrNumber <number>`.
3. Inspect the PR title only for Jira-style keys matching `[A-Z][A-Z0-9]*-[0-9]+`.
   - Exactly one distinct key: continue.
   - No key or multiple distinct keys: ask the user to provide or confirm one key. Do not create review artifacts until they do.
4. Run `get-issue-details -IssueKey <key>`. Treat the Jira title, description, acceptance criteria, comments, and readable attachment text as review requirements and context.
5. Compare those requirements against the selected PR's complete diff and changed-file metadata. Do not infer behavior that is not evidenced by the available context. Record missing evidence as a `risk` or `question`, as appropriate.
6. Before reporting a finding, compare it with existing PR issue comments and review comments returned by `get-pr-details`. Do not report or export a finding that already addresses the same Jira requirement and affected behavior. Similar wording alone is not a duplicate.
7. Write the overall review and proposed line comments using the templates in `gft_ai_om/templates/`.

## Findings and verdict

- `bug`: incorrect behavior, crash, security issue, or data loss.
- `risk`: missing requirement, unhandled edge case, unsafe assumption, or insufficient evidence that prevents confidence.
- `nit`: style or minor improvement; emit only when the user explicitly asks for a thorough review.
- `question`: author intent is required before a judgment can be made.

Include only actionable `bug` and `risk` findings in proposed inline comments. Use `APPROVE` when there are no `bug` or `risk` findings. Use `REQUEST_CHANGES` when either exists. Use `BLOCKED` only when Jira context cannot be resolved after requesting key confirmation.

Order findings by file path and ascending line number. Do not emit formatting-only findings unless they change meaning or the user asked for a thorough review.

## Review artifacts

Create `gft_ai_om/reviews/<pr-number>-<safe-title>/` for each completed review.

- Derive `<safe-title>` from the PR title: replace Windows-invalid filename characters (`<`, `>`, `:`, `"`, `/`, `\`, `|`, `?`, `*`) and control characters with `-`; collapse whitespace and repeated `-`; trim leading/trailing spaces, periods, and hyphens; use `untitled` if empty; and truncate before creating the directory so the complete path remains valid on Windows.
- Write the overall result to `review.md`, following `gft_ai_om/templates/pr-review-template.md`.
- Write `comments.json` as a UTF-8 valid JSON array. Each element must contain only `file`, `line`, and `comment` fields. Write `[]` when no new eligible inline comments exist.
- Add an object only when its file and positive line number are changed lines in the current PR diff. Its `comment` value must follow `gft_ai_om/templates/pr-line-comment-template.md`.

Use concise, specific language. A clean review is exactly `No issues.` followed by the `APPROVE` verdict in the overall-review template.
