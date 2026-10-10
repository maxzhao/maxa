# Run with Windows PowerShell; temporary fixture only, no Syncthing/config access.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/windows_vault_path.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('maxa-vault-identity-' + [guid]::NewGuid().ToString('N'))
$target = Join-Path $root 'target space'
$other = Join-Path $root 'other'
$link = Join-Path $root 'junction'
try {
    New-Item -ItemType Directory -Path $target, $other | Out-Null
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    if (-not (Test-SameVaultDirectory $target $target)) { throw 'same target rejected' }
    if (-not (Test-SameVaultDirectory $target $link)) { throw 'junction equality rejected' }
    if (-not (Test-SameVaultDirectory $target (Join-Path $other '../target space'))) { throw 'normalized spelling rejected' }
    if (Test-SameVaultDirectory $target $other) { throw 'foreign directory accepted' }
    $denied = $false
    try { Test-SameVaultDirectory $target (Join-Path $root 'missing') | Out-Null } catch { $denied = $true }
    if (-not $denied) { throw 'missing directory did not fail closed' }
    Write-Output 'PASS: Windows handle identity same/junction/normalized/foreign/missing cases'
} finally {
    if (Test-Path -LiteralPath $link) { [IO.Directory]::Delete($link) }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
