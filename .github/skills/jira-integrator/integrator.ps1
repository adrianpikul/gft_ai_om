[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [string]$IssueKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message, [int]$ExitCode = 1)

    [Console]::Error.WriteLine($Message)
    exit $ExitCode
}

function Write-Json {
    param([Parameter(Mandatory = $true)]$Value)

    $Value | ConvertTo-Json -Depth 30 -Compress
}

function Get-RequiredEnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        Fail "Environment variable '$Name' is required."
    }

    return $value.Trim()
}

function Get-JiraBaseUrl {
    $baseUrl = Get-RequiredEnvironmentValue -Name 'gft_ai_om_jira_url'
    $uri = $null
    if (-not [System.Uri]::TryCreate($baseUrl, [System.UriKind]::Absolute, [ref]$uri) -or
        ($uri.Scheme -ne [System.Uri]::UriSchemeHttp -and $uri.Scheme -ne [System.Uri]::UriSchemeHttps)) {
        Fail "Environment variable 'gft_ai_om_jira_url' must be an absolute HTTP(S) URL."
    }

    return $baseUrl.TrimEnd('/')
}

function Get-JiraApiErrorMessage {
    param([Parameter(Mandatory = $true)]$Exception)

    $message = $Exception.Message
    $responseProperty = $Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) {
        return $message
    }

    try {
        $stream = $responseProperty.Value.GetResponseStream()
        if ($null -eq $stream) { return $message }

        $reader = New-Object System.IO.StreamReader($stream)
        try {
            $responseBody = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            return "$message Response: $responseBody"
        }
    }
    catch {
    }

    return $message
}

function Get-JiraHeaders {
    $pat = Get-RequiredEnvironmentValue -Name 'gft_ai_om_jira_pat'
    return @{ Authorization = "Bearer $pat"; Accept = 'application/json'; 'User-Agent' = 'jira-integrator-skill' }
}

function Invoke-JiraApi {
    param([Parameter(Mandatory = $true)][string]$Path)

    $uri = "$(Get-JiraBaseUrl)$Path"
    try {
        $response = Invoke-WebRequest -Method GET -Uri $uri -Headers (Get-JiraHeaders) -UseBasicParsing
        if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }
        return $response.Content | ConvertFrom-Json
    }
    catch {
        Fail "Jira API request failed: $(Get-JiraApiErrorMessage -Exception $_.Exception)"
    }
}

function Get-AcceptanceCriteriaField {
    $fields = @(Invoke-JiraApi -Path '/rest/api/2/field')
    return $fields | Where-Object {
        $_.name -is [string] -and $_.name.Trim() -ieq 'Acceptance Criteria'
    } | Select-Object -First 1
}

function Get-IssueComments {
    param([Parameter(Mandatory = $true)][string]$EscapedIssueKey)

    $comments = @()
    $startAt = 0
    $maxResults = 100
    do {
        $page = Invoke-JiraApi -Path "/rest/api/2/issue/$EscapedIssueKey/comment?startAt=$startAt&maxResults=$maxResults"
        $pageComments = @($page.comments)
        $comments += $pageComments
        $startAt += $pageComments.Count
        $total = [int]$page.total
    } while ($pageComments.Count -gt 0 -and $startAt -lt $total)

    return $comments
}

function Select-Comment {
    param([Parameter(Mandatory = $true)]$Comment)

    $author = $null
    if ($null -ne $Comment.author) {
        $author = if (-not [string]::IsNullOrWhiteSpace([string]$Comment.author.displayName)) { $Comment.author.displayName } else { $Comment.author.name }
    }

    return @{ id = $Comment.id; author = $author; createdAt = $Comment.created; updatedAt = $Comment.updated; body = $Comment.body }
}

function Get-AttachmentTextResult {
    param([Parameter(Mandatory = $true)]$Attachment)

    $temporaryFile = Join-Path ([System.IO.Path]::GetTempPath()) ("jira-attachment-" + [System.Guid]::NewGuid().ToString() + [System.IO.Path]::GetExtension([string]$Attachment.filename))
    try {
        Invoke-WebRequest -Method GET -Uri $Attachment.content -Headers (Get-JiraHeaders) -OutFile $temporaryFile -UseBasicParsing
        $parserScript = Join-Path $PSScriptRoot 'attachment-text.ps1'
        $parserOutput = @(& $parserScript -FilePath $temporaryFile -FileName ([string]$Attachment.filename) 2>$null)
        if ($LASTEXITCODE -ne 0 -or $parserOutput.Count -eq 0) {
            return @{ status = 'error'; text = $null; error = 'Attachment text parser did not return a result.' }
        }

        return (($parserOutput -join "`n") | ConvertFrom-Json)
    }
    catch {
        return @{ status = 'error'; text = $null; error = "Unable to download or parse attachment: $($_.Exception.Message)" }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Select-Attachment {
    param([Parameter(Mandatory = $true)]$Attachment)

    return @{
        id = $Attachment.id
        filename = $Attachment.filename
        mimeType = $Attachment.mimeType
        size = $Attachment.size
        author = if ($null -ne $Attachment.author) { $Attachment.author.displayName } else { $null }
        createdAt = $Attachment.created
        url = $Attachment.content
        extraction = Get-AttachmentTextResult -Attachment $Attachment
    }
}

function Get-IssueDetails {
    param([Parameter(Mandatory = $true)][string]$IssueKey)

    $escapedIssueKey = [System.Uri]::EscapeDataString($IssueKey)
    $criteriaField = Get-AcceptanceCriteriaField
    $requestedFields = @('summary', 'description', 'attachment')
    if ($null -ne $criteriaField) { $requestedFields += [string]$criteriaField.id }
    $fieldQuery = [System.Uri]::EscapeDataString(($requestedFields -join ','))
    $issue = Invoke-JiraApi -Path "/rest/api/2/issue/${escapedIssueKey}?fields=$fieldQuery"
    $comments = Get-IssueComments -EscapedIssueKey $escapedIssueKey
    $criteria = $null
    if ($null -ne $criteriaField) { $criteria = $issue.fields.($criteriaField.id) }

    return @{
        issue = @{
            key = $issue.key
            url = "$(Get-JiraBaseUrl)/browse/$($issue.key)"
            title = $issue.fields.summary
            description = $issue.fields.description
            acceptanceCriteria = $criteria
        }
        comments = @($comments | ForEach-Object { Select-Comment -Comment $_ })
        attachments = @($issue.fields.attachment | ForEach-Object { Select-Attachment -Attachment $_ })
    }
}

switch ($Command) {
    'get-issue-details' {
        if ([string]::IsNullOrWhiteSpace($IssueKey)) { Fail 'get-issue-details requires -IssueKey.' }
        Write-Json (Get-IssueDetails -IssueKey $IssueKey)
        break
    }
    default {
        Fail "Unsupported command '$Command'. Allowed commands: get-issue-details."
    }
}
