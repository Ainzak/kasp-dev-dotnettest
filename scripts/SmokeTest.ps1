param([string]$BaseUrl = 'http://localhost:5080')

$ErrorActionPreference = 'Stop'

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-Scan([string]$Name) {
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/scans" -ContentType 'application/json' `
        -Body (@{ repositoryUrl = "https://example.com/$Name" } | ConvertTo-Json)
}

function Get-Scan([string]$Id) {
    Invoke-RestMethod -Uri "$BaseUrl/api/scans/$Id"
}

function Wait-State([string]$Id, [string]$Expected) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    do {
        $snapshot = Get-Scan $Id
        if ($snapshot.status -eq $Expected) { return $snapshot }
        if ($snapshot.status -in @('Completed', 'Failed', 'Cancelled')) {
            throw "Unexpected terminal state $($snapshot.status), expected $Expected."
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Expected."
}

# Uses the default concurrency limit of two on a fresh instance.
$vulnerability = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/vulnerabilities" `
    -ContentType 'application/json' -Body '{"name":"Smoke test issue","severity":"High"}'
$stored = Invoke-RestMethod -Uri "$BaseUrl/api/vulnerabilities/$($vulnerability.id)"
Assert-Condition ($stored.id -eq $vulnerability.id) 'Vulnerability lookup failed.'

$first = New-Scan 'first'
$second = New-Scan 'second'
$null = Wait-State $first.id 'Running'
$null = Wait-State $second.id 'Running'
$third = New-Scan 'third'
$fourth = New-Scan 'fourth'
Assert-Condition ((Get-Scan $third.id).status -eq 'Queued') 'Third scan should be queued.'
Assert-Condition ((Get-Scan $fourth.id).status -eq 'Queued') 'Fourth scan should be queued.'

$cancelQueued = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/scans/$($fourth.id)/cancel"
$cancelRunning = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/scans/$($first.id)/cancel"
Assert-Condition ($cancelQueued.success -and $cancelRunning.success) 'Cancellation failed.'
$null = Wait-State $third.id 'Running'
$completed = Wait-State $third.id 'Completed'
$null = Wait-State $second.id 'Completed'
Assert-Condition ($completed.result.isDemonstration -and $completed.result.findings.Count -eq 2) 'Invalid demo result.'
Assert-Condition ((Get-Scan $first.id).status -eq 'Cancelled') 'Running cancellation was lost.'
Assert-Condition ((Get-Scan $fourth.id).status -eq 'Cancelled') 'Queued cancellation was lost.'
$repeat = Invoke-RestMethod -Method Post -Uri "$BaseUrl/api/scans/$($first.id)/cancel"
Assert-Condition (-not $repeat.success) 'Repeated cancellation must return success=false.'

Write-Output 'Smoke test passed: creation, concurrency limit, queue, cancellation and demo results.'
