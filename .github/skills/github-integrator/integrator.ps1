[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [int]$PrNumber,
    [string]$FilePath,
    [int]$Line,
    [string]$Body,
    [ValidateSet('open', 'closed', 'all')]
    [string]$State = 'open',
    [int]$Page = 1,
    [int]$PerPage = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [int]$ExitCode = 1
    )

    [Console]::Error.WriteLine($Message)
    exit $ExitCode
}

function Write-Json {
    param(
        [Parameter(Mandatory = $true)]
        $Value
    )

    $Value | ConvertTo-Json -Depth 20 -Compress
}

function Select-PrSummary {
    param(
        [Parameter(Mandatory = $true)]
        $PullRequest
    )

    return @{
        number = $PullRequest.number
        title = $PullRequest.title
        url = $PullRequest.html_url
        state = $PullRequest.state
        isDraft = [bool]$PullRequest.draft
        createdAt = $PullRequest.created_at
        updatedAt = $PullRequest.updated_at
        author = if ($null -ne $PullRequest.user) { $PullRequest.user.login } else { $null }
        head = if ($null -ne $PullRequest.head) { $PullRequest.head.ref } else { $null }
        base = if ($null -ne $PullRequest.base) { $PullRequest.base.ref } else { $null }
    }
}

function Select-PrListItem {
    param(
        [Parameter(Mandatory = $true)]
        $PullRequest
    )

    return @{
        number = $PullRequest.number
        title = $PullRequest.title
        url = $PullRequest.html_url
    }
}

function Select-PrFileSummary {
    param(
        [Parameter(Mandatory = $true)]
        $File
    )

    return @{
        path = $File.filename
        status = $File.status
        additions = $File.additions
        deletions = $File.deletions
        changes = $File.changes
    }
}

function Select-IssueCommentSummary {
    param(
        [Parameter(Mandatory = $true)]
        $Comment
    )

    return @{
        id = $Comment.id
        url = $Comment.html_url
        author = if ($null -ne $Comment.user) { $Comment.user.login } else { $null }
        createdAt = $Comment.created_at
        updatedAt = $Comment.updated_at
        body = $Comment.body
    }
}

function Select-ReviewCommentSummary {
    param(
        [Parameter(Mandatory = $true)]
        $Comment
    )

    return @{
        id = $Comment.id
        url = $Comment.html_url
        author = if ($null -ne $Comment.user) { $Comment.user.login } else { $null }
        createdAt = $Comment.created_at
        updatedAt = $Comment.updated_at
        path = $Comment.path
        line = $Comment.line
        side = $Comment.side
        commitId = $Comment.commit_id
        body = $Comment.body
    }
}

function Get-RequiredPat {
    $pat = [Environment]::GetEnvironmentVariable('gft_ai_om_github_pat')
    if ([string]::IsNullOrWhiteSpace($pat)) {
        Fail "Environment variable 'gft_ai_om_github_pat' is required."
    }

    return $pat.Trim()
}

function Get-GitRemoteUrl {
    try {
        $null = & git rev-parse --is-inside-work-tree 2>$null
        if ($LASTEXITCODE -ne 0) {
            Fail 'Current directory is not inside a git repository.'
        }
    }
    catch {
        Fail "Failed to verify git repository: $($_.Exception.Message)"
    }

    $originUrl = $null
    try {
        $originUrl = (& git remote get-url origin 2>$null | Select-Object -First 1)
    }
    catch {
        $originUrl = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($originUrl)) {
        return $originUrl.Trim()
    }

    try {
        $remoteNames = & git remote 2>$null
    }
    catch {
        $remoteNames = @()
    }

    foreach ($remoteName in $remoteNames) {
        if ([string]::IsNullOrWhiteSpace($remoteName)) {
            continue
        }

        try {
            $remoteUrl = (& git remote get-url $remoteName 2>$null | Select-Object -First 1)
        }
        catch {
            $remoteUrl = $null
        }

        if (-not [string]::IsNullOrWhiteSpace($remoteUrl)) {
            return $remoteUrl.Trim()
        }
    }

    Fail "No usable git remote was found. Expected 'origin' or another configured remote."
}

