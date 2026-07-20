# Repository instructions

## GitHub integrator skill

For GitHub pull-request work, use and maintain `.github/skills/github-integrator/integrator.ps1` as the only integration path. Implement every supported workflow in that script; do not require ad-hoc commands, external GitHub tools, or manual steps outside it.

Preserve the skill's read-only boundary except for its explicitly documented PR-comment commands. Keep all successful script output to exactly one JSON document.

## PowerShell scripts

Write every new PowerShell script, and keep every modified PowerShell script, compatible with Windows PowerShell 5.1 as well as PowerShell 7. Do not use PowerShell-7-only syntax, cmdlet parameters, or APIs. For HTTP requests, use `Invoke-WebRequest -UseBasicParsing` and parse JSON explicitly when structured output is required; do not rely on the Internet Explorer web-request engine.
