#Requires -Version 5.1
<#
.SYNOPSIS
    Publishes a Soverance game build to Steam via steamcmd.

.DESCRIPTION
    Reads a per-project JSON config from Scripts\Projects, generates the
    app_build / depot_build VDF files from templates, and invokes the
    vendored steamcmd.exe to upload (or preview-validate) the build.

    IMPORTANT: this file is ASCII-only. PowerShell 5.1 reads .ps1 files as
    Windows-1252 without a BOM, so em-dashes, smart quotes, or other
    non-ASCII characters will corrupt the parse. Keep edits ASCII.

.PARAMETER Project
    Name of the project config (without .json) under Scripts\Projects.

.PARAMETER Preview
    Sets Preview=1 in the app_build VDF. Steam validates the build but
    does not upload. Use this for the first run on a new project.

.PARAMETER SetLive
    Optional Steam beta branch name. If set, the build goes live on that
    branch immediately on success. Omit for no auto-go-live.
    'default' is refused: Steam does not let steamcmd set a build live on
    the default branch (the upload succeeds, then the commit fails with a
    bare 'Failure'). Upload to a beta branch or with no SetLive, then set
    it live on default in the Steamworks partner site (see the error text).

.PARAMETER Description
    Build description shown in the Steamworks UI. Defaults to the project
    config's Description field, with a timestamp appended.

.PARAMETER ContentRoot
    Override the project config's DefaultContentRoot. Must be an absolute
    path to the staged build output (e.g. a UE5 archivedirectory).

.PARAMETER User
    Steam account username. Falls back to env var STEAM_USER, then
    interactive prompt.

.EXAMPLE
    .\Publish-Steam.ps1 -Project Ethereal -Preview

    Validates the Ethereal build pipeline end to end without uploading.

.EXAMPLE
    .\Publish-Steam.ps1 -Project Ethereal -SetLive beta

    Uploads the build and sets it live on the 'beta' branch.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [switch]$Preview,

    [string]$SetLive = '',

    [string]$Description = '',

    [string]$ContentRoot = '',

    [string]$User = ''
)

$ErrorActionPreference = 'Stop'

# Resolve repo layout.
$ScriptRoot   = $PSScriptRoot
$RepoRoot     = (Resolve-Path (Join-Path $ScriptRoot '..')).Path
$SdkSteamCmd  = Join-Path $RepoRoot 'sdk\tools\ContentBuilder\builder\steamcmd.exe'
$TemplateDir  = Join-Path $ScriptRoot 'Templates'
$ProjectsDir  = Join-Path $ScriptRoot 'Projects'
$OutputDir    = Join-Path $RepoRoot 'Output'
$GeneratedDir = Join-Path $OutputDir 'Generated'
$LogDir       = Join-Path $RepoRoot 'Logs'

# Boundary validation.
$ProjectFile = Join-Path $ProjectsDir "$Project.json"
if (-not (Test-Path $ProjectFile)) {
    throw "Project config not found: $ProjectFile"
}
if (-not (Test-Path $SdkSteamCmd)) {
    throw "steamcmd.exe not found at $SdkSteamCmd. Confirm the SDK is extracted under sdk\."
}

# Load project config.
$Config = Get-Content $ProjectFile -Raw | ConvertFrom-Json
$AppId  = $Config.AppId
$Depots = $Config.Depots

# Steam refuses to set the default branch live from steamcmd: the depots upload, then the
# commit fails with a bare 'Failure' (exit 6). Stop before logging in, with the manual steps.
if ($SetLive -eq 'default') {
    throw @"
SetLive 'default' is not allowed: Steam does not let steamcmd set a build live on the
default branch (the upload succeeds, then the commit fails with 'Failure').
Do this instead:
  1. Upload to a beta branch, or with no SetLive at all:
       .\Publish-Steam.ps1 -Project $Project -SetLive playtest
  2. In the Steamworks partner site: App Admin > AppID $AppId > SteamPipe > Builds.
  3. Find the new build (its description ends with today's date and time).
  4. 'Set build live on branch...' > default > Preview Change > Set Build Live Now.
"@
}

$ResolvedContentRoot = if ($ContentRoot) { $ContentRoot } else { $Config.DefaultContentRoot }
if (-not (Test-Path $ResolvedContentRoot)) {
    throw "ContentRoot does not exist: $ResolvedContentRoot. Stage the build first."
}

$ResolvedDescription = if ($Description) {
    $Description
} else {
    "$($Config.Description) ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))"
}

# Prepare output dirs.
New-Item -ItemType Directory -Path $GeneratedDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$BuildOutput = Join-Path $OutputDir 'BuildCache'
New-Item -ItemType Directory -Path $BuildOutput -Force | Out-Null

# Credentials.
if (-not $User) { $User = $env:STEAM_USER }
if (-not $User) { $User = Read-Host 'Steam username' }

$SecurePass = $null
if ($env:STEAM_PASS) {
    $SecurePass = ConvertTo-SecureString $env:STEAM_PASS -AsPlainText -Force
} else {
    $SecurePass = Read-Host "Steam password for $User" -AsSecureString
}
$PlainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass)
)

