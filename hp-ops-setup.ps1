#Requires -Version 5.1
<#
.SYNOPSIS
    Prepare an idle laptop as an always-on Claude box: audit it, back up and then turn off
    sleep, hibernate and the lid-close action, check whether Claude starts at login, and
    write a report.

.DESCRIPTION
    Installs nothing. Changes no accounts, sign-ins or auto-login.
    The only system change is to the active power plan (step 2).
    Writes only these files, all in your home folder:
        hp-power-backup.txt    sleep, hibernate and lid values from before the change, plus the
                               commands that restore them. If it already exists (a second run),
                               a timestamped copy is written instead, so the original values
                               are never overwritten.
        hp-battery-report.xml  only if battery capacity can't be read through WMI
        hp-audit.md            the full report

    If a powercfg command is refused for lack of admin rights, the script stops changing
    settings, names that command, and still finishes the read-only checks and the report.

.PARAMETER AuditOnly
    Skip step 2: no backup and no changes, report only.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\hp-ops-setup.ps1
#>
[CmdletBinding()]
param([switch]$AuditOnly)

if ($env:OS -ne 'Windows_NT') { Write-Error 'This script runs on Windows only.'; exit 1 }

$ErrorActionPreference = 'Continue'
$Now        = Get-Date
$BackupPath = Join-Path $HOME 'hp-power-backup.txt'
$AuditPath  = Join-Path $HOME 'hp-audit.md'
$BatteryXml = Join-Path $HOME 'hp-battery-report.xml'
$filesWritten = New-Object System.Collections.Generic.List[string]

function Invoke-Safe([scriptblock]$Block) { try { & $Block } catch { } }
function ConvertTo-GB($Bytes) { if ($null -eq $Bytes -or "$Bytes" -eq '') { return $null }; [math]::Round([double]$Bytes / 1GB, 1) }
function Format-Value($Value, [string]$Fallback = 'unreadable') { if ($null -eq $Value -or "$Value" -eq '') { $Fallback } else { "$Value" } }
function Format-Date($Date) { if ($Date) { '{0:yyyy-MM-dd HH:mm}' -f $Date } else { 'unreadable' } }
function Esc($Text) { ("$Text" -replace '\|', '\|') -replace "`r?`n", ' ' }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# =============================================================================
# Step 1: read-only audit
# =============================================================================
Write-Host 'Step 1: reading hardware, Windows, network and power settings...'

