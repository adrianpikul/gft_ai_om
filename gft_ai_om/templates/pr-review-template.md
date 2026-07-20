# PR Review

PR: #{{pr_number}} — {{pr_title}}
Jira: {{jira_key}} — {{jira_title}}

## Requirement coverage

{{requirement_coverage}}

## Findings

{{findings}}

Verdict: {{verdict}}

<!--
Use one concise line per finding:
path/to/file:42: bug: <what is wrong and its impact>. <required correction>.

For findings without a changed-line location:
general: risk: <what is missing or unproven and its impact>. <required correction>.

Order by path, then ascending line. When there are no findings, write exactly:
No issues.
-->