# Render depot VDFs.
$DepotTmpl     = Get-Content (Join-Path $TemplateDir 'depot_build.vdf.tmpl') -Raw
$AppTmpl       = Get-Content (Join-Path $TemplateDir 'app_build.vdf.tmpl') -Raw
$DepotRefLines = New-Object System.Collections.Generic.List[string]

foreach ($Depot in $Depots) {
    $DepotId   = $Depot.Id
    $Mappings  = New-Object System.Collections.Generic.List[string]

    foreach ($M in $Depot.FileMappings) {
        $Rec = if ($M.Recursive) { '1' } else { '0' }
        $Mappings.Add(@"
    "FileMapping"
    {
        "LocalPath" "$($M.LocalPath)"
        "DepotPath" "$($M.DepotPath)"
        "Recursive" "$Rec"
    }
"@)
    }

    $DepotVdf = $DepotTmpl `
        -replace '\{\{DEPOT_ID\}\}', "$DepotId" `
        -replace '\{\{FILE_MAPPINGS\}\}', ($Mappings -join "`r`n")

    $DepotVdfPath = Join-Path $GeneratedDir "depot_build_$DepotId.vdf"
    Set-Content -Path $DepotVdfPath -Value $DepotVdf -Encoding ASCII
    $DepotRefLines.Add("        `"$DepotId`" `"depot_build_$DepotId.vdf`"")
}

# Render app VDF.
$PreviewFlag = if ($Preview) { '1' } else { '0' }
$SetLiveLine = if ($SetLive) { "    `"SetLive`" `"$SetLive`"" } else { '' }

$AppVdf = $AppTmpl `
    -replace '\{\{APP_ID\}\}', "$AppId" `
    -replace '\{\{DESCRIPTION\}\}', $ResolvedDescription `
    -replace '\{\{PREVIEW\}\}', $PreviewFlag `
    -replace '\{\{CONTENT_ROOT\}\}', ($ResolvedContentRoot -replace '\\', '\\') `
    -replace '\{\{BUILD_OUTPUT\}\}', ($BuildOutput -replace '\\', '\\') `
    -replace '\{\{SETLIVE_LINE\}\}', $SetLiveLine `
    -replace '\{\{DEPOT_REFERENCES\}\}', ($DepotRefLines -join "`r`n")

$AppVdfPath = Join-Path $GeneratedDir "app_build_$AppId.vdf"
Set-Content -Path $AppVdfPath -Value $AppVdf -Encoding ASCII

# Summary before invoking steamcmd.
Write-Host ''
Write-Host '== Steam build summary ==' -ForegroundColor Cyan
Write-Host "  Project       : $($Config.Name)"
Write-Host "  AppID         : $AppId"
Write-Host "  Depots        : $(($Depots | ForEach-Object { $_.Id }) -join ', ')"
Write-Host "  ContentRoot   : $ResolvedContentRoot"
Write-Host "  BuildOutput   : $BuildOutput"
Write-Host "  Description   : $ResolvedDescription"
Write-Host "  Preview       : $($Preview.IsPresent)"
if ($SetLive) { Write-Host "  SetLive       : $SetLive" }
Write-Host "  App VDF       : $AppVdfPath"
Write-Host "  steamcmd      : $SdkSteamCmd"
Write-Host ''

# Invoke steamcmd. Output streams to console so Steam Guard prompts work.
# Metadata log records the call; full output is the user's responsibility to
# capture via redirection if needed.
$Stamp   = Get-Date -Format 'yyyy-MM-dd-HHmmss'
$LogFile = Join-Path $LogDir "$Project-$Stamp.log"

$Header = @"
Soverance Steam publish log
Project     : $($Config.Name)
AppID       : $AppId
Preview     : $($Preview.IsPresent)
SetLive     : $SetLive
ContentRoot : $ResolvedContentRoot
AppVDF      : $AppVdfPath
Started     : $(Get-Date -Format 'o')
"@
Set-Content -Path $LogFile -Value $Header -Encoding ASCII

$Start = Get-Date
& $SdkSteamCmd `
    +login $User $PlainPass `
    +run_app_build $AppVdfPath `
    +quit
$Exit = $LASTEXITCODE
$Duration = (Get-Date) - $Start

# Scrub the plaintext password from memory.
$PlainPass = $null
[GC]::Collect()

Add-Content -Path $LogFile -Value ""
Add-Content -Path $LogFile -Value "Finished    : $(Get-Date -Format 'o')"
Add-Content -Path $LogFile -Value "Duration    : $($Duration.ToString())"
Add-Content -Path $LogFile -Value "ExitCode    : $Exit"

Write-Host ''
if ($Exit -eq 0) {
    Write-Host "steamcmd exited 0 in $($Duration.ToString('mm\:ss')). Log: $LogFile" -ForegroundColor Green
} else {
    Write-Host "steamcmd exited $Exit in $($Duration.ToString('mm\:ss')). Log: $LogFile" -ForegroundColor Red
}

exit $Exit
