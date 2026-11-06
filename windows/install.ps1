param(
    [switch] $Build = $true,
    [switch] $SkipService,
    [switch] $SkipTrayStartup
)

$ErrorActionPreference = "Stop"
$script:StepNumber = 0

function Write-Step([string] $Message) {
    $script:StepNumber += 1
    Write-Host ""
    Write-Host ("[{0}] {1}" -f $script:StepNumber, $Message)
}

function Write-Detail([string] $Message) {
    Write-Host ("    {0}" -f $Message)
}

function Write-ErrorLog([string] $Message) {
    Write-Host ("ERROR: {0}" -f $Message) -ForegroundColor Red
}

try {
    Write-Step "Setting PowerShell execution policy for this session"
    Write-Detail "Running: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force"
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    Write-Detail "Execution policy for this PowerShell session is ready."

    Write-Step "Starting Browser Time Tracker installer"
    $installer = Join-Path $PSScriptRoot "scripts\install-windows.ps1"
    Write-Detail "Installer script: $installer"

    $installerParameters = @{}
    if ($Build) {
        $installerParameters.Build = $true
    }
    if ($SkipService) {
        $installerParameters.SkipService = $true
    }
    if ($SkipTrayStartup) {
        $installerParameters.SkipTrayStartup = $true
    }

    Write-Detail ("Forwarding switches: Build={0}, SkipService={1}, SkipTrayStartup={2}" -f [bool]$Build, [bool]$SkipService, [bool]$SkipTrayStartup)
    & $installer @installerParameters
} catch {
    Write-ErrorLog "Bootstrap installer failed at step $script:StepNumber."
    Write-ErrorLog $_.Exception.Message
    if ($_.InvocationInfo) {
        Write-ErrorLog ("Location: {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber)
        Write-ErrorLog ("Command: {0}" -f $_.InvocationInfo.Line.Trim())
    }
    throw
}