# --- RAM ---------------------------------------------------------------------
$memModules = @(Invoke-Safe { Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop })
$memArrays  = @(Invoke-Safe { Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop })
$ramBytes   = ($memModules | Measure-Object -Property Capacity -Sum).Sum
if (-not $ramBytes) { $ramBytes = Invoke-Safe { (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } }
$ramGB      = ConvertTo-GB $ramBytes
$slotsUsed  = $memModules.Count
$slotsTotal = ($memArrays | Measure-Object -Property MemoryDevices -Sum).Sum
$ramOk      = ($ramGB -ge 7.5)   # 8 GB installed can read as 7.8 when only usable memory is visible

# --- CPU and GPU -------------------------------------------------------------
$cpu = Invoke-Safe { Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 }
$cpuText = if ($cpu) { '{0} ({1} cores, {2} threads)' -f "$($cpu.Name)".Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors } else { 'unreadable' }
$gpuLines = @(Invoke-Safe { Get-CimInstance Win32_VideoController -ErrorAction Stop }) |
    ForEach-Object { '{0} (driver {1})' -f "$($_.Name)".Trim(), $_.DriverVersion }

# --- Disks and volumes -------------------------------------------------------
$volumes = @(Invoke-Safe { Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop })
$volRows = foreach ($v in $volumes) {
    [pscustomobject]@{
        Drive   = $v.DeviceID
        Label   = $v.VolumeName
        SizeGB  = ConvertTo-GB $v.Size
        FreeGB  = ConvertTo-GB $v.FreeSpace
        FreePct = if ($v.Size) { [math]::Round(100 * $v.FreeSpace / $v.Size) } else { $null }
    }
}
$volRows = @($volRows)

$diskRows = @()
foreach ($pd in @(Invoke-Safe { Get-PhysicalDisk -ErrorAction Stop })) {
    $media = "$($pd.MediaType)"
    $bus   = "$($pd.BusType)"
    if ($media -ne 'SSD' -and $media -ne 'HDD') {
        if ($bus -eq 'NVMe')                                                   { $media = 'SSD' }
        elseif ($pd.SpindleSpeed -eq 0)                                         { $media = 'SSD' }
        elseif ($pd.SpindleSpeed -gt 0 -and $pd.SpindleSpeed -lt 4294967295)    { $media = 'HDD' }
        else                                                                    { $media = 'Unknown' }
    }
    $letters = @(Invoke-Safe {
        Get-Partition -DiskNumber ([int]$pd.DeviceId) -ErrorAction Stop |
            Where-Object { "$($_.DriveLetter)" -match '^[A-Za-z]$' } |
            ForEach-Object { "$($_.DriveLetter):" }
    })
    $freeBytes = ($volumes | Where-Object { $letters -contains $_.DeviceID } | Measure-Object -Property FreeSpace -Sum).Sum
    $diskRows += [pscustomobject]@{
        Model   = "$($pd.FriendlyName)".Trim()
        Type    = $media
        Bus     = $bus
        SizeGB  = ConvertTo-GB $pd.Size
        FreeGB  = if ($letters.Count) { ConvertTo-GB $freeBytes } else { $null }
        Volumes = ($letters -join ' ')
        Health  = "$($pd.HealthStatus)"
    }
}
if (-not $diskRows.Count) {
    foreach ($dd in @(Invoke-Safe { Get-CimInstance Win32_DiskDrive -ErrorAction Stop })) {
        $diskRows += [pscustomobject]@{
            Model = "$($dd.Model)".Trim(); Type = 'Unknown'; Bus = "$($dd.InterfaceType)"
            SizeGB = ConvertTo-GB $dd.Size; FreeGB = $null; Volumes = ''; Health = "$($dd.Status)"
        }
    }
}

# --- Battery -----------------------------------------------------------------
$batteries      = @(Invoke-Safe { Get-CimInstance Win32_Battery -ErrorAction Stop })
$batteryPresent = $batteries.Count -gt 0
$batteryCharge = $null; $batteryState = $null; $designCap = $null; $fullCap = $null; $batterySource = $null
if ($batteryPresent) {
    $batteryCharge = $batteries[0].EstimatedChargeRemaining
    $statusNames = @{ 1 = 'on battery'; 2 = 'on AC power'; 3 = 'fully charged'; 4 = 'low'; 5 = 'critical';
                      6 = 'charging'; 7 = 'charging'; 8 = 'charging'; 9 = 'charging'; 11 = 'partially charged' }
    $batteryState = $statusNames[[int]$batteries[0].BatteryStatus]
    $designCap = (@(Invoke-Safe { Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop }) |
                  Measure-Object -Property DesignedCapacity -Sum).Sum
    $fullCap   = (@(Invoke-Safe { Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop }) |
                  Measure-Object -Property FullChargedCapacity -Sum).Sum
    if ($designCap -and $fullCap) {
        $batterySource = 'WMI'
    } else {
        Invoke-Safe { & powercfg.exe /batteryreport /xml /output "$BatteryXml" *> $null }
        if (Test-Path -LiteralPath $BatteryXml) {
            $filesWritten.Add($BatteryXml)
            $designCap = 0; $fullCap = 0
            $xml = Invoke-Safe { [xml](Get-Content -LiteralPath $BatteryXml -Raw -ErrorAction Stop) }
            if ($xml) {
                foreach ($b in @($xml.BatteryReport.Batteries.Battery)) {
                    if ($b) { $designCap += [double]$b.DesignCapacity; $fullCap += [double]$b.FullChargeCapacity }
                }
            }
            if ($designCap -and $fullCap) { $batterySource = 'powercfg battery report' }
        }
    }
}
$batteryHealthPct = $null; $batteryWearPct = $null
if ($designCap -gt 0 -and $fullCap -gt 0) {
    $batteryHealthPct = [math]::Round(100 * $fullCap / $designCap)
    $batteryWearPct   = [math]::Max(0, 100 - $batteryHealthPct)
}

# --- Windows -----------------------------------------------------------------
$os = Invoke-Safe { Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
$cv = Invoke-Safe { Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop }
$buildNumber = [int]("0" + "$($os.BuildNumber)")
$isWin10 = ($buildNumber -gt 0 -and $buildNumber -lt 22000)
$winName = ("$($os.Caption)".Trim()) -replace '^Microsoft\s+', ''
if ($buildNumber -ge 22000) { $winName = $winName -replace 'Windows 10', 'Windows 11' }
if (-not $winName) { $winName = 'Windows (edition unreadable)' }
$winVersion = Format-Value $cv.DisplayVersion (Format-Value $cv.ReleaseId)
$winBuild   = if ($null -ne $cv.UBR) { "$($os.BuildNumber).$($cv.UBR)" } else { Format-Value $os.BuildNumber }
$lastBoot   = $os.LastBootUpTime
$uptimeText = if ($lastBoot) { $u = $Now - $lastBoot; '{0}d {1}h {2}m' -f $u.Days, $u.Hours, $u.Minutes } else { 'unreadable' }

# Last installed update: Windows Update history (skipping Defender definition updates) and Get-HotFix.
$lastWu = Invoke-Safe {
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $count = $searcher.GetTotalHistoryCount()
    if ($count -gt 0) {
        $searcher.QueryHistory(0, [math]::Min($count, 300)) |
            Where-Object { $_.Operation -eq 1 -and ($_.ResultCode -eq 2 -or $_.ResultCode -eq 3) -and
                           $_.Title -notmatch 'Security Intelligence|Definition Update|KB2267602|Antimalware platform' } |
            Sort-Object -Property Date -Descending | Select-Object -First 1
    }
}
$lastHotfix = Invoke-Safe {
    Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } |
        Sort-Object -Property InstalledOn -Descending | Select-Object -First 1
}
$lastUpdateDate = $null; $lastUpdateTitle = $null
if ($lastWu) { $lastUpdateDate = $lastWu.Date.ToLocalTime(); $lastUpdateTitle = $lastWu.Title }
if ($lastHotfix -and (-not $lastUpdateDate -or $lastHotfix.InstalledOn.Date -gt $lastUpdateDate.Date)) {
    $lastUpdateDate = $lastHotfix.InstalledOn; $lastUpdateTitle = '{0} ({1})' -f $lastHotfix.HotFixID, $lastHotfix.Description
}
$lastUpdateText = if ($lastUpdateDate) { '{0:yyyy-MM-dd}' -f $lastUpdateDate } else { 'unreadable' }

# --- Network -----------------------------------------------------------------
$defaultRouteIfs = @(Invoke-Safe {
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object -Property RouteMetric |
        ForEach-Object { $_.InterfaceIndex }
})
$netRows = @()
foreach ($a in @(Invoke-Safe { Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } })) {
    $medium = "$($a.PhysicalMediaType)"
    $kind = if ($medium -match '802\.11') { 'Wi-Fi' } elseif ($medium -match '802\.3') { 'Ethernet' } elseif ($a.Virtual) { 'Virtual/VPN' } else { "Other ($medium)" }
    $netRows += [pscustomobject]@{
        Index = $a.ifIndex; Name = $a.Name; Kind = $kind; Description = $a.InterfaceDescription
        Speed = $a.LinkSpeed; Internet = ($defaultRouteIfs -contains $a.ifIndex)
    }
}
$primaryNet = $null
foreach ($idx in $defaultRouteIfs) {
    $match = $netRows | Where-Object { $_.Index -eq $idx -and ($_.Kind -eq 'Wi-Fi' -or $_.Kind -eq 'Ethernet') } | Select-Object -First 1
    if ($match) { $primaryNet = $match; break }
}
$netType = if ($primaryNet) { $primaryNet.Kind } elseif ($netRows.Count) { (@($netRows | ForEach-Object { $_.Kind }) | Select-Object -Unique) -join ', ' } else { 'no connected adapter' }

