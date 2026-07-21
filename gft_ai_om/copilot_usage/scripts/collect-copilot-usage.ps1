[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EventName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-EventName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    switch ($Name.ToLowerInvariant()) {
        'sessionstart' { return 'SessionStart' }
        'sessionend' { return 'Stop' }
        'userpromptsubmitted' { return 'UserPromptSubmit' }
        'userpromptsubmit' { return 'UserPromptSubmit' }
        'userprompttransformed' { return 'UserPromptSubmit' }
        'pretooluse' { return 'PreToolUse' }
        'posttooluse' { return 'PostToolUse' }
        'posttoolusefailure' { return 'ErrorOccurred' }
        'agentstop' { return 'Stop' }
        'subagentstart' { return 'SubagentStart' }
        'subagentstop' { return 'SubagentStop' }
        'erroroccurred' { return 'ErrorOccurred' }
        'precompact' { return 'PreCompact' }
        'permissionrequest' { return 'PreToolUse' }
        'notification' { return 'Stop' }
        'stop' { return 'Stop' }
        default { return $Name }
    }
}

function Get-Value {
    param(
        [Parameter(Mandatory = $true)]
        $Object,
        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }

    return $null
}

function ConvertTo-CanonicalJson {
    param(
        [Parameter(Mandatory = $true)]
        $Value
    )

    return ($Value | ConvertTo-Json -Depth 50 -Compress)
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
}

function Get-IsoTimestamp {
    param(
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }

        return $text
    }

    $milliseconds = [double]$Value
    $epoch = [DateTimeOffset]::FromUnixTimeMilliseconds([long][Math]::Round($milliseconds))
    return $epoch.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function Get-MonthlyDataFilePath {
    param(
        [string]$ExplicitPath,
        [Parameter(Mandatory = $true)]
        [string]$DefaultDirectory,
        $Payload
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return $ExplicitPath
    }

    $timestamp = Get-IsoTimestamp (Get-Value -Object $Payload -Names @('timestamp'))
    if (-not [string]::IsNullOrWhiteSpace($timestamp) -and $timestamp.Length -ge 7) {
        $year = $timestamp.Substring(0, 4)
        $month = $timestamp.Substring(5, 2)
    }
    else {
        $now = [DateTime]::UtcNow
        $year = $now.ToString('yyyy')
        $month = $now.ToString('MM')
    }

    return (Join-Path $DefaultDirectory ("copilot_usage_{0}_{1}.json" -f $month, $year))
}

function Get-TextLength {
    param($Value)

    if ($null -eq $Value) {
        return 0
    }

    return ([string]$Value).Length
}

function Get-WordCount {
    param($Value)

    if ($null -eq $Value) {
        return 0
    }

    $wordMatches = [regex]::Matches([string]$Value, '\S+')
    return $wordMatches.Count
}

function Get-SerializedLength {
    param($Value)

    if ($null -eq $Value) {
        return 0
    }

    return (ConvertTo-CanonicalJson -Value $Value).Length
}

function Get-ToolCategory {
    param(
        [string]$ToolName
    )

    switch ($ToolName) {
        'ask_user' { return 'interaction' }
        'bash' { return 'execute' }
        'powershell' { return 'execute' }
        'create' { return 'write' }
        'edit' { return 'write' }
        'str_replace_editor' { return 'write' }
        'apply_patch' { return 'write' }
        'glob' { return 'discovery' }
        'grep' { return 'discovery' }
        'rg' { return 'discovery' }
        'task' { return 'subagent' }
        'view' { return 'read' }
        'web_fetch' { return 'network' }
        'web_search' { return 'network' }
        default { return 'other' }
    }
}

