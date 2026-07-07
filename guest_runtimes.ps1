<#
guest_runtimes.ps1 - Install common Windows runtimes and apps on the CAPE
sandbox VM to mimic a normal user workstation.

Sections are independent: if one install fails the rest still run.

Order of installs (heavy -> light):
  1. .NET Framework 4.8              (modifies OS, reboot needed)
  2. .NET Desktop + Runtime          (x86 + x64, single LTS version)
  3. Visual C++ 2015-2022            (x86 + x64, critical for native PE)
  4. Java JRE                        (single LTS version, Adoptium Temurin)
  5. Node.js LTS                     (winget)
  6. WPS Office                      (free, Office-file inspection)
  7. Apps: 7-Zip, Notepad++, VLC, SumatraPDF
  8. Browsers: Chrome, Firefox

Each section can be disabled in the $Config block below.

Run AFTER sandbox_config.ps1, BEFORE taking the snapshot:
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine
    .\guest_runtimes.ps1
#Requires -RunAsAdministrator
#>

# =============================================================================
# Config - flip any of these to $false to skip a whole section
# =============================================================================
$Config = @{
    InstallDotNetFx   = $true    # .NET Framework 4.8 (offline installer)
    InstallDotNet     = $true    # .NET Desktop + Runtime (x86 + x64). Single LTS version.
    InstallVC         = $true    # VC++ 2015-2022 Redistributable (x86 + x64)
    InstallJava       = $true    # Java JRE - single LTS version (Adoptium Temurin)
    InstallNodeJS     = $true    # Node.js LTS (winget)
    InstallWPS        = $true    # WPS Office - for inspecting .doc/.xls/.ppt files
    InstallApps       = $true    # 7-Zip, Notepad++, VLC, SumatraPDF
    InstallBrowsers   = $true    # Chrome, Firefox

    # Single LTS version each. Change the number to pick a different one.
    DotNetVersion     = "9.0"    # .NET version (Desktop + Runtime). e.g. "8.0", "9.0"
    JavaVersion       = 21       # Java LTS major. e.g. 8, 17, 21

    LogFile           = "C:\GuestRuntimesSetup.log"
    TempDir           = "$env:TEMP\guest_runtimes"
}

# Continue past single failures (one bad installer shouldn't kill the rest).
$ErrorActionPreference = "Continue"

# =============================================================================
# Logging
# =============================================================================
$logDir = Split-Path $Config.LogFile -Parent
if ($logDir -and -not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}
try {
    Start-Transcript -Path $Config.LogFile -Append -ErrorAction Stop
} catch {
    Write-Warning "Could not start transcript: $_"
}

$Script:Installed = @()
$Script:Failed    = @()

function Write-Step {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Mark-OK {
    param($Name)
    $Script:Installed += $Name
    Write-Host "  [OK]  $Name" -ForegroundColor Green
}
function Mark-Fail {
    param($Name, $Err = "")
    if ($Err) { $line = "$Name - $Err" } else { $line = $Name }
    $Script:Failed += $line
    Write-Host "  [FAIL] $line" -ForegroundColor Red
}

# =============================================================================
# Helpers
# =============================================================================

# Download a file once into the temp dir. Returns the local path or $null.
function Get-Installer {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$LocalName
    )
    New-Item -ItemType Directory -Force -Path $Config.TempDir | Out-Null
    $local = Join-Path $Config.TempDir $LocalName
    if (Test-Path $local) {
        Write-Host "  cached -> $local"
        return $local
    }
    try {
        Write-Host "  downloading $Url"
        Invoke-WebRequest -Uri $Url -OutFile $local -UseBasicParsing -ErrorAction Stop
        return $local
    } catch {
        Mark-Fail "download $LocalName" $_.Exception.Message
        return $null
    }
}