function Parse-RemoteInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl
    )

    $sshMatch = [regex]::Match($RemoteUrl, '^(?:ssh://)?git@(?<host>[^/:]+)[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$')
    if ($sshMatch.Success) {
        return @{
            host = $sshMatch.Groups['host'].Value
            owner = $sshMatch.Groups['owner'].Value
            repo = $sshMatch.Groups['repo'].Value
            remoteUrl = $RemoteUrl
        }
    }

    $httpsMatch = [regex]::Match($RemoteUrl, '^https://(?<host>[^/]+)/(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$')
    if ($httpsMatch.Success) {
        return @{
            host = $httpsMatch.Groups['host'].Value
            owner = $httpsMatch.Groups['owner'].Value
            repo = $httpsMatch.Groups['repo'].Value
            remoteUrl = $RemoteUrl
        }
    }

    Fail "Unsupported git remote format: $RemoteUrl"
}

function Get-RepositoryContext {
    $remoteUrl = Get-GitRemoteUrl
    $info = Parse-RemoteInfo -RemoteUrl $remoteUrl

    $apiBaseUrl = if ($info.host -ieq 'github.com') {
        'https://api.github.com'
    }
    else {
        "https://$($info.host)/api/v3"
    }

    return @{
        host = $info.host
        owner = $info.owner
        repo = $info.repo
        remoteUrl = $info.remoteUrl
        apiBaseUrl = $apiBaseUrl
    }
}

function Get-GitHubApiErrorMessage {
    param(
        [Parameter(Mandatory = $true)]
        $Exception
    )

    $message = $Exception.Message
    $responseProperty = $Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) {
        return $message
    }

    try {
        $stream = $responseProperty.Value.GetResponseStream()
        if ($null -eq $stream) {
            return $message
        }

        $reader = [System.IO.StreamReader]::new($stream)
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

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        $BodyObject,
        [ref]$ResponseHeadersRef
    )

    $pat = Get-RequiredPat
    $repoContext = Get-RepositoryContext
    $uri = "$($repoContext.apiBaseUrl)$Path"
    $headers = @{
        Authorization = "Bearer $pat"
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'github-integrator-skill'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    $invokeParams = @{
        Method = $Method
        Uri = $uri
        Headers = $headers
    }

    if ($null -ne $BodyObject) {
        $invokeParams['ContentType'] = 'application/json'
        $invokeParams['Body'] = ($BodyObject | ConvertTo-Json -Depth 20)
    }

    try {
        # Invoke-WebRequest works on both Windows PowerShell 5.1 and PowerShell 7.
        # -UseBasicParsing avoids the Internet Explorer dependency in PowerShell 5.1.
        $response = Invoke-WebRequest @invokeParams -UseBasicParsing
        if ($null -ne $ResponseHeadersRef) {
            $ResponseHeadersRef.Value = $response.Headers
        }

        if ([string]::IsNullOrWhiteSpace($response.Content)) {
            return $null
        }

        return ($response.Content | ConvertFrom-Json)
    }
    catch {
        Fail "GitHub API request failed: $(Get-GitHubApiErrorMessage -Exception $_.Exception)"
    }
}

function Invoke-GitHubApiPagedGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $allItems = @()
    $page = 1

    while ($true) {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $pagedPath = "$Path${separator}per_page=100&page=$page"
        $pageResult = @(Invoke-GitHubApi -Method GET -Path $pagedPath)
        $allItems += $pageResult

        if ($pageResult.Count -lt 100) {
            break
        }

        $page++
    }

    return $allItems
}

function Invoke-GitHubRawGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Accept
    )

    $pat = Get-RequiredPat
    $repoContext = Get-RepositoryContext
    $uri = "$($repoContext.apiBaseUrl)$Path"
    $headers = @{
        Authorization = "Bearer $pat"
        Accept = $Accept
        'User-Agent' = 'github-integrator-skill'
        'X-GitHub-Api-Version' = '2022-11-28'
    }

    try {
        $content = (Invoke-WebRequest -Method GET -Uri $uri -Headers $headers -UseBasicParsing).Content
        if ($content -is [byte[]]) {
            return [System.Text.Encoding]::UTF8.GetString($content)
        }

        return [string]$content
    }
    catch {
        Fail "GitHub API request failed: $(Get-GitHubApiErrorMessage -Exception $_.Exception)"
    }
}

function Get-PullRequestPathPrefix {
    $repoContext = Get-RepositoryContext
    return "/repos/$($repoContext.owner)/$($repoContext.repo)"
}

