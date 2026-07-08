# clean_python.ps1 - Remove wedged / orphaned Python 3.10 installs from a
# Windows sandbox guest and (optionally) reinstall cleanly to C:\Python310.
#
# Handles the state you hit: files deleted by -Purge but MSI registration left
# behind, per-user AND all-users registrations coexisting, and uninstall failing
# with 0x80070643 / 1603 (made worse by VSS being disabled).
#
# Run in an ELEVATED PowerShell in the guest:
#     Set-ExecutionPolicy Bypass -Scope Process -Force
#     .\clean_python.ps1              # clean only
#     .\clean_python.ps1 -Reinstall   # clean, then install Python 3.10.11 + Pillow
#
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Reinstall,
    [string]$TargetDir = "C:\Python310",
    [string]$Match     = "Python 3.10"   # only things matching this are touched
)

$ErrorActionPreference = "Continue"
function Info { param($m) Write-Host "[*] $m" -ForegroundColor Cyan }
function OK   { param($m) Write-Host "[OK] $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }

# A partial install leaves python.exe present but unable to import its stdlib
# ("No module named 'encodings'"), so Test-Path is not enough - actually run it.
function Test-PyWorks {
    param($exe)
    if (-not (Test-Path $exe)) { return $false }
    try { & $exe -c "import encodings, os, zlib; print('pyok')" 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }
    catch { return $false }
}

# Stale PYTHONHOME/PYTHONPATH make the interpreter resolve relative sys.path and
# fail to find its stdlib. Clear them at every scope + the current process.
function Clear-PyEnv {
    foreach ($sc in "Machine","User") {
        [Environment]::SetEnvironmentVariable("PYTHONHOME",$null,$sc)
        [Environment]::SetEnvironmentVariable("PYTHONPATH",$null,$sc)
    }
    $env:PYTHONHOME = $null; $env:PYTHONPATH = $null
}

Info "Cleaning Python installs matching '*$Match*'."

# --- 0. Make sure the Installer + VSS services can run -----------------------
# VSS disabled is a common cause of 0x80070643 during MSI operations.
foreach ($svc in "VSS","msiserver") {
    try {
        $s = Get-Service $svc -ErrorAction Stop
        if ($s.StartType -eq "Disabled") { Set-Service $svc -StartupType Manual }
        if ($s.Status -ne "Running" -and $svc -eq "VSS") { Start-Service $svc -ErrorAction SilentlyContinue }
        OK "$svc service ready ($((Get-Service $svc).StartType))."
    } catch { Warn "$svc not adjustable: $_" }
}

# --- 1. Best-effort proper uninstall via each ARP entry's UninstallString ----
$arpRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
)
$arp = foreach ($r in $arpRoots) {
    Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.DisplayName -like "*$Match*") {
            [pscustomobject]@{ Name=$p.DisplayName; Key=$_.PSChildName; Path=$_.PSPath; Uninstall=$p.UninstallString }
        }
    }
}
if ($arp) {
    foreach ($e in $arp) {
        Info "Trying uninstall: $($e.Name)  [$($e.Key)]"
        try {
            if ($e.Key -match '^{[0-9A-Fa-f\-]+}$') {
                # It's an MSI product code -> msiexec /x
                Start-Process msiexec.exe -Wait -ArgumentList "/x $($e.Key) /qn /norestart MSIFASTINSTALL=7"
            } elseif ($e.Uninstall) {
                # It's a Wix bundle -> run its cached bootstrapper with /uninstall
                $exe = ($e.Uninstall -replace '"','').Trim()
                if ($exe -match '\.exe') {
                    $exePath = ($exe -split '\.exe')[0] + '.exe'
                    Start-Process $exePath -Wait -ArgumentList "/uninstall /quiet /norestart"
                }
            }
        } catch { Warn "uninstall attempt failed (will force-remove reg next): $_" }
    }
} else { Info "No ARP entries matched (may already be gone)." }

# --- 2. Best-effort package-manager uninstall -------------------------------
try {
    Get-Package -Name "*$Match*" -ErrorAction SilentlyContinue | ForEach-Object {
        Info "Uninstall-Package: $($_.Name)"
        Uninstall-Package -Name $_.Name -Force -ErrorAction SilentlyContinue | Out-Null
    }
} catch { Warn "Get-Package pass skipped: $_" }

# --- 3. Force-remove any leftover REGISTRATION the MSI engine wouldn't clear --
# (Files are already gone, so what blocks reinstall is the registration itself.)
$removed = 0

# 3a. ARP keys still present
foreach ($r in $arpRoots) {
    Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.DisplayName -like "*$Match*") {
            Info "Removing ARP key: $($p.DisplayName)"
            Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue; $removed++
        }
    }
}

# 3b. Windows Installer product/feature registrations (per-machine + per-user)
$prodRoots = @(
    "HKLM:\SOFTWARE\Classes\Installer\Products",
    "HKCU:\SOFTWARE\Microsoft\Installer\Products"
)
foreach ($r in $prodRoots) {
    Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.ProductName -like "*$Match*") {
            Info "Removing Installer product reg: $($p.ProductName)"
            Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue; $removed++
        }
    }
}

# 3c. PythonCore keys
foreach ($k in @(
    "HKLM:\SOFTWARE\Python\PythonCore\3.10",
    "HKLM:\SOFTWARE\Python\PythonCore\3.10-32",
    "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore\3.10",
    "HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore\3.10-32",
    "HKCU:\SOFTWARE\Python\PythonCore\3.10",
    "HKCU:\SOFTWARE\Python\PythonCore\3.10-32")) {
    if (Test-Path $k) { Info "Removing $k"; Remove-Item $k -Recurse -Force -ErrorAction SilentlyContinue; $removed++ }
}
OK "Registration cleanup done ($removed key group(s) removed)."

