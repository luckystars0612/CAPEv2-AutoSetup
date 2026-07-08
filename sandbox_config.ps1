# sandbox_config.ps1 - Configure a Windows VM as a CAPEv2 sandbox guest.
#
# Modes:
#   .\sandbox_config.ps1                    # install / configure everything
#   .\sandbox_config.ps1 -Verify           # readiness check only (no changes)
#   .\sandbox_config.ps1 -Uninstall        # remove the CAPE agent setup
#   .\sandbox_config.ps1 -Uninstall -Purge # also remove Python + Sysmon
#
# Install mode does:
#   1. Static IP on the first non-virtual "Up" adapter.
#   2. Disable Teredo, LLMNR, Defender (policy), Firewall, Store, UAC.
#   3. Guest-state hardening: SmartScreen off, WER off,
#      auto-reboot/maintenance off, power plan never-sleep, Edge first-run off.
#   4. Sysmon (SwiftOnSecurity config).
#   5. Python 3.10.11 (32-bit) to C:\Python310 + Pillow (verified).
#   6. Local admin analysis user + auto-logon.
#   7. CAPE agent as an INTERACTIVE scheduled task (Session 1, elevated).
#   8. Optional computer rename (-NewHostName) for a less sandboxy fingerprint.
#
# MANUAL STEP the script CANNOT do: turn OFF Tamper Protection in
#   Windows Security -> Virus & threat protection -> Manage settings.
#   Microsoft blocks scripted changes to it. -Verify will fail until it's off.
#
# Run elevated:
#   Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine
#
# IPs are patched in by cape_config.py from sandbox.conf.

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$Verify,
    [string]$AnalystUser     = "analyst",
    [string]$AnalystPassword = "cape",
    [string]$NewHostName     = "",     # e.g. "DESKTOP-7QF2K1" ; blank = leave as is
    [int]$AgentPort          = 8000,   # CAPE agent listen port
    [switch]$NoRestart
)

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error "Run this as Administrator."; exit 1 }

# --- shared constants --------------------------------------------------------
$taskName   = "CAPE_Agent"
$agentDest  = "C:\cape_agent.pyw"
$pythonDir  = "C:\Python310"
$pythonExe  = "$pythonDir\python.exe"
$pythonwExe = "$pythonDir\pythonw.exe"
$pipExe     = "$pythonDir\Scripts\pip.exe"
$winlogon   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