function Get-EventMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Payload
    )

    $metadata = [ordered]@{}

    switch ($Name) {
        'SessionStart' {
            $initialPrompt = Get-Value -Object $Payload -Names @('initialPrompt', 'initial_prompt')
            $metadata.source = (Get-Value -Object $Payload -Names @('source'))
            if ([string]::IsNullOrWhiteSpace([string]$metadata.source)) { $metadata.source = 'unknown' }
            $metadata.hasInitialPrompt = [bool]$initialPrompt
            $metadata.initialPromptLength = Get-TextLength $initialPrompt
            $metadata.initialPromptWordCount = Get-WordCount $initialPrompt
            $metadata.initialPromptHash = if ($initialPrompt) { Get-Sha256 ([string]$initialPrompt) } else { $null }
        }
        'Stop' {
            $metadata.stopReason = Get-Value -Object $Payload -Names @('stopReason', 'stop_reason', 'reason')
            if ([string]::IsNullOrWhiteSpace([string]$metadata.stopReason)) { $metadata.stopReason = 'unknown' }
        }
        'UserPromptSubmit' {
            $prompt = Get-Value -Object $Payload -Names @('prompt')
            $metadata.promptLength = Get-TextLength $prompt
            $metadata.promptWordCount = Get-WordCount $prompt
            $metadata.promptHash = if ($prompt) { Get-Sha256 ([string]$prompt) } else { $null }
        }
        { $_ -in @('PreToolUse', 'PostToolUse') } {
            $toolName = Get-Value -Object $Payload -Names @('toolName', 'tool_name')
            if ([string]::IsNullOrWhiteSpace([string]$toolName)) { $toolName = 'unknown' }
            $toolArgs = Get-Value -Object $Payload -Names @('toolArgs', 'tool_input')
            $metadata.toolName = $toolName
            $metadata.toolCategory = Get-ToolCategory -ToolName ([string]$toolName)
            $metadata.toolArgsLength = Get-SerializedLength $toolArgs
            $metadata.toolArgsHash = if ($null -ne $toolArgs) { Get-Sha256 (ConvertTo-CanonicalJson -Value $toolArgs) } else { $null }
            if ($Name -eq 'PostToolUse') {
                $toolResult = Get-Value -Object $Payload -Names @('toolResult', 'tool_result')
                $llmText = Get-Value -Object $toolResult -Names @('textResultForLlm', 'text_result_for_llm')
                $metadata.toolOutcome = 'success'
                $metadata.toolResultLength = Get-TextLength $llmText
                $metadata.toolResultHash = if ($llmText) { Get-Sha256 ([string]$llmText) } else { $null }
            }
        }
        'SubagentStart' {
            $transcriptPath = Get-Value -Object $Payload -Names @('transcriptPath', 'transcript_path')
            $description = Get-Value -Object $Payload -Names @('agentDescription', 'agent_description')
            $metadata.agentName = Get-Value -Object $Payload -Names @('agentName', 'agent_name')
            if ([string]::IsNullOrWhiteSpace([string]$metadata.agentName)) { $metadata.agentName = 'unknown' }
            $metadata.agentDisplayName = Get-Value -Object $Payload -Names @('agentDisplayName', 'agent_display_name')
            $metadata.transcriptPathHash = if ($transcriptPath) { Get-Sha256 ([string]$transcriptPath) } else { $null }
            $metadata.agentDescriptionLength = Get-TextLength $description
            $metadata.agentDescriptionHash = if ($description) { Get-Sha256 ([string]$description) } else { $null }
        }
        'SubagentStop' {
            $transcriptPath = Get-Value -Object $Payload -Names @('transcriptPath', 'transcript_path')
            $metadata.agentName = Get-Value -Object $Payload -Names @('agentName', 'agent_name')
            if ([string]::IsNullOrWhiteSpace([string]$metadata.agentName)) { $metadata.agentName = 'unknown' }
            $metadata.agentDisplayName = Get-Value -Object $Payload -Names @('agentDisplayName', 'agent_display_name')
            $metadata.transcriptPathHash = if ($transcriptPath) { Get-Sha256 ([string]$transcriptPath) } else { $null }
            $metadata.stopReason = Get-Value -Object $Payload -Names @('stopReason', 'stop_reason')
            if ([string]::IsNullOrWhiteSpace([string]$metadata.stopReason)) { $metadata.stopReason = 'unknown' }
        }
        'ErrorOccurred' {
            $errorRecord = Get-Value -Object $Payload -Names @('error')
            $message = Get-Value -Object $errorRecord -Names @('message')
            $metadata.errorName = Get-Value -Object $errorRecord -Names @('name')
            if ([string]::IsNullOrWhiteSpace([string]$metadata.errorName)) { $metadata.errorName = 'Error' }
            $metadata.errorContext = Get-Value -Object $Payload -Names @('errorContext', 'error_context')
            if ([string]::IsNullOrWhiteSpace([string]$metadata.errorContext)) { $metadata.errorContext = 'unknown' }
            $metadata.recoverable = [bool](Get-Value -Object $Payload -Names @('recoverable'))
            $metadata.errorMessageLength = Get-TextLength $message
            $metadata.errorMessageHash = if ($message) { Get-Sha256 ([string]$message) } else { $null }
            $metadata.hasStack = [bool](Get-Value -Object $errorRecord -Names @('stack'))
        }
        'PreCompact' {
            $transcriptPath = Get-Value -Object $Payload -Names @('transcriptPath', 'transcript_path')
            $instructions = Get-Value -Object $Payload -Names @('customInstructions', 'custom_instructions')
            $metadata.trigger = Get-Value -Object $Payload -Names @('trigger')
            if ([string]::IsNullOrWhiteSpace([string]$metadata.trigger)) { $metadata.trigger = 'unknown' }
            $metadata.transcriptPathHash = if ($transcriptPath) { Get-Sha256 ([string]$transcriptPath) } else { $null }
            $metadata.customInstructionsLength = Get-TextLength $instructions
            $metadata.customInstructionsHash = if ($instructions) { Get-Sha256 ([string]$instructions) } else { $null }
        }
    }

    return [pscustomobject]$metadata
}

