param(
    [string]$PreferencesPath,
    [string]$BackupPath
)

$ErrorActionPreference = "Stop"

Write-Host "Closing ChatGPT if it is running..."
Stop-Process -Name "ChatGPT" -Force -ErrorAction SilentlyContinue

if (-not $PreferencesPath) {
    $packagesRoot = Join-Path $env:LOCALAPPDATA "Packages"
    $package = Get-ChildItem $packagesRoot -Directory -Filter "OpenAI.ChatGPT-Desktop_*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $package) {
        throw "Could not find a folder matching OpenAI.ChatGPT-Desktop_* under $packagesRoot"
    }

    $PreferencesPath = Join-Path $package.FullName "LocalCache\Roaming\ChatGPT\Preferences"
}

if (-not $BackupPath) {
    $BackupPath = Get-ChildItem "$PreferencesPath.bak-*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $BackupPath) {
    throw "No backup found for: $PreferencesPath"
}

if (-not (Test-Path $BackupPath)) {
    throw "Backup file not found: $BackupPath"
}

Copy-Item $BackupPath $PreferencesPath -Force
Write-Host "Restored backup: $BackupPath"
Write-Host "Reopen ChatGPT."