function Set-Reg {
    param($Path, $Name, $Value, $Type = "DWord")
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

# =============================================================================
#  VERIFY MODE  -  readiness gate; exit 0 = ready to snapshot, 1 = not ready
# =============================================================================
function Invoke-Verify {
    Write-Host "=== CAPE guest readiness check ===" -ForegroundColor Cyan
    $script:fail = 0
    function Check { param($ok, $label, $detail="")
        if ($ok) { Write-Host ("  [PASS] {0} {1}" -f $label, $detail) -ForegroundColor Green }
        else     { Write-Host ("  [FAIL] {0} {1}" -f $label, $detail) -ForegroundColor Red; $script:fail++ }
    }

    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Check (-not $mp.RealTimeProtectionEnabled) "Defender real-time protection OFF"
        Check (-not $mp.IsTamperProtected) "Tamper Protection OFF" `
            $(if ($mp.IsTamperProtected) {"-> disable in Windows Security GUI, then re-run"} else {""})
    } catch { Write-Host "  [warn] Get-MpComputerStatus unavailable." -ForegroundColor Yellow }

    $fwOn = (Get-NetFirewallProfile | Where-Object { $_.Enabled -eq $true }).Count
    Check ($fwOn -eq 0) "Firewall disabled on all profiles"

    Check (Test-Path $pythonExe) "Python present at $pythonExe"
    if (Test-Path $pythonExe) {
        & $pythonExe -c "import PIL" 2>$null
        Check ($LASTEXITCODE -eq 0) "Pillow importable"
    }

    $al = (Get-ItemProperty $winlogon -ErrorAction SilentlyContinue).AutoAdminLogon
    Check ($al -eq "1") "Auto-logon enabled"

    Check ([bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) "Scheduled task '$taskName' exists"

    $agent = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -like "*cape_agent*" -or $_.CommandLine -like "*agent.py*" } |
             Select-Object -First 1
    if ($agent) { Check ($agent.SessionId -ge 1) "Agent in interactive session" "(SessionId=$($agent.SessionId))" }
    else        { Check $false "Agent process running" "(log in as the analysis user first)" }

    $listen = Get-NetTCPConnection -State Listen -LocalPort $AgentPort -ErrorAction SilentlyContinue
    Check ([bool]$listen) "Agent listening on port $AgentPort"

    Write-Host ""
    if ($script:fail -eq 0) { Write-Host "READY. Safe to snapshot from the host." -ForegroundColor Green; return 0 }
    else { Write-Host "$($script:fail) check(s) failed - fix before snapshotting." -ForegroundColor Red; return 1 }
}

if ($Verify) { $rc = Invoke-Verify; exit $rc }

try { Start-Transcript -Path "C:\SandboxSetup.log" -Append -ErrorAction Stop } catch { Write-Warning "Transcript: $_" }

# =============================================================================
#  UNINSTALL MODE
# =============================================================================
function Invoke-Uninstall {
    Write-Host "=== Removing CAPE sandbox agent setup ===" -ForegroundColor Yellow
    try {
        Get-CimInstance Win32_Process -Filter "Name='pythonw.exe' OR Name='python.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*cape_agent*" -or $_.CommandLine -like "*agent.py*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                             Write-Host "[OK] Killed agent pid $($_.ProcessId)." }
    } catch { Write-Warning "kill agent: $_" }

    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[OK] Scheduled task '$taskName' removed."
    }
    foreach ($lnk in @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\cape_agent.lnk",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\cape_agent.lnk")) {
        if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue; Write-Host "[OK] Removed $lnk" }
    }
    if (Test-Path $agentDest) { Remove-Item $agentDest -Force -ErrorAction SilentlyContinue; Write-Host "[OK] Removed $agentDest" }

    Set-ItemProperty $winlogon "AutoAdminLogon" "0" -ErrorAction SilentlyContinue
    Remove-ItemProperty $winlogon "DefaultPassword"   -ErrorAction SilentlyContinue
    Remove-ItemProperty $winlogon "DefaultUserName"   -ErrorAction SilentlyContinue
    Remove-ItemProperty $winlogon "DefaultDomainName" -ErrorAction SilentlyContinue
    Write-Host "[OK] Auto-logon reverted."

    if ($Purge) {
        Write-Host "--- -Purge: removing Sysmon + Python ---" -ForegroundColor Yellow
        $sm = @("$env:SystemRoot\Sysmon64.exe","$env:SystemRoot\Sysmon.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($sm) { try { & $sm -u force 2>&1 | Out-Null; Write-Host "[OK] Sysmon uninstalled." } catch { Write-Warning "sysmon -u: $_" } }
        foreach ($svc in "Sysmon64","Sysmon") {
            if (Get-Service $svc -ErrorAction SilentlyContinue) { sc.exe stop $svc|Out-Null; sc.exe delete $svc|Out-Null; Write-Host "[OK] Removed service $svc." }
        }
        if (Test-Path $pythonDir) { try { Remove-Item $pythonDir -Recurse -Force -ErrorAction Stop; Write-Host "[OK] Removed $pythonDir." } catch { Write-Warning "remove python: $_" } }
    }
    Write-Host "`nCleanup complete." -ForegroundColor Green
}

if ($Uninstall) { Invoke-Uninstall; try { Stop-Transcript | Out-Null } catch {}; exit 0 }

# =============================================================================
#  INSTALL MODE
# =============================================================================

# --- IPs patched by cape_config.py ------------------------------------------
$sandbox_ip = "192.168.122.50" # patched from sandbox.conf:sandbox_ip
$cape_ip = "192.168.122.1" # patched from sandbox.conf:resultserver_ip

function Test-IpPatched {
    param([string]$Value, [string]$Name)
    if ($Value -eq "192.168.121.50" -or [string]::IsNullOrWhiteSpace($Value)) {
        Write-Error "$Name not patched from sandbox.conf (still '$Value'). Re-run cape_config.py."; exit 1
    }
    try { [System.Net.IPAddress]::Parse($Value) | Out-Null } catch { Write-Error "$Name invalid IP: $Value"; exit 1 }
}
Test-IpPatched $sandbox_ip "sandbox_ip"
Test-IpPatched $cape_ip "cape_ip"

# --- network adapter + static IP --------------------------------------------
function Get-PhysicalAdapter {
    $c = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and -not $_.Virtual -and $_.HardwareInterface } | Sort-Object ifIndex
    if ($c) { return $c | Select-Object -First 1 }
    $f = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Sort-Object ifIndex | Select-Object -First 1
    if ($f) { Write-Warning "No physical adapter, using '$($f.Name)'."; return $f }
    Write-Error "No active network adapter."; exit 1
}
$adapter = Get-PhysicalAdapter
Write-Host "Using adapter: $($adapter.Name)"
try {
    Remove-NetIPAddress -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute     -InterfaceAlias $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $sandbox_ip -PrefixLength 24 -DefaultGateway $cape_ip -ErrorAction Stop
    Set-DnsClientServerAddress -InterfaceAlias $adapter.Name -ServerAddresses ("8.8.8.8","8.8.4.4") -ErrorAction Stop
    Write-Host "[OK] Static IP $sandbox_ip / gw $cape_ip."
} catch { Write-Error "Static IP failed: $_"; exit 1 }