# Run an EXE installer silently. Some installers return 3010 = "reboot
# required" - treat that as success.
function Invoke-SilentInstall {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [string]$Arguments = "/quiet /norestart",
        [int]$TimeoutSec   = 600
    )
    $proc = Start-Process -FilePath $ExePath -ArgumentList $Arguments -Wait -PassThru `
        -ErrorAction Continue
    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        return $true
    }
    throw "exit code $($proc.ExitCode)"
}

# winget wrapper: silent, accept agreements, idempotent (skips if installed).
function Install-Winget {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$ExtraArgs = @()
    )
    try {
        # Skip if already present.
        $existing = winget list --id $Id --accept-source-agreements 2>$null
        $idPattern = "^" + [regex]::Escape($Id) + "\s"
        if ($LASTEXITCODE -eq 0 -and ($existing -split "`n") -match $idPattern) {
            Mark-OK "$Name (already installed)"
            return
        }
        Write-Host "  winget install $Id"
        $args = @("install", "--id", $Id, "--silent",
                  "--accept-package-agreements", "--accept-source-agreements") + $ExtraArgs
        $proc = Start-Process -FilePath "winget" -ArgumentList $args -Wait -PassThru `
            -RedirectStandardOutput "$env:TEMP\winget_$Id.out.txt" `
            -RedirectStandardError  "$env:TEMP\winget_$Id.err.txt" `
            -ErrorAction Stop
        if ($proc.ExitCode -eq 0) { Mark-OK $Name }
        else { Mark-Fail $Name "winget exit $($proc.ExitCode)" }
    } catch {
        Mark-Fail $Name $_.Exception.Message
    }
}

# =============================================================================
# 1. .NET Framework 4.8 (offline web installer)
# =============================================================================
if ($Config.InstallDotNetFx) {
    Write-Step "1/8  .NET Framework 4.8"
    try {
        $exe = Get-Installer -Url "https://go.microsoft.com/fwlink/?linkid=2088631" `
                             -LocalName "ndp48-web.exe"
        if ($exe) {
            Invoke-SilentInstall -ExePath $exe -Arguments "/q /norestart" | Out-Null
            Mark-OK ".NET Framework 4.8"
        }
    } catch {
        $msg = if ($_.Exception) { $_.Exception.Message } else { "$_" }
        Mark-Fail ".NET Framework 4.8" $msg
    }
}

# =============================================================================
# 2. .NET Desktop + Runtime (x86 + x64) - single LTS version
# =============================================================================
if ($Config.InstallDotNet) {
    $v = $Config.DotNetVersion
    Write-Step "2/8  .NET $v Desktop + Runtime"
    $jobs = @(
        @{ Url = "https://aka.ms/dotnet/$v/windowsdesktop-runtime-win-x64.exe"; Name = ".NET $v Desktop x64" },
        @{ Url = "https://aka.ms/dotnet/$v/windowsdesktop-runtime-win-x86.exe"; Name = ".NET $v Desktop x86" },
        @{ Url = "https://aka.ms/dotnet/$v/dotnet-runtime-win-x64.exe";           Name = ".NET $v Runtime x64" },
        @{ Url = "https://aka.ms/dotnet/$v/dotnet-runtime-win-x86.exe";           Name = ".NET $v Runtime x86" }
    )
    foreach ($j in $jobs) {
        try {
            $exe = Get-Installer -Url $j.Url -LocalName (($j.Name -replace '[\s\.]','_') + ".exe")
            if (-not $exe) { continue }
            Invoke-SilentInstall -ExePath $exe | Out-Null
            Mark-OK $j.Name
        } catch {
            $msg = if ($_.Exception) { $_.Exception.Message } else { "$_" }
            Mark-Fail $j.Name $msg
        }
    }
}

# =============================================================================
# 3. Visual C++ 2015-2022 Redistributable (x86 + x64)
# =============================================================================
if ($Config.InstallVC) {
    Write-Step "3/8  Visual C++ 2015-2022"
    foreach ($vc in @(
        @{ Url = "https://aka.ms/vs/17/release/vc_redist.x64.exe"; Name = "VC++ 2015-2022 x64" },
        @{ Url = "https://aka.ms/vs/17/release/vc_redist.x86.exe"; Name = "VC++ 2015-2022 x86" }
    )) {
        try {
            $exe = Get-Installer -Url $vc.Url -LocalName ("vc_redist_" + ($vc.Name -replace '[^a-z0-9]','_') + ".exe")
            if (-not $exe) { continue }
            Invoke-SilentInstall -ExePath $exe | Out-Null
            Mark-OK $vc.Name
        } catch {
            $msg = if ($_.Exception) { $_.Exception.Message } else { "$_" }
            Mark-Fail $vc.Name $msg
        }
    }
}

# =============================================================================
# 4. Java JRE (Adoptium Temurin) - single LTS version
# =============================================================================
if ($Config.InstallJava) {
    $major = $Config.JavaVersion
    Write-Step "4/8  Java JRE (Adoptium Temurin $major)"
    try {
        # Adoptium's API returns an MSI; rename for clarity.
        $url    = "https://api.adoptium.net/v3/binary/latest/${major}/ga/windows/x64/jre/hotspot/normal/eclipse?project=jdk"
        $dlName = "temurin-${major}-jre-x64.msi"
        $msi    = Get-Installer -Url $url -LocalName $dlName
        if ($msi) {
            Write-Host "  installing Temurin $major JRE"
            $proc = Start-Process -FilePath "msiexec.exe" `
                -ArgumentList "/i `"$msi`" /qn /norestart" `
                -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) { Mark-OK "Temurin $major JRE" }
            else { Mark-Fail "Temurin $major JRE" "msiexec exit $($proc.ExitCode)" }
        }
    } catch {
        $msg = if ($_.Exception) { $_.Exception.Message } else { "$_" }
        Mark-Fail "Temurin $major JRE" $msg
    }
}

