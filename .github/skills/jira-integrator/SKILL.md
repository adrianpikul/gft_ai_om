---
name: jira-integrator
description: Read Jira issue details, all comments, and readable attachments by running the local PowerShell integrator script. Use this only when fetching a Jira issue's title, description, acceptance criteria, comments, or attachment text.
---

Use only the `integrator.ps1` script in this skill directory for Jira access.

Supported operation only:

- Get issue details, all comments, and attachment extraction results

Forbidden operations:

- Creating, editing, transitioning, assigning, deleting, or otherwise mutating Jira issues
- Creating, editing, or deleting Jira comments or attachments
- Managing projects, users, fields, versions, sprints, boards, or workflows

If the user asks for a forbidden operation, refuse and stop. Do not attempt a nearby alternative.

Authentication rules:

- Use only `gft_ai_om_jira_pat` as a Bearer token.
- Use only `gft_ai_om_jira_url` for the Jira base URL.
- Do not use Jira MCP, browser tools, stored credentials, or interactive login flows.
- If either environment variable is missing or invalid, stop and report the script error.

Invocation rules:

- Run the script from the current PowerShell host when available; if a PowerShell executable must be launched on Windows, use `powershell.exe`.
- Invoke the script from this directory or by absolute path.
- Use its JSON result directly; do not re-query Jira by another means.

Command:

```powershell
./integrator.ps1 get-issue-details -IssueKey "PROJ-123"
```

`get-issue-details` requires `-IssueKey` and returns title, description, acceptance criteria when a field named `Acceptance Criteria` exists, all comments, and attachment metadata plus extraction results. JSON, CSV, log, text, and EML files are extracted with built-in capabilities. MSG and unsupported file types are reported per attachment without failing the complete request.

The script is read-only, returns exactly one JSON document on success, and exits non-zero with a plain stderr error on failure.