# --- privacy / discovery disables -------------------------------------------
try { netsh interface teredo set state disabled | Out-Null; Write-Host "[OK] Teredo off." } catch { Write-Warning "Teredo: $_" }
try { Set-Reg "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient" "EnableMulticast" 0; Write-Host "[OK] LLMNR off." } catch { Write-Warning "LLMNR: $_" }

# --- Defender (policy; Tamper Protection must be off manually first) ---------
try {
    $defPath = "HKLM:\Software\Policies\Microsoft\Windows Defender"
    Set-Reg $defPath "DisableAntiSpyware" 1
    Set-Reg "$defPath\Real-Time Protection" "DisableRealtimeMonitoring" 1
    try { Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop }
    catch { Write-Warning "DisableRealtimeMonitoring skipped (Tamper Protection still on?): $_" }
    try { Set-MpPreference -DisableBehaviorMonitoring $true -ErrorAction Stop }
    catch { Write-Warning "DisableBehaviorMonitoring skipped (Tamper Protection still on?): $_" }
    Write-Host "[OK] Defender policy disables applied."
} catch { Write-Warning "Defender: $_" }

# --- Firewall / Store / UAC -------------------------------------------------
try { Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled False -ErrorAction Stop; Write-Host "[OK] Firewall off." } catch { Write-Warning "Firewall: $_" }
try { Set-Reg "HKLM:\Software\Policies\Microsoft\WindowsStore" "RemoveWindowsStore" 1; Write-Host "[OK] Store off." } catch { Write-Warning "Store: $_" }
try {
    $sysPol = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-Reg $sysPol "EnableLUA" 0; Set-Reg $sysPol "ConsentPromptBehaviorAdmin" 0
    Write-Host "[OK] UAC off (after reboot)."
} catch { Write-Warning "UAC: $_" }

# --- guest-state hardening ---------------------------------------------------
# (Windows Update intentionally left ENABLED per preference.)
try {
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableSmartScreen" 0
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" "SmartScreenEnabled" "Off" "String"
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "SmartScreenEnabled" 0
    Set-Reg "HKLM:\SOFTWARE\Policies\Microsoft\Edge" "HideFirstRunExperience" 1
    Write-Host "[OK] SmartScreen + Edge first-run off."
} catch { Write-Warning "SmartScreen: $_" }

try {
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" "Disabled" 1
    Set-Reg "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance" "MaintenanceDisabled" 1
    Write-Host "[OK] WER + auto-maintenance off."
} catch { Write-Warning "WER/maintenance: $_" }

try {
    powercfg /change monitor-timeout-ac 0 2>$null
    powercfg /change standby-timeout-ac 0 2>$null
    powercfg /change disk-timeout-ac 0 2>$null
    powercfg /change hibernate-timeout-ac 0 2>$null
    powercfg /hibernate off 2>$null
    Write-Host "[OK] Power plan: never sleep."
} catch { Write-Warning "powercfg: $_" }

if ($NewHostName -and $NewHostName -ne $env:COMPUTERNAME) {
    try { Rename-Computer -NewName $NewHostName -Force -ErrorAction Stop; Write-Host "[OK] Renamed to $NewHostName (after reboot)." }
    catch { Write-Warning "Rename: $_" }
}