# =============================================================================
# 5. Node.js LTS
# =============================================================================
if ($Config.InstallNodeJS) {
    Write-Step "5/8  Node.js LTS"
    Install-Winget -Id "OpenJS.NodeJS.LTS" -Name "Node.js LTS"
}

# =============================================================================
# 6. WPS Office (free) - for inspecting .doc/.docx/.xls/.xlsx/.ppt/.pptx
# =============================================================================
if ($Config.InstallWPS) {
    Write-Step "6/8  WPS Office (free international)"
    # Try winget first (id may be "WPS.Office" or "Kingsoft.WPSOffice" depending
    # on source repo). Fall back to a direct download if both fail.
    $wpsInstalled = $false

    # Attempt 1: WPS.Office
    try {
        $existing = winget list --id "WPS.Office" --accept-source-agreements 2>$null
        if ($LASTEXITCODE -eq 0 -and ($existing -split "`n") -match "^WPS\.Office\s") {
            Mark-OK "WPS Office (already installed)"
            $wpsInstalled = $true
        } else {
            Write-Host "  winget install WPS.Office"
            $proc = Start-Process -FilePath "winget" `
                -ArgumentList @("install","--id","WPS.Office","--silent",
                                "--accept-package-agreements","--accept-source-agreements") `
                -Wait -PassThru -ErrorAction Stop
            if ($proc.ExitCode -eq 0) { Mark-OK "WPS Office"; $wpsInstalled = $true }
        }
    } catch {
        Write-Host "  winget attempt for WPS Office failed: $_" -ForegroundColor Yellow
    }

    # Attempt 2: direct MSI/EXE download if winget failed.
    if (-not $wpsInstalled) {
        try {
            # WPS's CDN URL changes per version. This is the latest stable as of 2025-06;
            # if 404 just edit the line below.
            $wpsUrl = "https://wdl1.pcfg.cache.wpscdn.com/wpsdl/wpsoffices/download/free/12110.12009/WPSOffice_12110.12009.exe"
            $exe = Get-Installer -Url $wpsUrl -LocalName "WPSOffice_setup.exe"
            if ($exe) {
                Write-Host "  installing WPS Office (silent)"
                # WPS uses NSIS; /S means fully silent.
                $proc = Start-Process -FilePath $exe -ArgumentList "/S" -Wait -PassThru -ErrorAction Stop
                if ($proc.ExitCode -eq 0) { Mark-OK "WPS Office" }
                else { Mark-Fail "WPS Office" "nsis exit $($proc.ExitCode)" }
            }
        } catch {
            $msg = if ($_.Exception) { $_.Exception.Message } else { "$_" }
            Mark-Fail "WPS Office" "$msg - try 'winget install WPS.Office' manually"
        }
    }
}

# =============================================================================
# 7. Apps: 7-Zip, Notepad++, VLC, SumatraPDF
# =============================================================================
if ($Config.InstallApps) {
    Write-Step "7/8  Apps (7-Zip, Notepad++, VLC, SumatraPDF)"
    Install-Winget -Id "7zip.7zip"           -Name "7-Zip"
    Install-Winget -Id "Notepad++.Notepad++"  -Name "Notepad++"
    Install-Winget -Id "VideoLAN.VLC"        -Name "VLC media player"
    Install-Winget -Id "SumatraPDF.SumatraPDF" -Name "SumatraPDF"
}

# =============================================================================
# 8. Browsers: Chrome, Firefox
# =============================================================================
if ($Config.InstallBrowsers) {
    Write-Step "8/8  Browsers (Chrome, Firefox)"
    Install-Winget -Id "Google.Chrome" -Name "Google Chrome"
    Install-Winget -Id "Mozilla.Firefox" -Name "Mozilla Firefox"
}

# =============================================================================
# Summary
# =============================================================================
Write-Step "Summary"
Write-Host ("Installed: {0}" -f $Script:Installed.Count) -ForegroundColor Green
$Script:Installed | ForEach-Object { Write-Host "  [OK] $_" -ForegroundColor Green }
if ($Script:Failed.Count -gt 0) {
    Write-Host ""
    Write-Host ("Failed:    {0}" -f $Script:Failed.Count) -ForegroundColor Red
    $Script:Failed | ForEach-Object { Write-Host "  [FAIL] $_" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Check the log for details: $($Config.LogFile)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Open each app once so it lays down its first-run registry/state."
Write-Host "  2. Open WPS and confirm it registers .doc/.docx/.xls/.xlsx/.ppt/.pptx."
Write-Host "  3. Visit any login pages you want cached (Gmail, etc.)."
Write-Host "  4. Shut down the VM and take the snapshot."

try { Stop-Transcript | Out-Null } catch { }