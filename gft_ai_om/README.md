# gft_ai_om

## Integration environment variables

Configure these variables in the PowerShell session that runs an integrator. Do not commit their values.

| Integration | Variable | Required value |
| --- | --- | --- |
| GitHub | `gft_ai_om_github_pat` | A GitHub personal access token accepted by the repository host. |
| Jira | `gft_ai_om_jira_url` | The absolute HTTP(S) Jira base URL, for example `https://jira.example.com`. |
| Jira | `gft_ai_om_jira_pat` | A Jira personal access token sent as a Bearer token. |

Example for the current PowerShell session:

```powershell
$env:gft_ai_om_github_pat = '...'
$env:gft_ai_om_jira_url = 'https://jira.example.com/jira'
$env:gft_ai_om_jira_pat = '...'
```

## Copilot usage dashboard

This repository now includes a VS Code Chat hook collector and a static dashboard:

- Hook configuration: `.github/hooks/hooks.json`
- Hook scripts: `gft_ai_om/copilot_usage/scripts/collect-copilot-usage.sh` and `gft_ai_om/copilot_usage/scripts/collect-copilot-usage.ps1`
- Data file: `gft_ai_om/copilot_usage/copilot-usage.json`
- Dashboard: `gft_ai_om/copilot_usage/dashboard.html`

Usage notes:

- Before using the hooks, make the shell script executable on macOS/Linux:
  ```bash
  chmod +x gft_ai_om/copilot_usage/scripts/collect-copilot-usage.sh
  ```
- The hooks are workspace-level VS Code hook files and target VS Code Chat / agent sessions.
- The command paths are rooted at the workspace and call scripts under `gft_ai_om/copilot_usage/scripts/`.
- The collector stores metadata only. It does not persist raw prompt text or full tool output.
- When `dashboard.html` is opened from disk, browsers often block automatic JSON loading. Use the dashboard's `Open JSON File` button to load `copilot-usage.json` directly.