# --- Power -------------------------------------------------------------------
function Get-PowerSetting([string]$SubGroup, [string]$Setting) {
    $raw  = (& powercfg.exe /q SCHEME_CURRENT $SubGroup $Setting 2>&1 | Out-String).Trim()
    $exit = $LASTEXITCODE
    $ac = $null; $dc = $null
    if ($raw -match 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)') { $ac = [Convert]::ToInt64($Matches[1], 16) }
    if ($raw -match 'Current DC Power Setting Index:\s*(0x[0-9a-fA-F]+)') { $dc = [Convert]::ToInt64($Matches[1], 16) }
    if (($null -eq $ac -or $null -eq $dc) -and $exit -eq 0) {
        # Non-English Windows: the current AC and DC values are the last two hex values printed.
        $hex = [regex]::Matches($raw, '0x[0-9a-fA-F]{8}')
        if ($hex.Count -ge 2) {
            $ac = [Convert]::ToInt64($hex[$hex.Count - 2].Value, 16)
            $dc = [Convert]::ToInt64($hex[$hex.Count - 1].Value, 16)
        }
    }
    [pscustomobject]@{ SubGroup = $SubGroup; Setting = $Setting; AC = $ac; DC = $dc; ExitCode = $exit; Raw = $raw }
}
function Get-PowerSnapshot {
    [ordered]@{
        STANDBYIDLE   = Get-PowerSetting 'SUB_SLEEP'   'STANDBYIDLE'
        HIBERNATEIDLE = Get-PowerSetting 'SUB_SLEEP'   'HIBERNATEIDLE'
        LIDACTION     = Get-PowerSetting 'SUB_BUTTONS' 'LIDACTION'
    }
}
function Format-Timeout($Seconds) {
    if ($null -eq $Seconds) { 'unreadable' } elseif ($Seconds -eq 0) { 'never' }
    elseif ($Seconds -lt 60) { "$Seconds s" } else { '{0} min' -f [math]::Round($Seconds / 60) }
}
$lidNames = @{ 0 = 'do nothing'; 1 = 'sleep'; 2 = 'hibernate'; 3 = 'shut down' }
function Format-Lid($Value) {
    if ($null -eq $Value) { 'unreadable' } elseif ($lidNames.ContainsKey([int]$Value)) { $lidNames[[int]$Value] } else { "value $Value" }
}
function Format-Setting($Name, $Value) { if ($Name -eq 'LIDACTION') { Format-Lid $Value } else { Format-Timeout $Value } }