# --- Sysmon ------------------------------------------------------------------
$sysmonInstallOk = $false
try {
    $z="$env:TEMP\Sysmon.zip"; $d="$env:TEMP\Sysmon"; $cfg="$d\sysmonconfig.xml"
    $exe = if ([Environment]::Is64BitOperatingSystem) { "Sysmon64.exe" } else { "Sysmon.exe" }
    Invoke-WebRequest "https://download.sysinternals.com/files/Sysmon.zip" -OutFile $z -UseBasicParsing -ErrorAction Stop
    if (Test-Path $d) { Remove-Item -Recurse -Force $d }
    Expand-Archive $z -DestinationPath $d -Force -ErrorAction Stop
    Invoke-WebRequest "https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml" -OutFile $cfg -UseBasicParsing -ErrorAction Stop
    Start-Process "$d\$exe" -ArgumentList "-accepteula -i `"$cfg`"" -Verb RunAs -Wait -ErrorAction Stop
    $sysmonInstallOk = $true; Write-Host "[OK] Sysmon installed."
} catch { Write-Warning "Sysmon: $_" }

# --- Python 3.10.11 (32-bit) + Pillow ---------------------------------------
try {
    if (Test-Path $pythonExe) { Write-Host "Python already at $pythonExe." }
    else {
        $inst="$env:TEMP\python-3.10.11.exe"
        $pyArgs = "/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1 TargetDir=$pythonDir"
        Invoke-WebRequest "https://www.python.org/ftp/python/3.10.11/python-3.10.11.exe" -OutFile $inst -UseBasicParsing -ErrorAction Stop
        Write-Host "Installing Python..."
        $p = Start-Process $inst -ArgumentList $pyArgs -Wait -PassThru
        Write-Host "Installer exit code: $($p.ExitCode)"
        # A stale registration from a previous (e.g. -Purge'd) install makes the
        # /quiet installer no-op instead of writing files. Clear it and retry.
        if (-not (Test-Path $pythonExe)) {
            Write-Warning "python.exe not found - clearing prior registration and retrying."
            Start-Process $inst -ArgumentList "/uninstall /quiet" -Wait
            $p = Start-Process $inst -ArgumentList $pyArgs -Wait -PassThru
            Write-Host "Reinstall exit code: $($p.ExitCode)"
        }
        Remove-Item $inst -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $pythonExe)) {
            throw "python.exe still missing at $pythonExe (installer exit $($p.ExitCode)). Reboot once and re-run - a pending Python MSI operation may need clearing first."
        }
    }
    Write-Host "[OK] $(& $pythonExe --version 2>&1)"
    # FIX: real flag is --disable-pip-version-check (old script used a nonexistent
    # flag, so pip errored and Pillow never installed -> 'No module named PIL').
    & $pipExe install --quiet --disable-pip-version-check Pillow
    & $pythonExe -c "import PIL; print('[OK] Pillow', PIL.__version__)"
    if ($LASTEXITCODE -ne 0) { throw "Pillow import check failed." }
} catch { Write-Error "Python/Pillow: $_"; exit 1 }

# --- analysis user + auto-logon ---------------------------------------------
try {
    $sec = ConvertTo-SecureString $AnalystPassword -AsPlainText -Force
    if (-not (Get-LocalUser -Name $AnalystUser -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name $AnalystUser -Password $sec -FullName $AnalystUser -Description "CAPE analysis user" `
            -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
        Write-Host "[OK] Created user '$AnalystUser'."
    } else { Set-LocalUser -Name $AnalystUser -Password $sec -ErrorAction SilentlyContinue; Write-Host "User '$AnalystUser' exists - pw reset." }
    Add-LocalGroupMember -Group "Administrators" -Member $AnalystUser -ErrorAction SilentlyContinue

    Set-ItemProperty $winlogon "AutoAdminLogon" "1"
    Set-ItemProperty $winlogon "DefaultUserName" $AnalystUser
    Set-ItemProperty $winlogon "DefaultPassword" $AnalystPassword
    Set-ItemProperty $winlogon "DefaultDomainName" $env:COMPUTERNAME
    Remove-ItemProperty $winlogon "AutoLogonCount" -ErrorAction SilentlyContinue
    Write-Host "[OK] Auto-logon for '$AnalystUser'."
} catch { Write-Error "User/auto-logon: $_"; exit 1 }

# --- CAPE agent as INTERACTIVE scheduled task -------------------------------
try {
    if (-not (Test-Path $agentDest)) {
        Invoke-WebRequest "https://raw.githubusercontent.com/kevoreilly/CAPEv2/master/agent/agent.py" -OutFile $agentDest -UseBasicParsing -ErrorAction Stop
    }
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $action    = New-ScheduledTaskAction -Execute $pythonwExe -Argument "`"$agentDest`""
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $AnalystUser
    $principal = New-ScheduledTaskPrincipal -UserId $AnalystUser -RunLevel Highest -LogonType Interactive
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "CAPE agent (interactive)"
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    Write-Host "[OK] Interactive agent task '$taskName' registered as $AnalystUser."
} catch { Write-Warning "Agent task: $_" }

# --- summary -----------------------------------------------------------------
Write-Host "`n================ Summary ================"
Write-Host "Adapter        : $($adapter.Name)"
Write-Host "Sandbox IP     : $sandbox_ip   gateway $cape_ip"
Write-Host "Python         : $pythonExe"
Write-Host "Sysmon         : $(if ($sysmonInstallOk){'installed'}else{'FAILED'})"
Write-Host "Analysis user  : $AnalystUser (auto-logon)"
Write-Host "Agent task     : $taskName (interactive / Session 1)"
Write-Host "========================================`n"
Write-Host "!! MANUAL: turn OFF Tamper Protection in Windows Security GUI." -ForegroundColor Yellow
Write-Host "Then: reboot, run '.\sandbox_config.ps1 -Verify' after auto-logon,"
Write-Host "and only snapshot (from the host) once every check PASSes.`n"

if (-not $NoRestart) {
    if ((Read-Host "Restart now? (Y/N)") -match '^[Yy]$') { Restart-Computer -Force }
    else { Write-Host "Restart manually to apply all changes." }
}
try { Stop-Transcript | Out-Null } catch { }