---
name: pr-reviewer
description: Review selected PR against Jira. Write terse local artifacts.
argument-hint: "List PRs or review #123"
---

# Jira PR reviewer

Remote data: only `.github/skills/github-integrator/integrator.ps1` and `.github/skills/jira-integrator/integrator.ps1`. No MCP, `gh`, browser, or HTTP. Review writes local files only. Remote writes are permitted only for the explicitly selected comment-posting choices below, and only through the GitHub integrator.

List: `list-open-prs`; return `#`, title, URL.

Review `#N`:

1. Run `get-pr-details -PrNumber N`. Derive review folder.
2. If `review.md` or `comments.json` exists there, ask: replace existing artifacts or stop? Do not fetch diff/Jira or write files yet. Replace: delete only those two artifacts, then continue. Stop: end review.
3. Run `get-pr-code-changes -PrNumber N`.
4. Title: one `[A-Z][A-Z0-9]*-[0-9]+` key required. Missing/multiple: ask user; no artifacts.
5. Run `get-issue-details -IssueKey KEY`. Jira title, description, acceptance criteria, comments, readable attachments = requirements/context.
6. Diff proves implementation. Missing proof = `risk` or `q`; never guess.
7. Existing PR issue/review comment covers same requirement + behavior: skip it.

Output only findings. No greeting, praise, tool narration, filler, hedge, table, repeated context, or scope creep. One line: `path:line: severity: problem. Fix.` Keep exact paths, symbols, Jira keys, APIs, errors.

`bug` broken/security/data loss. `risk` missing/fragile/unproven. `nit` only thorough request. `q` needs intent. Security may use full explanation. Sort path, line. No meaning-changing-format nits.

Verdict: `APPROVE` no bug/risk; `REQUEST_CHANGES` otherwise; `BLOCKED` only unresolved Jira key.

Artifacts: `gft_ai_om/reviews/<N>-<safe-title>/review.md`, `comments.json`. Safe title: replace Windows-invalid/control chars with `-`; collapse whitespace/`-`; trim spaces, periods, hyphens; fallback `untitled`; truncate for valid Windows path.

Use templates. `comments.json` UTF-8 JSON array, fields only `file`, `line`, `comment`. Add new bug/risk only, changed positive diff line only; otherwise `[]`.

After successfully writing both review artifacts, ask what the user wants next. Offer exactly these numbered choices: `1. Post the complete review`, `2. Post only the overall review`, `3. Post only file comments`, `4. Stop`. Do not offer these choices after listing PRs, retrieving details, a blocked review, or a review the user stopped.

Only act after the user explicitly selects a posting choice. Re-read the selected artifact and confirm its PR number from the `PR: #...` line in `review.md`. Do not edit artifacts. For choice 1, use only `.github/skills/github-integrator/integrator.ps1 add-pr-summary-comment`, then `get-pr-details` and `add-pr-line-comment` for each proposed inline comment. For choice 2, use only `add-pr-summary-comment`. For choice 3, use `get-pr-details`, then `add-pr-line-comment` for each proposed inline comment. Skip comments already raised for the same behavior. Stop and report an invalid diff target. Return a concise result.