$schemeRaw  = (& powercfg.exe /getactivescheme 2>&1 | Out-String).Trim()
$schemeGuid = if ($schemeRaw -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $Matches[1] } else { $null }
$schemeName = if ($schemeRaw -match '\(([^)]+)\)\s*\*?\s*$') { $Matches[1] } else { '' }
$sleepStatesRaw = (& powercfg.exe /a 2>&1 | Out-String).Trim()
$before = Get-PowerSnapshot

# =============================================================================
# Step 2: back up, then apply
# =============================================================================
$applyResults = @(); $adminRefusal = $null; $otherFailures = @(); $backupWritten = $null; $after = $null
$commands = @(
    'powercfg /change standby-timeout-ac 0'
    'powercfg /change standby-timeout-dc 0'
    'powercfg /change hibernate-timeout-ac 0'
    'powercfg /change hibernate-timeout-dc 0'
    'powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0'
    'powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0'
    'powercfg /setactive SCHEME_CURRENT'
)

if ($AuditOnly) {
    Write-Host 'Step 2: skipped (-AuditOnly). Nothing was backed up or changed.'
} else {
    Write-Host 'Step 2: backing up current sleep, hibernate and lid values...'
    $target = $BackupPath
    if (Test-Path -LiteralPath $target) {
        $target = Join-Path $HOME ('hp-power-backup-{0:yyyyMMdd-HHmmss}.txt' -f $Now)
        Write-Host "  $BackupPath already exists (an earlier run); keeping it and writing $target"
    }
    $scheme = if ($schemeGuid) { $schemeGuid } else { 'SCHEME_CURRENT' }
    $b = New-Object System.Collections.Generic.List[string]
    $b.Add('# Power settings backup, {0:yyyy-MM-dd HH:mm:ss}, computer {1}' -f $Now, $env:COMPUTERNAME)
    $b.Add("# Active power plan: $schemeName $schemeGuid")
    $b.Add('# Timeouts are in seconds (0 = never). LIDACTION: 0 do nothing, 1 sleep, 2 hibernate, 3 shut down.')
    foreach ($k in $before.Keys) {
        $b.Add(('{0}  AC={1} ({2})  DC={3} ({4})' -f $k, (Format-Value $before[$k].AC), (Format-Setting $k $before[$k].AC),
                                                       (Format-Value $before[$k].DC), (Format-Setting $k $before[$k].DC)))
    }
    $b.Add('')
    $b.Add('# To restore these exact values, run these lines in PowerShell:')
    foreach ($k in $before.Keys) {
        $s = $before[$k]
        if ($null -ne $s.AC) { $b.Add("powercfg /setacvalueindex $scheme $($s.SubGroup) $k $($s.AC)") }
        if ($null -ne $s.DC) { $b.Add("powercfg /setdcvalueindex $scheme $($s.SubGroup) $k $($s.DC)") }
    }
    $b.Add("powercfg /setactive $scheme")
    $b.Add('')
    $b.Add('# Raw powercfg output before the change:')
    $b.Add($schemeRaw)
    foreach ($k in $before.Keys) { $b.Add(''); $b.Add($before[$k].Raw) }
    try {
        $b | Set-Content -LiteralPath $target -Encoding UTF8 -ErrorAction Stop
        $backupWritten = $target
        $filesWritten.Add($target)
        Write-Host "  saved $target"
    } catch {
        Write-Warning "Could not write the backup to $target ($($_.Exception.Message)). No settings were changed."
    }

    if ($backupWritten) {
        Write-Host 'Step 2: turning sleep and hibernate off, and setting lid close to do nothing...'
        foreach ($cmd in $commands) {
            $cmdArgs = @($cmd -split ' ' | Select-Object -Skip 1)
            $out  = (& powercfg.exe @cmdArgs 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
            $refused = ($out -match 'denied|permission|administrator|privilege|elevat')
            $result = [pscustomobject]@{ Command = $cmd; ExitCode = $code; Output = $out; Ok = ($code -eq 0 -and -not $refused) }
            $applyResults += $result
            if ($refused) {
                $adminRefusal = $result
                Write-Warning "Refused for lack of admin rights: $cmd"
                Write-Warning 'Stopped here; the remaining commands were not run.'
                break
            }
            if ($code -ne 0) {
                $otherFailures += $result
                Write-Warning "Failed (exit $code): $cmd  $out"
            } else {
                Write-Host "  ok  $cmd"
            }
        }
        $after = Get-PowerSnapshot
    }
}
$current = if ($after) { $after } else { $before }
$sleepOff     = ($current.STANDBYIDLE.AC -eq 0   -and $current.STANDBYIDLE.DC -eq 0)
$hibernateOff = ($current.HIBERNATEIDLE.AC -eq 0 -and $current.HIBERNATEIDLE.DC -eq 0)
$lidNothing   = ($current.LIDACTION.AC -eq 0     -and $current.LIDACTION.DC -eq 0)
$notRun = @()
if ($adminRefusal) { $notRun = @($commands | Select-Object -Skip ([array]::IndexOf($commands, $adminRefusal.Command) + 1)) }

# =============================================================================
# Step 3: Claude start at login, and Remote Control
# =============================================================================
Write-Host 'Step 3: checking whether Claude starts at login, and Remote Control...'

function Get-StartupApproval([string[]]$Names) {
    # Task Manager's Startup tab records enabled/disabled here; an odd first byte means disabled.
    $keys = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32',
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
    foreach ($k in $keys) {
        $item = Invoke-Safe { Get-ItemProperty -LiteralPath $k -ErrorAction Stop }
        if (-not $item) { continue }
        foreach ($n in $Names) {
            if ($n -and $item.PSObject.Properties[$n]) {
                $bytes = [byte[]]$item.$n
                if ($bytes.Length -gt 0 -and ($bytes[0] % 2) -eq 1) { return 'disabled in Task Manager' }
                return 'enabled'
            }
        }
    }
    'enabled'
}

$autostart = @()
$startupCommands = @(Invoke-Safe { Get-CimInstance Win32_StartupCommand -ErrorAction Stop })
foreach ($sc in $startupCommands) {
    if ("$($sc.Name) $($sc.Command)" -notmatch 'claude') { continue }
    $fileName = ("$($sc.Command)" -replace '^.*[\\/]', '').Trim().Trim('"')
    $status = Get-StartupApproval @("$($sc.Name)", $fileName)
    $autostart += [pscustomobject]@{ Source = "Win32_StartupCommand ($($sc.Location))"; Detail = "$($sc.Name): $($sc.Command)"; Status = $status; Active = ($status -eq 'enabled') }
}

$startupFolder       = [Environment]::GetFolderPath('Startup')
$commonStartupFolder = [Environment]::GetFolderPath('CommonStartup')
$startupFolderItems  = @(Get-ChildItem -LiteralPath $startupFolder, $commonStartupFolder -Force -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -ne 'desktop.ini' })
foreach ($f in $startupFolderItems) {
    if ($f.Name -notmatch 'claude') { continue }
    if ($autostart | Where-Object { $_.Detail -match [regex]::Escape($f.Name) }) { continue }
    $status = Get-StartupApproval @($f.Name)
    $autostart += [pscustomobject]@{ Source = 'Startup folder'; Detail = $f.FullName; Status = $status; Active = ($status -eq 'enabled') }
}

