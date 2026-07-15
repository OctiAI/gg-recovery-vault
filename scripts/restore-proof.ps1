[CmdletBinding()]
param(
  [switch]$SimulateFailure,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Invoke-Docker {
  param([string[]]$Arguments)
  & docker @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Docker command failed with exit code $LASTEXITCODE."
  }
}

function Set-RestoreAlert {
  param([bool]$Failed, [string]$Detail)

  $title = 'GoalsGraph restore proof failure'
  $existing = & gh issue list --repo OctiAI/gg-recovery-vault --state open --search "is:issue in:title $title" --json number --jq '.[0].number // empty'
  if ($LASTEXITCODE -ne 0) { return }

  if ($Failed -and -not $existing) {
    & gh issue create --repo OctiAI/gg-recovery-vault --title $title --body "The scheduled isolated restore proof failed. $Detail"
  } elseif (-not $Failed -and $existing) {
    & gh issue close $existing --repo OctiAI/gg-recovery-vault --comment 'A subsequent isolated restore proof succeeded.'
  }
}

$vaultRoot = Split-Path -Parent $PSScriptRoot
$identityPath = Join-Path $env:USERPROFILE '.secrets\goalsgraph-recovery\age.key'
$receiptDirectory = Join-Path $env:LOCALAPPDATA 'GoalsGraph\recovery-proof'
$receiptPath = Join-Path $receiptDirectory 'last-success.json'
$network = "goalsgraph-restore-proof-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$databaseContainer = "goalsgraph-restore-proof-db-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$databasePassword = 'ephemeral-restore-proof-password'
$networkCreated = $false
$databaseCreated = $false

try {
  if ($SimulateFailure) { throw 'Controlled restore-proof failure.' }
  if (-not (Test-Path -LiteralPath $identityPath)) { throw 'The local age identity is unavailable.' }

  if (-not $Force -and (Test-Path -LiteralPath $receiptPath)) {
    $lastSuccess = (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).completed_at
    if ([DateTime]::Parse($lastSuccess).ToUniversalTime() -gt [DateTime]::UtcNow.AddDays(-28)) {
      Write-Output "RESTORE_PROOF_NOT_DUE last_success=$lastSuccess"
      return
    }
  }

  & git -C $vaultRoot pull --ff-only
  if ($LASTEXITCODE -ne 0) { throw 'Could not refresh the off-host vault.' }

  $dump = Get-ChildItem -LiteralPath (Join-Path $vaultRoot 'backups\hourly') -Filter '*.dump.age' |
    Sort-Object Name -Descending |
    Select-Object -First 1
  if (-not $dump -or $dump.Name -notmatch '^\d{8}T\d{6}Z\.dump\.age$') {
    throw 'No valid off-host encrypted dump is available.'
  }

  Invoke-Docker @('build', '-t', 'goalsgraph-restore-proof', '-f', (Join-Path $vaultRoot 'Dockerfile.restore'), $vaultRoot)
  Invoke-Docker @('network', 'create', $network)
  $networkCreated = $true
  Invoke-Docker @('run', '-d', '--rm', '--name', $databaseContainer, '--network', $network, '--network-alias', 'restore-db', '-e', 'POSTGRES_DB=restoreproof', '-e', 'POSTGRES_USER=restoreproof', "-e", "POSTGRES_PASSWORD=$databasePassword", 'postgres:17-alpine')
  $databaseCreated = $true

  $ready = $false
  for ($attempt = 0; $attempt -lt 30; $attempt++) {
    $readiness = & docker exec $databaseContainer pg_isready -U restoreproof -d restoreproof 2>$null
    if ($LASTEXITCODE -eq 0 -and $readiness -match 'accepting connections') {
      $ready = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $ready) { throw 'The disposable restore database did not become ready.' }

  $vaultDumpPath = "/vault/backups/hourly/$($dump.Name)"
  $tocEntries = Invoke-Docker @('run', '--rm', '--mount', "type=bind,source=$(Split-Path -Parent $identityPath),target=/keys,readonly", '--mount', "type=bind,source=$vaultRoot,target=/vault,readonly", '--entrypoint', '/bin/sh', 'goalsgraph-restore-proof', '-ec', "age -d -i /keys/age.key $vaultDumpPath | pg_restore --list | wc -l")
  Invoke-Docker @('run', '--rm', '--network', $network, '-e', "PGPASSWORD=$databasePassword", '--mount', "type=bind,source=$(Split-Path -Parent $identityPath),target=/keys,readonly", '--mount', "type=bind,source=$vaultRoot,target=/vault,readonly", '--entrypoint', '/bin/sh', 'goalsgraph-restore-proof', '-ec', "age -d -i /keys/age.key $vaultDumpPath | pg_restore --exit-on-error --no-owner --no-privileges -h restore-db -U restoreproof -d restoreproof")
  $tableCount = & docker exec $databaseContainer psql -U restoreproof -d restoreproof -Atc "select count(*) from pg_catalog.pg_tables where schemaname = 'public'"
  if ($LASTEXITCODE -ne 0 -or [int]$tocEntries -le 0 -or [int]$tableCount -le 0) {
    throw 'The restore produced no readable PostgreSQL archive or public schema.'
  }

  New-Item -ItemType Directory -Force -Path $receiptDirectory | Out-Null
  [IO.File]::WriteAllText(
    $receiptPath,
    (@{ completed_at = [DateTime]::UtcNow.ToString('o'); dump = $dump.Name; toc_entries = [int]$tocEntries; public_tables = [int]$tableCount } | ConvertTo-Json -Compress) + [Environment]::NewLine,
    [Text.UTF8Encoding]::new($false)
  )
  Set-RestoreAlert -Failed $false -Detail ''
  Write-Output "RESTORE_PROOF_OK dump=$($dump.Name) toc_entries=$tocEntries public_tables=$tableCount"
} catch {
  Set-RestoreAlert -Failed $true -Detail $_.Exception.Message
  throw
} finally {
  if ($databaseCreated) { & docker rm -f $databaseContainer 2>$null | Out-Null }
  if ($networkCreated) { & docker network rm $network 2>$null | Out-Null }
}
