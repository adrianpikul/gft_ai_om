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
$env:gft_ai_om_jira_url = 'https://jira.example.com'
$env:gft_ai_om_jira_pat = '...'
```