# Store (MSIX) builds start through a package startup task instead of the Run key.
$taskStates = @{ 0 = 'disabled'; 1 = 'disabled by you'; 2 = 'enabled'; 3 = 'disabled by policy'; 4 = 'enabled by policy' }
$claudePackages = @(Invoke-Safe { Get-AppxPackage -Name '*Claude*' -ErrorAction Stop })
foreach ($p in $claudePackages) {
    $base = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData\$($p.PackageFamilyName)"
    foreach ($t in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        $state = (Get-ItemProperty -LiteralPath $t.PSPath -ErrorAction SilentlyContinue).State
        if ($null -eq $state) { continue }
        $status = Format-Value $taskStates[[int]$state] "state $state"
        $autostart += [pscustomobject]@{ Source = 'Store app startup task'; Detail = "$($p.Name) / $($t.PSChildName)"; Status = $status; Active = ([int]$state -eq 2 -or [int]$state -eq 4) }
    }
}

$claudeTasks = @(Invoke-Safe {
    Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $_.TaskName -match 'claude' -or ((@($_.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ') -match 'claude'
    }
})
foreach ($t in $claudeTasks) {
    $atLogon = @($t.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count -gt 0
    $autostart += [pscustomobject]@{
        Source = 'Scheduled task'; Detail = "$($t.TaskPath)$($t.TaskName)"
        Status = '{0}{1}' -f $t.State, $(if ($atLogon) { ', runs at logon' } else { ', not a logon trigger' })
        Active = ($atLogon -and "$($t.State)" -ne 'Disabled')
    }
}
$claudeAutostarts = @($autostart | Where-Object { $_.Active }).Count -gt 0
$claudeDisabledEntry = @($autostart | Where-Object { -not $_.Active }).Count -gt 0

$claudeProcs   = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude' })
$claudeRunning = $claudeProcs.Count -gt 0
$rcProcs = @(Invoke-Safe {
    Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { "$($_.CommandLine)" -match 'claude' -and "$($_.CommandLine)" -match 'remote-control' }
})
$rcText = if ($rcProcs.Count) {
    'a "claude remote-control" process is running (PID {0})' -f (($rcProcs | ForEach-Object { $_.ProcessId }) -join ', ')
} else {
    'no "claude remote-control" process found; Remote Control inside Claude Desktop is not visible from PowerShell, so confirm it from your phone'
}

# =============================================================================
# Step 4: report
# =============================================================================
Write-Host 'Step 4: writing the report...'

# --- Summary lines (shown in the console and at the top of the report) --------
$sum = New-Object System.Collections.Generic.List[string]
$slotText = if ($slotsTotal) { "$slotsUsed of $slotsTotal slots" } else { "$slotsUsed module(s)" }
$sum.Add(('RAM: {0} GB in {1} - {2}' -f (Format-Value $ramGB), $slotText, $(if ($ramOk) { 'fine' } else { 'under 8 GB, tight for an always-on box' })))
$sum.Add('Disk: ' + $(if ($diskRows.Count) { ($diskRows | ForEach-Object { '{0} {1} GB ({2})' -f $_.Type, (Format-Value $_.SizeGB '?'), $_.Model }) -join '; ' } else { 'unreadable' }))
$sum.Add('Free disk: ' + $(if ($volRows.Count) { ($volRows | ForEach-Object { '{0} {1} GB free of {2} GB' -f $_.Drive, (Format-Value $_.FreeGB '?'), (Format-Value $_.SizeGB '?') }) -join '; ' } else { 'unreadable' }))
if (-not $batteryPresent) {
    $sum.Add('Battery: none detected')
} else {
    $health = if ($null -ne $batteryHealthPct) { '{0}% health ({1}% wear)' -f $batteryHealthPct, $batteryWearPct } else { 'health unreadable' }
    $sum.Add(('Battery: {0}, {1}% charged, {2}' -f $health, (Format-Value $batteryCharge '?'), (Format-Value $batteryState 'state unknown')))
}
$sum.Add(('Windows: {0} {1}, build {2}; last update {3}' -f $winName, $winVersion, $winBuild, $lastUpdateText))
if ($isWin10) {
    $sum.Add('Windows 10: check Settings > Windows Update for the ESU offer (consumer ESU was scheduled to end 13 Oct 2026; if no offer, plan a move to Windows 11).')
}
if ($AuditOnly) {
    $sleepLine = 'Sleep: not changed (-AuditOnly); now AC {0} / battery {1}, lid {2}' -f (Format-Timeout $current.STANDBYIDLE.AC), (Format-Timeout $current.STANDBYIDLE.DC), (Format-Lid $current.LIDACTION.AC)
} elseif (-not $backupWritten) {
    $sleepLine = 'Sleep: NOT changed - the backup file could not be written'
} elseif ($adminRefusal) {
    $sleepLine = 'Sleep: STOPPED - "{0}" was refused for lack of admin rights' -f $adminRefusal.Command
} elseif ($sleepOff -and $hibernateOff -and $lidNothing) {
    $sleepLine = 'Sleep: now off on AC and battery, hibernate off, lid close does nothing'
} else {
    $sleepLine = 'Sleep: partly applied - sleep {0}/{1}, hibernate {2}/{3}, lid {4}/{5} (AC/battery)' -f
        (Format-Timeout $current.STANDBYIDLE.AC), (Format-Timeout $current.STANDBYIDLE.DC),
        (Format-Timeout $current.HIBERNATEIDLE.AC), (Format-Timeout $current.HIBERNATEIDLE.DC),
        (Format-Lid $current.LIDACTION.AC), (Format-Lid $current.LIDACTION.DC)
}
$sum.Add($sleepLine)
if ($claudeAutostarts) {
    $sum.Add('Claude auto-start: yes (' + ((@($autostart | Where-Object { $_.Active }) | ForEach-Object { $_.Source }) -join ', ') + ')' + $(if ($claudeRunning) { ', running now' } else { ', not running now' }))
} else {
    $sum.Add('Claude auto-start: no' + $(if ($claudeDisabledEntry) { ' (an entry exists but is disabled)' } else { '' }) + $(if ($claudeRunning) { '; running now' } else { '; not running now' }))
}
$sum.Add('Remote Control: ' + $rcText)

$human = New-Object System.Collections.Generic.List[string]
if ($adminRefusal) { $human.Add('rerun this script from PowerShell opened with "Run as administrator" to finish: ' + (@($adminRefusal.Command) + $notRun -join '; ')) }
if ($otherFailures.Count) { $human.Add('look at the failed powercfg commands in ' + $AuditPath) }
if (-not $claudeAutostarts) {
    if ($claudeDisabledEntry) { $human.Add('re-enable Claude in Task Manager > Startup apps') }
    else { $human.Add('turn on start-at-login for Claude Desktop in its settings (this script does not change it)') }
}
if (-not $rcProcs.Count) { $human.Add('confirm from your phone that Remote Control reaches this laptop') }
if ($batteryPresent) { $human.Add('for 24/7 charging, turn on the HP battery charge limit in BIOS (F10, Adaptive Battery Optimizer / Battery Care)') }
$human.Add('after any restart (e.g. Windows Update), someone must sign in before Claude starts, since auto-login stays off')
$sum.Add('Needs you at the keyboard: ' + ($human -join '; ') + '.')

# --- Markdown report ---------------------------------------------------------
$md = New-Object System.Collections.Generic.List[string]
$md.Add('# HP always-on audit')
$md.Add('')
$md.Add(('Run {0:yyyy-MM-dd HH:mm} on {1} as {2}{3}{4}.' -f $Now, $env:COMPUTERNAME, $env:USERNAME,
         $(if ($isAdmin) { ' (administrator)' } else { ' (not elevated)' }), $(if ($AuditOnly) { ', audit only' } else { '' })))
$md.Add('')
$md.Add('## Summary')
$md.Add('')
foreach ($line in $sum) { $md.Add("- $line") }
$md.Add('')

$md.Add('## Step 1: hardware and Windows')
$md.Add('')
$md.Add('| Item | Value |')
$md.Add('| --- | --- |')
$md.Add(('| RAM | {0} GB installed, {1} |' -f (Format-Value $ramGB), $slotText))
$md.Add(('| CPU | {0} |' -f (Esc $cpuText)))
$md.Add(('| GPU | {0} |' -f (Esc ($(if ($gpuLines) { $gpuLines -join '; ' } else { 'unreadable' })))))
$md.Add(('| Battery | {0} |' -f (Esc $(if ($batteryPresent) { '{0}% charged, {1}' -f (Format-Value $batteryCharge '?'), (Format-Value $batteryState 'state unknown') } else { 'none detected' }))))
if ($batteryPresent) {
    $md.Add(('| Battery capacity | design {0} mWh, full charge {1} mWh, health {2}, wear {3} (source: {4}) |' -f
             (Format-Value $designCap), (Format-Value $fullCap),
             $(if ($null -ne $batteryHealthPct) { "$batteryHealthPct%" } else { 'unreadable' }),
             $(if ($null -ne $batteryWearPct) { "$batteryWearPct%" } else { 'unreadable' }),
             (Format-Value $batterySource 'none')))
}
$md.Add(('| Windows | {0}, version {1}, build {2} |' -f (Esc $winName), $winVersion, $winBuild))
$md.Add(('| Last installed update | {0}: {1} |' -f $lastUpdateText, (Esc (Format-Value $lastUpdateTitle 'unknown'))))
$md.Add(('| Last boot | {0} (up {1}) |' -f (Format-Date $lastBoot), $uptimeText))
$md.Add(('| Network | {0} |' -f (Esc $netType)))
$md.Add('')
if ($memModules.Count) {
    $md.Add('### Memory modules')
    $md.Add('')
    $md.Add('| Slot | Size | Speed | Maker |')
    $md.Add('| --- | --- | --- | --- |')
    foreach ($m in $memModules) {
        $md.Add(('| {0} | {1} GB | {2} MHz | {3} |' -f (Esc ("$($m.DeviceLocator)".Trim())), (ConvertTo-GB $m.Capacity), (Format-Value $m.Speed '?'), (Esc ("$($m.Manufacturer)".Trim()))))
    }
    $md.Add('')
}
$md.Add('### Disks')
$md.Add('')
$md.Add('| Model | Type | Bus | Size GB | Free GB | Volumes | Health |')
$md.Add('| --- | --- | --- | --- | --- | --- | --- |')
foreach ($d in $diskRows) {
    $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f (Esc $d.Model), $d.Type, $d.Bus, (Format-Value $d.SizeGB '?'), (Format-Value $d.FreeGB '-'), (Format-Value $d.Volumes '-'), (Format-Value $d.Health '?')))
}
$md.Add('')
$md.Add('| Volume | Label | Size GB | Free GB | Free % |')
$md.Add('| --- | --- | --- | --- | --- |')
foreach ($v in $volRows) {
    $md.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $v.Drive, (Esc $v.Label), (Format-Value $v.SizeGB '?'), (Format-Value $v.FreeGB '?'), (Format-Value $v.FreePct '?')))
}
$md.Add('')
$md.Add('### Network adapters that are up')
$md.Add('')
$md.Add('| Name | Type | Speed | Internet route | Adapter |')
$md.Add('| --- | --- | --- | --- | --- |')
foreach ($n in $netRows) {
    $md.Add(('| {0} | {1} | {2} | {3} | {4} |' -f (Esc $n.Name), (Esc $n.Kind), (Esc $n.Speed), $(if ($n.Internet) { 'yes' } else { 'no' }), (Esc $n.Description)))
}
$md.Add('')