function Get-EmptyStore {
    return @{
        version = 1
        updatedAt = $null
        summary = @{
            totalEvents = 0
            totalSessions = 0
            firstEventAt = $null
            lastEventAt = $null
            eventTypeCounts = @{}
            months = @()
        }
        events = @()
    }
}

function Get-Store {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            return ($raw | ConvertFrom-Json)
        }
    }

    return Get-EmptyStore
}

function Update-Summary {
    param(
        [Parameter(Mandatory = $true)]
        $Store
    )

    $eventTypeCounts = @{}
    $sessions = New-Object 'System.Collections.Generic.HashSet[string]'
    $months = New-Object 'System.Collections.Generic.SortedSet[string]'
    $firstEventAt = $null
    $lastEventAt = $null

    foreach ($usageEvent in @($Store.events)) {
        $eventType = [string]$usageEvent.eventType
        if ([string]::IsNullOrWhiteSpace($eventType)) { $eventType = 'unknown' }
        if ($eventTypeCounts.ContainsKey($eventType)) {
            $eventTypeCounts[$eventType] = [int]$eventTypeCounts[$eventType] + 1
        }
        else {
            $eventTypeCounts[$eventType] = 1
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$usageEvent.sessionId)) {
            [void]$sessions.Add([string]$usageEvent.sessionId)
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$usageEvent.month)) {
            [void]$months.Add([string]$usageEvent.month)
        }

        $timestamp = [string]$usageEvent.timestamp
        if (-not [string]::IsNullOrWhiteSpace($timestamp)) {
            if ($null -eq $firstEventAt -or $timestamp -lt $firstEventAt) {
                $firstEventAt = $timestamp
            }

            if ($null -eq $lastEventAt -or $timestamp -gt $lastEventAt) {
                $lastEventAt = $timestamp
            }
        }
    }

    $Store.summary = @{
        totalEvents = @($Store.events).Count
        totalSessions = $sessions.Count
        firstEventAt = $firstEventAt
        lastEventAt = $lastEventAt
        eventTypeCounts = $eventTypeCounts
        months = @($months)
    }
}