# 3d. Clear stale PYTHONHOME / PYTHONPATH (a cause of the 'encodings' failure)
Clear-PyEnv
OK "Cleared any PYTHONHOME / PYTHONPATH environment variables."

# --- 4. Remove leftover files: install dirs + Package Cache bundles ----------
$dirs = @(
    $TargetDir,
    "$env:LOCALAPPDATA\Programs\Python\Python310-32",
    "$env:LOCALAPPDATA\Programs\Python\Python310"
)
foreach ($d in $dirs) {
    if (Test-Path $d) { Info "Removing folder $d"; Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}
Get-ChildItem "$env:ProgramData\Package Cache" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    if (Get-ChildItem $_.FullName -Filter "python-3.10.11*.exe" -ErrorAction SilentlyContinue) {
        Info "Removing Package Cache bundle: $($_.Name)"
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- 5. Verify --------------------------------------------------------------
$still = @()
try { $still += (Get-Package -Name "*$Match*" -ErrorAction SilentlyContinue).Name } catch {}
foreach ($r in $arpRoots) {
    $still += (Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName } |
               Where-Object { $_ -like "*$Match*" })
}
Write-Host ""
if ($still.Count -eq 0 -and -not (Test-Path "$TargetDir\python.exe")) {
    OK "Python 3.10 fully removed. Registration and files are clean."
} else {
    Warn "Still present: $($still -join ', ')"
    Warn "If anything remains, REBOOT and run this script once more (a pending"
    Warn "reboot blocks MSI cleanup), then continue."
}

# --- pending reboot check ----------------------------------------------------
$pending = (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") -or
           (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") -or
           [bool](Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)

# --- 6. Optional clean reinstall --------------------------------------------
if ($Reinstall) {
    if ($pending) {
        Warn "A reboot is PENDING - do NOT reinstall now."
        Warn "Reboot, then run:  .\clean_python.ps1 -Reinstall"
        exit 0
    }
    Info "Installing Python 3.10.11 (32-bit) to $TargetDir ..."
    Clear-PyEnv
    $inst = "$env:TEMP\python-3.10.11.exe"
    $common = "MSIFASTINSTALL=7 InstallAllUsers=1 PrependPath=1 Include_pip=1 Include_test=0 TargetDir=$TargetDir"
    $pyexe = "$TargetDir\python.exe"
    try {
        Invoke-WebRequest "https://www.python.org/ftp/python/3.10.11/python-3.10.11.exe" -OutFile $inst -UseBasicParsing -ErrorAction Stop

        # Attempt 1: normal quiet install.
        Info "Install pass 1 (quiet)..."
        $p = Start-Process $inst -ArgumentList "/quiet $common /log C:\python_install.log" -Wait -PassThru
        Info "exit code: $($p.ExitCode)"

        # Attempt 2: if the interpreter can't load its stdlib, leftover component
        # registration made the installer SKIP files. /repair rewrites them all.
        if (-not (Test-PyWorks $pyexe)) {
            Warn "Interpreter incomplete (stdlib not loading). Forcing /repair..."
            $p = Start-Process $inst -ArgumentList "/quiet /repair $common /log C:\python_repair.log" -Wait -PassThru
            Info "repair exit code: $($p.ExitCode)"
        }

        # Attempt 3: last resort - wipe folder + registration, then install fresh.
        if (-not (Test-PyWorks $pyexe)) {
            Warn "Still broken - wiping and doing a from-scratch install..."
            Start-Process $inst -ArgumentList "/uninstall /quiet" -Wait | Out-Null
            Remove-Item $TargetDir -Recurse -Force -ErrorAction SilentlyContinue
            $p = Start-Process $inst -ArgumentList "/quiet $common /log C:\python_install2.log" -Wait -PassThru
            Info "final exit code: $($p.ExitCode)"
        }
        Remove-Item $inst -Force -ErrorAction SilentlyContinue

        if (-not (Test-PyWorks $pyexe)) {
            $log = @("C:\python_repair.log","C:\python_install.log") | Where-Object { Test-Path $_ } | Select-Object -First 1
            $tail = if ($log) { (Get-Content $log -Tail 12) -join "`n" } else { "(no log)" }
            throw @"
Interpreter still can't load its stdlib after 3 attempts.
This guest's Windows Installer state is damaged beyond a scripted fix.
Recommended: revert the VM to a clean snapshot and run sandbox_config.ps1 once
(never -Purge). If no snapshot exists, repair Windows: 'sfc /scannow' then
'DISM /Online /Cleanup-Image /RestoreHealth', reboot, and retry.
Log tail ($log):
$tail
"@
        }

        OK "Interpreter healthy: $(& $pyexe --version 2>&1)"
        & $pyexe -m ensurepip --upgrade 2>$null | Out-Null
        & $pyexe -m pip install --disable-pip-version-check Pillow
        & $pyexe -c "import PIL; print('[OK] Pillow', PIL.__version__)"
        OK "Python + Pillow installed and verified. Now re-run .\sandbox_config.ps1"
    } catch { Warn "Reinstall failed: $_" }
} else {
    Write-Host ""
    Info "Clean-only done. To install now:  .\clean_python.ps1 -Reinstall"
    if ($pending) { Warn "(Reboot first - a reboot is pending.)" }
}