$md.Add('## Step 2: power settings')
$md.Add('')
$md.Add(('Active plan: {0} {1}' -f (Format-Value $schemeName 'unknown'), (Format-Value $schemeGuid '')))
$md.Add('')
$md.Add('| Setting | Before (AC / battery) | Now (AC / battery) |')
$md.Add('| --- | --- | --- |')
$labels = [ordered]@{ STANDBYIDLE = 'Sleep after'; HIBERNATEIDLE = 'Hibernate after'; LIDACTION = 'Lid close' }
foreach ($k in $labels.Keys) {
    $md.Add(('| {0} | {1} / {2} | {3} / {4} |' -f $labels[$k],
             (Format-Setting $k $before[$k].AC), (Format-Setting $k $before[$k].DC),
             (Format-Setting $k $current[$k].AC), (Format-Setting $k $current[$k].DC)))
}
$md.Add('')
if ($AuditOnly) {
    $md.Add('Skipped (-AuditOnly): nothing was backed up or changed.')
} elseif (-not $backupWritten) {
    $md.Add('The backup could not be written, so no settings were changed.')
} else {
    $md.Add(('Backup of the earlier values, with restore commands: {0}' -f $backupWritten))
    $md.Add('')
    $md.Add('| Command | Result |')
    $md.Add('| --- | --- |')
    foreach ($r in $applyResults) {
        $res = if ($r.Ok) { 'ok' } elseif ($adminRefusal -and $r.Command -eq $adminRefusal.Command) { 'REFUSED (admin rights): ' + $r.Output } else { "failed (exit $($r.ExitCode)): $($r.Output)" }
        $md.Add(('| {0} | {1} |' -f $r.Command, (Esc $res)))
    }
    foreach ($c in $notRun) { $md.Add(('| {0} | not run (stopped after the refusal) |' -f $c)) }
}
$md.Add('')
$md.Add('Sleep states this machine supports (powercfg /a):')
$md.Add('')
$md.Add('```')
$md.Add($sleepStatesRaw)
$md.Add('```')
$md.Add('')