function Write-Store {
    param(
        [Parameter(Mandatory = $true)]
        $Store,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $json = $Store | ConvertTo-Json -Depth 100
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Enter-Lock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath
    )

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ($true) {
        if (-not (Test-Path -LiteralPath $LockPath)) {
            try {
                New-Item -ItemType Directory -Path $LockPath -ErrorAction Stop | Out-Null
                return
            }
            catch {
            }
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Timed out waiting for collector lock at '$LockPath'."
        }

        Start-Sleep -Milliseconds 50
    }
}

function Exit-Lock {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LockPath
    )

    if (Test-Path -LiteralPath $LockPath) {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }
}

$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$copilotUsageRoot = Split-Path -Parent $scriptDirectory
$defaultDataDirectory = Join-Path $copilotUsageRoot 'data'
$dataFile = [Environment]::GetEnvironmentVariable('COPILOT_USAGE_DATA_FILE')

$EventName = Resolve-EventName -Name $EventName

$inputPayloadText = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($inputPayloadText)) {
    $inputPayloadText = '{}'
}

$payload = $inputPayloadText | ConvertFrom-Json
$dataFile = Get-MonthlyDataFilePath -ExplicitPath $dataFile -DefaultDirectory $defaultDataDirectory -Payload $payload
$dataDirectory = Split-Path -Parent $dataFile
if (-not (Test-Path -LiteralPath $dataDirectory)) {
    New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null
}

$lockPath = "$dataFile.lock"
$recordedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

Enter-Lock -LockPath $lockPath
try {
    $store = Get-Store -Path $dataFile
    $payloadCanonical = ConvertTo-CanonicalJson -Value $payload
    $fingerprint = Get-Sha256 "$EventName|$payloadCanonical"

    foreach ($existingEvent in @($store.events)) {
        if ([string]$existingEvent.sourceFingerprint -eq $fingerprint) {
            $store.updatedAt = $recordedAt
            Update-Summary -Store $store
            Write-Store -Store $store -Path $dataFile
            exit 0
        }
    }

    $sessionId = [string](Get-Value -Object $payload -Names @('sessionId', 'session_id'))
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'unknown' }
    $timestamp = Get-IsoTimestamp (Get-Value -Object $payload -Names @('timestamp'))
    $cwd = [string](Get-Value -Object $payload -Names @('cwd'))
    $cwdHash = if (-not [string]::IsNullOrWhiteSpace($cwd)) { Get-Sha256 $cwd } else { $null }
    $month = if ($timestamp) { $timestamp.Substring(0, 7) } else { $null }

    $sessionEventIndex = 1
    foreach ($existingEvent in @($store.events)) {
        if ([string]$existingEvent.sessionId -eq $sessionId) {
            $sessionEventIndex += 1
        }
    }

    $eventRecord = [ordered]@{
        id = Get-Sha256 "$fingerprint|$sessionEventIndex"
        schemaVersion = 1
        eventType = $EventName
        sessionId = $sessionId
        timestamp = $timestamp
        recordedAt = $recordedAt
        month = $month
        cwd = $cwd
        cwdHash = $cwdHash
        sourceSurface = 'vscode-chat'
        sessionEventIndex = $sessionEventIndex
        sourceFingerprint = $fingerprint
        metadata = Get-EventMetadata -Name $EventName -Payload $payload
    }

    $store.events = @($store.events) + @($eventRecord)
    $store.updatedAt = $recordedAt
    Update-Summary -Store $store
    Write-Store -Store $store -Path $dataFile
}
finally {
    Exit-Lock -LockPath $lockPath
}