function Get-PullRequestFiles {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PrNumber
    )

    $prefix = Get-PullRequestPathPrefix
    $result = Invoke-GitHubApiPagedGet -Path "$prefix/pulls/$PrNumber/files"
    return @($result)
}

function Get-PullRequestComments {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PrNumber
    )

    $prefix = Get-PullRequestPathPrefix
    $issueComments = @(Invoke-GitHubApiPagedGet -Path "$prefix/issues/$PrNumber/comments")
    $reviewComments = @(Invoke-GitHubApiPagedGet -Path "$prefix/pulls/$PrNumber/comments")

    return @{
        issueComments = $issueComments
        reviewComments = $reviewComments
    }
}

function Get-DiffLineMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Patch
    )

    $newLine = 0
    $oldLine = 0
    $lineMap = @{}

    foreach ($rawLine in ($Patch -split "`n")) {
        $lineText = $rawLine.TrimEnd("`r")

        $headerMatch = [regex]::Match($lineText, '^@@ -(?<oldStart>\d+)(?:,\d+)? \+(?<newStart>\d+)(?:,\d+)? @@')
        if ($headerMatch.Success) {
            $oldLine = [int]$headerMatch.Groups['oldStart'].Value
            $newLine = [int]$headerMatch.Groups['newStart'].Value
            continue
        }

        if ([string]::IsNullOrEmpty($lineText)) {
            continue
        }

        $prefix = $lineText.Substring(0, 1)
        switch ($prefix) {
            ' ' {
                $oldLine++
                $newLine++
            }
            '+' {
                $lineMap[$newLine] = @{
                    side = 'RIGHT'
                    line = $newLine
                }
                $newLine++
            }
            '-' {
                $oldLine++
            }
            '\' {
            }
            default {
            }
        }
    }

    return $lineMap
}

function Resolve-ReviewCommentTarget {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PrNumber,
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [int]$Line
    )

    $files = Get-PullRequestFiles -PrNumber $PrNumber
    $targetFile = $files | Where-Object { $_.filename -eq $FilePath } | Select-Object -First 1

    if ($null -eq $targetFile) {
        Fail "File '$FilePath' is not part of pull request #$PrNumber."
    }

    if ([string]::IsNullOrWhiteSpace($targetFile.patch)) {
        Fail "File '$FilePath' does not include patch data, so line validation cannot be performed."
    }

    $lineMap = Get-DiffLineMap -Patch $targetFile.patch
    if (-not $lineMap.ContainsKey($Line)) {
        Fail "Line $Line in file '$FilePath' is not a changed line in pull request #$PrNumber."
    }

    $target = $lineMap[$Line]
    return @{
        path = $FilePath
        line = [int]$target.line
        side = $target.side
    }
}

function Detect-Repo {
    $context = Get-RepositoryContext
    return @{
        host = $context.host
        owner = $context.owner
        repo = $context.repo
        remoteUrl = $context.remoteUrl
        apiBaseUrl = $context.apiBaseUrl
    }
}

function List-OpenPrs {
    if ($Page -le 0) {
        Fail 'list-open-prs requires -Page with a positive integer.'
    }

    if ($PerPage -le 0) {
        Fail 'list-open-prs requires -PerPage with a positive integer.'
    }

    if ($PerPage -gt 100) {
        $PerPage = 100
    }

    $prefix = Get-PullRequestPathPrefix
    $responseHeaders = $null
    $prs = @(
        Invoke-GitHubApi -Method GET -Path "$prefix/pulls?state=$State&sort=updated&direction=desc&per_page=$PerPage&page=$Page" -ResponseHeadersRef ([ref]$responseHeaders)
    )
    $linkHeader = $null
    if ($null -ne $responseHeaders) {
        $linkHeader = $responseHeaders['Link']
    }

    $context = Get-RepositoryContext
    return @{
        host = $context.host
        owner = $context.owner
        repo = $context.repo
        count = $prs.Count
        hasMore = -not [string]::IsNullOrWhiteSpace($linkHeader) -and $linkHeader.Contains('rel="next"')
        pullRequests = @($prs | ForEach-Object { Select-PrListItem -PullRequest $_ })
    }
}

