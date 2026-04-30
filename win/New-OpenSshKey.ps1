param(
    [string]$KeyName,
    [string]$OutputDirectory = (Join-Path $HOME ".ssh"),
    [string]$Comment = "ssh-key",
    [switch]$NoPassphrase
)

# This script creates an OpenSSH client key pair for logging in to an SSH server.
# The private key is written in OpenSSH format in the standard ~/.ssh location.
# The public key can be uploaded to the target system.

if ([string]::IsNullOrWhiteSpace($KeyName)) {
    $KeyName = Read-Host "Enter a name for the SSH key"
}

if ([string]::IsNullOrWhiteSpace($KeyName)) {
    throw "A key name is required."
}

$sshKeygen = Get-Command ssh-keygen -ErrorAction SilentlyContinue
if (-not $sshKeygen) {
    throw "ssh-keygen was not found. Install OpenSSH Client and run the script again."
}

if (-not (Test-Path -Path $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$privateKeyPath = Join-Path $OutputDirectory $KeyName
$publicKeyPath = "$privateKeyPath.pub"

if ((Test-Path -Path $privateKeyPath) -or (Test-Path -Path $publicKeyPath)) {
    Write-Warning "Key files already exist at '$privateKeyPath'. Remove them or choose a different KeyName."
    return
}

$passphrase = if ($NoPassphrase) { "" } else { Read-Host "Enter a passphrase for the private key (leave empty for none)" -AsSecureString }
$plainPassphrase = if ($passphrase -is [System.Security.SecureString]) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($passphrase)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
} else {
    $passphrase
}

function ConvertTo-CommandLineArgument {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -eq "") {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escapedValue = $Value -replace '(\\*)"', '$1$1\"'
    $escapedValue = $escapedValue -replace '(\\+)$', '$1$1'
    return '"' + $escapedValue + '"'
}

# Generate an Ed25519 key pair in the default OpenSSH private key format.
$arguments = @(
    "-t", "ed25519",
    "-a", "100",
    "-C", $Comment,
    "-f", $privateKeyPath,
    "-N", $plainPassphrase
)

$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $sshKeygen.Source
$startInfo.Arguments = ($arguments | ForEach-Object { ConvertTo-CommandLineArgument -Value $_ }) -join ' '
$startInfo.UseShellExecute = $false

$process = [System.Diagnostics.Process]::Start($startInfo)
$process.WaitForExit()

if ($process.ExitCode -ne 0) {
    throw "ssh-keygen failed with exit code $($process.ExitCode)."
}

Write-Host "Private key: $privateKeyPath"
Write-Host "Public key:  $publicKeyPath"
Write-Host "Upload the public key to the target system and keep the private key secure."