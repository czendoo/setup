param(
    [switch]$UseEmptyArray,
    [string]$PreferencesPath
)

$ErrorActionPreference = "Stop"

Write-Host "Closing ChatGPT if it is running..."
Stop-Process -Name "ChatGPT" -Force -ErrorAction SilentlyContinue

if (-not $PreferencesPath) {
    $packagesRoot = Join-Path $env:LOCALAPPDATA "Packages"
    if (-not (Test-Path $packagesRoot)) {
        throw "Packages folder not found: $packagesRoot"
    }

    $package = Get-ChildItem $packagesRoot -Directory -Filter "OpenAI.ChatGPT-Desktop_*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $package) {
        throw "Could not find a folder matching OpenAI.ChatGPT-Desktop_* under $packagesRoot"
    }

    $PreferencesPath = Join-Path $package.FullName "LocalCache\Roaming\ChatGPT\Preferences"
}

if (-not (Test-Path $PreferencesPath)) {
    throw "Preferences file not found: $PreferencesPath"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = "$PreferencesPath.bak-$timestamp"
Copy-Item $PreferencesPath $backupPath -Force
Write-Host "Backup created: $backupPath"

$content = [System.IO.File]::ReadAllText($PreferencesPath)
$replacement = if ($UseEmptyArray) { '"dictionaries":[]' } else { '"dictionaries":[""]' }
$pattern = '"dictionaries"\s*:\s*\[[^\]]*\]'
$regex = [regex]$pattern

if ($regex.IsMatch($content)) {
    $updated = $regex.Replace($content, $replacement, 1)
} else {
    Write-Host "No dictionaries entry found. Adding spellcheck.dictionaries via JSON parser..."
    $json = $content | ConvertFrom-Json

    if (-not ($json.PSObject.Properties.Name -contains "spellcheck")) {
        $json | Add-Member -MemberType NoteProperty -Name spellcheck -Value ([pscustomobject]@{})
    }

    if ($UseEmptyArray) {
        $dictValue = @()
    } else {
        $dictValue = New-Object System.Collections.ArrayList
        [void]$dictValue.Add("")
    }

    $json.spellcheck | Add-Member -MemberType NoteProperty -Name dictionaries -Value $dictValue -Force
    $updated = $json | ConvertTo-Json -Depth 200 -Compress
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($PreferencesPath, $updated, $utf8NoBom)

Write-Host "Done. Reopen ChatGPT and test the input box."
Write-Host "Updated: $PreferencesPath"