function Get-PrDetails {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PrNumber
    )

    $prefix = Get-PullRequestPathPrefix
    $pr = Invoke-GitHubApi -Method GET -Path "$prefix/pulls/$PrNumber"
    $files = Get-PullRequestFiles -PrNumber $PrNumber
    $comments = Get-PullRequestComments -PrNumber $PrNumber
    $context = Get-RepositoryContext

    return @{
        host = $context.host
        owner = $context.owner
        repo = $context.repo
        pullRequest = Select-PrSummary -PullRequest $pr
        files = @($files | ForEach-Object { Select-PrFileSummary -File $_ })
        comments = @{
            issueComments = @($comments.issueComments | ForEach-Object { Select-IssueCommentSummary -Comment $_ })
            reviewComments = @($comments.reviewComments | ForEach-Object { Select-ReviewCommentSummary -Comment $_ })
        }
    }
}

function Get-PrCodeChanges {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PrNumber
    )

    $prefix = Get-PullRequestPathPrefix
    $pr = Invoke-GitHubApi -Method GET -Path "$prefix/pulls/$PrNumber"
    $diff = Invoke-GitHubRawGet -Path "$prefix/pulls/$PrNumber" -Accept 'application/vnd.github.diff'
    $context = Get-RepositoryContext

    return @{
        host = $context.host
        owner = $context.owner
        repo = $context.repo
        pullRequest = Select-PrSummary -PullRequest $pr
        diff = $diff
    }
}

function Add-PrSummaryComment {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PrNumber,
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        Fail 'Comment body must not be empty.'
    }

    $prefix = Get-PullRequestPathPrefix
    $comment = Invoke-GitHubApi -Method POST -Path "$prefix/issues/$PrNumber/comments" -BodyObject @{
        body = $Body
    }

    return @{
        operation = 'add-pr-summary-comment'
        pullRequestNumber = $PrNumber
        comment = $comment
    }
}

function Add-PrLineComment {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PrNumber,
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [int]$Line,
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    if ([string]::IsNullOrWhiteSpace($Body)) {
        Fail 'Comment body must not be empty.'
    }

    $target = Resolve-ReviewCommentTarget -PrNumber $PrNumber -FilePath $FilePath -Line $Line
    $prefix = Get-PullRequestPathPrefix
    $comment = Invoke-GitHubApi -Method POST -Path "$prefix/pulls/$PrNumber/comments" -BodyObject @{
        body = $Body
        path = $target.path
        line = $target.line
        side = $target.side
    }

    return @{
        operation = 'add-pr-line-comment'
        pullRequestNumber = $PrNumber
        path = $target.path
        line = $target.line
        side = $target.side
        comment = $comment
    }
}

switch ($Command) {
    'detect-repo' {
        Write-Json (Detect-Repo)
        break
    }
    'list-open-prs' {
        Write-Json (List-OpenPrs)
        break
    }
    'get-pr-details' {
        if ($PrNumber -le 0) {
            Fail 'get-pr-details requires -PrNumber with a positive integer.'
        }

        Write-Json (Get-PrDetails -PrNumber $PrNumber)
        break
    }
    'get-pr-code-changes' {
        if ($PrNumber -le 0) {
            Fail 'get-pr-code-changes requires -PrNumber with a positive integer.'
        }

        Write-Json (Get-PrCodeChanges -PrNumber $PrNumber)
        break
    }
    'add-pr-summary-comment' {
        if ($PrNumber -le 0) {
            Fail 'add-pr-summary-comment requires -PrNumber with a positive integer.'
        }
        if ([string]::IsNullOrWhiteSpace($Body)) {
            Fail 'add-pr-summary-comment requires -Body.'
        }

        Write-Json (Add-PrSummaryComment -PrNumber $PrNumber -Body $Body)
        break
    }
    'add-pr-line-comment' {
        if ($PrNumber -le 0) {
            Fail 'add-pr-line-comment requires -PrNumber with a positive integer.'
        }
        if ([string]::IsNullOrWhiteSpace($FilePath)) {
            Fail 'add-pr-line-comment requires -FilePath.'
        }
        if ($Line -le 0) {
            Fail 'add-pr-line-comment requires -Line with a positive integer.'
        }
        if ([string]::IsNullOrWhiteSpace($Body)) {
            Fail 'add-pr-line-comment requires -Body.'
        }

        Write-Json (Add-PrLineComment -PrNumber $PrNumber -FilePath $FilePath -Line $Line -Body $Body)
        break
    }
    default {
        Fail "Unsupported command '$Command'. Allowed commands: detect-repo, list-open-prs, get-pr-details, get-pr-code-changes, add-pr-summary-comment, add-pr-line-comment."
    }
}