$md.Add('## Step 3: Claude at login and Remote Control')
$md.Add('')
if ($autostart.Count) {
    $md.Add('| Where | Entry | Status |')
    $md.Add('| --- | --- | --- |')
    foreach ($a in $autostart) { $md.Add(('| {0} | {1} | {2} |' -f (Esc $a.Source), (Esc $a.Detail), (Esc $a.Status))) }
} else {
    $md.Add('No Claude entry in Win32_StartupCommand (Run keys and Startup folders), the Startup folders, a Store app startup task or a scheduled task.')
}
$md.Add('')
$md.Add(('Claude running now: {0}' -f $(if ($claudeRunning) { 'yes (' + ((@($claudeProcs | Select-Object -ExpandProperty ProcessName -Unique)) -join ', ') + ')' } else { 'no' })))
$md.Add('')
$userStartupNames   = @($startupFolderItems | Where-Object { $_.FullName -like "$startupFolder\*" } | ForEach-Object { $_.Name })
$commonStartupNames = @($startupFolderItems | Where-Object { $_.FullName -like "$commonStartupFolder\*" } | ForEach-Object { $_.Name })
$md.Add(('Startup folder, shell:startup ({0}): {1}' -f $startupFolder, $(if ($userStartupNames.Count) { $userStartupNames -join ', ' } else { 'empty' })))
$md.Add(('All-users Startup folder ({0}): {1}' -f $commonStartupFolder, $(if ($commonStartupNames.Count) { $commonStartupNames -join ', ' } else { 'empty' })))
$md.Add('')
$md.Add('Other programs that start at login (Win32_StartupCommand):')
$md.Add('')
if ($startupCommands.Count) { foreach ($sc in $startupCommands) { $md.Add(('- {0} ({1}): {2}' -f $sc.Name, $sc.Location, $sc.Command)) } } else { $md.Add('- none found') }
$md.Add('')
$md.Add('Remote Control: ' + $rcText + '.')
$md.Add('')

$md.Add('## Needs a human at the keyboard')
$md.Add('')
foreach ($h in $human) { $md.Add("- $h") }
if ($isWin10) { $md.Add('- Windows 10: check Settings > Windows Update for the ESU offer.') }
$md.Add('')

$filesWritten.Add($AuditPath)
$md.Add('## Files this script wrote')
$md.Add('')
foreach ($f in $filesWritten) { $md.Add("- $f") }

try {
    $md | Set-Content -LiteralPath $AuditPath -Encoding UTF8 -ErrorAction Stop
} catch {
    Write-Warning "Could not write $AuditPath ($($_.Exception.Message))"
}

# --- Console summary -----------------------------------------------------------
Write-Host ''
foreach ($line in $sum) { Write-Host $line }
Write-Host "Full report: $AuditPath"

if ($adminRefusal) { exit 2 }
