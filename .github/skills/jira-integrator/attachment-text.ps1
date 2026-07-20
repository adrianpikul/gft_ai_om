[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string]$FileName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Json {
    param([Parameter(Mandatory = $true)]$Value)

    $Value | ConvertTo-Json -Depth 20 -Compress
}

function Get-PlainText {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Get-EmailText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $content = Get-PlainText -Path $Path
    $sections = [regex]::Split($content, "\r?\n\r?\n", 2)
    if ($sections.Count -lt 2) {
        return $content
    }

    $headers = $sections[0]
    $body = $sections[1]
    $subjectMatch = [regex]::Match($headers, '(?im)^Subject:\s*(?<subject>.+)$')
    if ($subjectMatch.Success) {
        return "Subject: $($subjectMatch.Groups['subject'].Value.Trim())`n`n$body"
    }

    return $body
}

$nameForExtension = if ([string]::IsNullOrWhiteSpace($FileName)) { $FilePath } else { $FileName }
$extension = [System.IO.Path]::GetExtension($nameForExtension).ToLowerInvariant()

try {
    switch ($extension) {
        '.json' { $text = Get-PlainText -Path $FilePath }
        '.csv' { $text = Get-PlainText -Path $FilePath }
        '.log' { $text = Get-PlainText -Path $FilePath }
        '.txt' { $text = Get-PlainText -Path $FilePath }
        '.eml' { $text = Get-EmailText -Path $FilePath }
        '.msg' {
            Write-Json @{ status = 'unsupported'; text = $null; error = 'MSG extraction requires a parser that is not bundled with this skill.' }
            exit 0
        }
        default {
            Write-Json @{ status = 'unsupported'; text = $null; error = "Unsupported attachment extension '$extension'." }
            exit 0
        }
    }

    Write-Json @{ status = 'extracted'; text = $text; error = $null }
}
catch {
    Write-Json @{ status = 'error'; text = $null; error = "Attachment text extraction failed: $($_.Exception.Message)" }
}
