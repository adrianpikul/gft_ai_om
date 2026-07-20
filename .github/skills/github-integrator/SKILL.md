---
name: github-integrator
description: Read pull requests and add approved pull request comments for the current repository by running the local integrator.ps1 script. Use this only for listing open PRs, fetching PR details, adding a PR summary comment, or adding an inline comment on a changed PR diff line.
---

Use only the `integrator.ps1` script in this skill directory for GitHub access.

Supported operations only:
- Detect repository host, owner, and repo from git remotes
- List open pull requests
- Get PR details including title, changed files, and comments
- Add a PR summary comment
- Add an inline PR file comment on a changed diff line

Forbidden operations:
- Deleting, merging, closing, reopening, or editing pull requests
- Deleting or editing comments
- Issue management
- Labels, reviewers, assignees, milestones, branches, releases, or workflow changes
- Any GitHub write action other than the two approved comment flows above

If the user asks for a forbidden operation, refuse and stop. Do not attempt a nearby alternative.

Authentication rules:
- Use only the `gft_ai_om_github_pat` environment variable
- Do not use GitHub MCP, `gh auth`, browser tools, stored credentials, or any interactive login flow
- If `gft_ai_om_github_pat` is missing or invalid, stop and report the script error

Invocation rules:
- Run the script from the current PowerShell host when available; if a PowerShell executable must be launched on Windows, use `powershell.exe`
- Do not require `pwsh` and do not fail over to GitHub connectors or `gh`
- Run the script from this skill directory or invoke it by absolute path so relative lookup is stable
- Prefer structured output from the script and use it directly instead of re-querying GitHub with other tools
- Do not narrate host fallback or JSON parsing steps unless script execution fails

Commands:

```powershell
./integrator.ps1 detect-repo
./integrator.ps1 list-open-prs
./integrator.ps1 list-open-prs -State all -Page 1 -PerPage 100
./integrator.ps1 get-pr-details -PrNumber 123
./integrator.ps1 add-pr-summary-comment -PrNumber 123 -Body "Summary text"
./integrator.ps1 add-pr-line-comment -PrNumber 123 -FilePath "src/app.ts" -Line 42 -Body "Please revisit this logic."
```

Command requirements:
- `list-open-prs` accepts optional `-State`, `-Page`, and `-PerPage`
- `get-pr-details` requires `-PrNumber`
- `add-pr-summary-comment` requires `-PrNumber` and `-Body`
- `add-pr-line-comment` requires `-PrNumber`, `-FilePath`, `-Line`, and `-Body`

Inline comment rules:
- Inline comments are allowed only on changed lines that exist in the current PR diff
- If the requested file or line is not part of the PR diff, stop and report the script error

The script returns exactly one JSON document on success and exits non-zero with a plain stderr error on failure.
