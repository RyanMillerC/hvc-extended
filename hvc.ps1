<#
.SYNOPSIS
    hvc - drop-in wrapper for hvc.exe that adds create, delete, and clone.

.DESCRIPTION
    create, delete, clone, and help are handled here with the Hyper-V
    PowerShell module. Every other subcommand (list, start, ssh, scp,
    serial, ...) passes straight through to hvc.exe unchanged.

    Put this folder ahead of C:\Windows\System32 in the SYSTEM PATH so
    `hvc` resolves here. The real tool is always called by full path.

    Run elevated, or as a member of Hyper-V Administrators.

.EXAMPLE
    hvc create rhel9-lab -Iso C:\iso\rhel-9.6-x86_64-dvd.iso -Cpu 4 -Memory 8GB -Disk 60GB -Start
.EXAMPLE
    hvc create web01 -FromVhd D:\images\rhel9-golden.vhdx -Disk 80GB -Start
.EXAMPLE
    hvc clone rhel9-lab rhel9-lab2
.EXAMPLE
    hvc delete rhel9-lab2 -Force
.EXAMPLE
    hvc ssh ryan@rhel9-lab
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AllArgs = @($args)
$script:Hvc     = Join-Path $env:SystemRoot 'System32\hvc.exe'

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

function Write-Usage {
    @'
hvc (wrapper) - hvc.exe plus create, delete, clone

USAGE
  hvc create <name> [options]
  hvc clone  <source> <new-name> [-Start]
  hvc delete <name> [-KeepDisks] [-Force]
  hvc <any hvc subcommand> ...        (passed through to the real hvc.exe)

CREATE OPTIONS
  -Cpu <n>             vCPUs (default 2)
  -Disk <size>         New disk size, or grow a -FromVhd copy (default 40GB)
  -DynamicMemory       Enable dynamic memory
  -FromVhd <path>      Start from a copy of an existing VHD/VHDX (golden image)
  -Generation <1|2>    VM generation (default 2)
  -Iso <path>          Attach ISO and boot from it first
  -Memory <size>       Startup memory (default 4GB)
  -NoSecureBoot        Gen 2: disable Secure Boot
  -Start               Power on after create
  -Switch <name>       vSwitch (default: "Default Switch", or the only switch)
  -Windows             Gen 2: use the MicrosoftWindows Secure Boot template
                       (default is MicrosoftUEFICertificateAuthority for Linux)

CLONE OPTIONS
  -Start              Power on after clone

DELETE OPTIONS
  -Force               Skip the confirmation prompt
  -KeepDisks           Remove the VM but leave its disk files

NOTES
  Clones are byte-identical guests. On Linux, reset /etc/machine-id, SSH host
  keys, and hostname on first boot. For Windows, sysprep the source first.

hvc.exe usage follows.
'@ | Write-Host
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Assert-HyperV {
    if (-not (Get-Command Get-VMHost -ErrorAction SilentlyContinue)) {
        throw 'Hyper-V PowerShell module not found. Enable the Microsoft-Hyper-V-Management-PowerShell feature.'
    }
    try { Get-VMHost | Out-Null }
    catch { throw 'Cannot reach Hyper-V. Run elevated or as a member of Hyper-V Administrators.' }
}

# Manual parser so hvc works the same from cmd.exe (-File passes strings)
# and from PowerShell (which pre-converts 4GB to a number).
function Split-Arguments {
    param([object[]]$Arguments, [string[]]$Switches = @(), [string[]]$Options = @())

    $named      = @{}
    $positional = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $a = [string]$Arguments[$i]
        if ($a -match '^-{1,2}([A-Za-z][\w-]*)$') {
            $key = $Matches[1]
            $sw  = @($Switches | Where-Object { $_ -ieq $key })
            $op  = @($Options  | Where-Object { $_ -ieq $key })
            if ($sw.Count) { $named[$sw[0]] = $true; continue }
            if ($op.Count) {
                if ($i + 1 -ge $Arguments.Count) { throw "Missing value for -$key" }
                $i++
                $named[$op[0]] = [string]$Arguments[$i]
                continue
            }
            throw "Unknown option -$key"
        }
        $positional.Add($a)
    }

    [pscustomobject]@{ Named = $named; Positional = $positional }
}

function ConvertTo-Bytes([string]$Value) {
    if ($Value -match '^\s*(\d+(?:\.\d+)?)\s*(KB|MB|GB|TB)?\s*$') {
        $mult = switch ($Matches[2]) { 'KB' { 1KB } 'MB' { 1MB } 'GB' { 1GB } 'TB' { 1TB } default { 1 } }
        return [int64]([double]$Matches[1] * $mult)
    }
    throw "Invalid size '$Value'. Use values like 512MB, 4GB, 1TB."
}

function Get-HostPaths {
    $h = Get-VMHost
    [pscustomobject]@{ Vm = $h.VirtualMachinePath; Vhd = $h.VirtualHardDiskPath }
}

function Resolve-DefaultSwitch {
    $default = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($default) { return $default.Name }
    $all = @(Get-VMSwitch)
    if ($all.Count -eq 1) { return $all[0].Name }
    if ($all.Count -eq 0) { throw 'No vSwitches exist. Create one with New-VMSwitch, or pass -Switch.' }
    throw "Multiple switches; pass -Switch. Available: $(($all | ForEach-Object Name) -join ', ')"
}

function Get-SingleVM([string]$Name) {
    $vms = @(Get-VM -Name $Name -ErrorAction SilentlyContinue)
    if ($vms.Count -eq 0) { throw "VM '$Name' not found." }
    if ($vms.Count -gt 1) { throw "Multiple VMs named '$Name'. Rename one first (Rename-VM)." }
    $vms[0]
}

function Get-DiskChain([string]$Path) {
    $chain = @()
    while ($Path) {
        $chain += $Path
        try   { $Path = (Get-VHD -Path $Path).ParentPath }
        catch { $Path = $null }
    }
    $chain
}

# The disk that survives a checkpoint merge: first non-.avhdx file in the chain.
function Get-BaseDisk([string]$Path) {
    foreach ($p in (Get-DiskChain $Path)) {
        if ([IO.Path]::GetExtension($p) -ine '.avhdx') { return $p }
    }
    $Path
}

function Set-CommonVMDefaults($Vm) {
    if ((Get-Command Set-VM).Parameters.ContainsKey('AutomaticCheckpointsEnabled')) {
        Set-VM -VM $Vm -AutomaticCheckpointsEnabled $false
    }
    try   { Enable-VMIntegrationService -VM $Vm -Name 'Guest Service Interface' }
    catch { Write-Warning 'Could not enable Guest Service Interface (Copy-VMFile will not work).' }
}

function Show-VM($Vm) {
    Get-VM -Id $Vm.Id | Format-Table -AutoSize Name, State, Generation, ProcessorCount,
        @{ n = 'MemoryGB'; e = { [math]::Round($_.MemoryStartup / 1GB, 1) } },
        @{ n = 'Path';     e = { $_.Path } }
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

function Invoke-Create {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Cpu        = '2',
        [string]$Disk       = '40GB',
        [string]$FromVhd,
        [string]$Generation = '2',
        [string]$Iso,
        [string]$Memory     = '4GB',
        [string]$Switch,
        [switch]$DynamicMemory,
        [switch]$NoSecureBoot,
        [switch]$Start,
        [switch]$Windows
    )

    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "VM '$Name' already exists." }
    if ($Iso -and $FromVhd)                 { throw 'Use -Iso or -FromVhd, not both.' }
    $gen = [int16]$Generation
    if ($gen -notin 1, 2)                   { throw '-Generation must be 1 or 2.' }

    $paths = Get-HostPaths
    if (-not $Switch) { $Switch = Resolve-DefaultSwitch }

    $ext     = if ($FromVhd) { [IO.Path]::GetExtension($FromVhd) } else { '.vhdx' }
    $vhdDir  = Join-Path $paths.Vhd $Name
    $vhdPath = Join-Path $vhdDir "$Name$ext"
    if (Test-Path -LiteralPath $vhdPath) { throw "Disk already exists: $vhdPath" }
    New-Item -ItemType Directory -Path $vhdDir -Force | Out-Null

    if ($FromVhd) {
        $FromVhd = (Resolve-Path -LiteralPath $FromVhd).Path
        Write-Host "Copying $FromVhd"
        Copy-Item -LiteralPath $FromVhd -Destination $vhdPath
        if ($PSBoundParameters.ContainsKey('Disk')) {
            $want = ConvertTo-Bytes $Disk
            if ($want -gt (Get-VHD -Path $vhdPath).Size) {
                Write-Host "Growing disk to $Disk (extend the partition inside the guest)"
                Resize-VHD -Path $vhdPath -SizeBytes $want
            }
        }
    } else {
        New-VHD -Path $vhdPath -SizeBytes (ConvertTo-Bytes $Disk) -Dynamic | Out-Null
    }

    $vm = New-VM -Name $Name -Generation $gen -MemoryStartupBytes (ConvertTo-Bytes $Memory) `
                 -VHDPath $vhdPath -SwitchName $Switch -Path $paths.Vm

    Set-VMProcessor -VM $vm -Count ([int]$Cpu)
    if ($DynamicMemory) { Set-VMMemory -VM $vm -DynamicMemoryEnabled $true }
    Set-CommonVMDefaults $vm

    if ($gen -eq 2) {
        if ($NoSecureBoot) {
            Set-VMFirmware -VM $vm -EnableSecureBoot Off
        } else {
            $tpl = if ($Windows) { 'MicrosoftWindows' } else { 'MicrosoftUEFICertificateAuthority' }
            Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate $tpl
        }
    }

    if ($Iso) {
        $Iso = (Resolve-Path -LiteralPath $Iso).Path
        $dvd = Add-VMDvdDrive -VM $vm -Path $Iso -Passthru
        if ($gen -eq 2) { Set-VMFirmware -VM $vm -FirstBootDevice $dvd }
        # Gen 1 already boots CD first by default.
    }

    if ($Start) { Start-VM -VM $vm }
    Show-VM $vm
}

# ---------------------------------------------------------------------------
# delete
# ---------------------------------------------------------------------------

function Invoke-Delete {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Force,
        [switch]$KeepDisks
    )

    $vm = Get-SingleVM $Name

    # Disks that will remain after any checkpoint merge (base .vhdx, not .avhdx).
    $disks = @(Get-VMHardDiskDrive -VM $vm |
               Where-Object { $_.Path } |
               ForEach-Object { Get-BaseDisk $_.Path })

    if (-not $Force) {
        Write-Host "VM:    $Name ($($vm.State))"
        if (-not $KeepDisks) { $disks | ForEach-Object { Write-Host "Disk:  $_" } }
        $answer = Read-Host 'Type the VM name to confirm'
        if ($answer -cne $Name) { Write-Host 'Aborted.'; return }
    }

    if ($vm.State -ne 'Off') { Stop-VM -VM $vm -TurnOff }

    if (-not $KeepDisks) {
        $snaps = @(Get-VMSnapshot -VM $vm)
        if ($snaps.Count) {
            Write-Host "Removing $($snaps.Count) checkpoint(s) and merging..."
            $snaps | Remove-VMSnapshot
            while ((Get-VM -Id $vm.Id).Status -match 'Merg') { Start-Sleep -Seconds 2 }
        }
    }

    $vmPath = $vm.Path
    Remove-VM -VM $vm -Force
    Write-Host "Removed VM $Name"

    if (-not $KeepDisks) {
        foreach ($d in $disks) {
            if (Test-Path -LiteralPath $d) {
                Remove-Item -LiteralPath $d -Force
                Write-Host "Deleted $d"
            }
            $dir = Split-Path $d -Parent
            if ((Split-Path $dir -Leaf) -ieq $Name -and -not (Get-ChildItem -LiteralPath $dir -Force)) {
                Remove-Item -LiteralPath $dir -Force
            }
        }
    }

    # Clean up the per-VM config folder if it is now empty.
    if ($vmPath -and (Split-Path $vmPath -Leaf) -ieq $Name -and (Test-Path -LiteralPath $vmPath)) {
        if (-not (Get-ChildItem -LiteralPath $vmPath -Recurse -File -Force)) {
            Remove-Item -LiteralPath $vmPath -Recurse -Force
        }
    }
}

# ---------------------------------------------------------------------------
# clone
# ---------------------------------------------------------------------------

function Invoke-Clone {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$NewName,
        [switch]$Start
    )

    if (Get-VM -Name $NewName -ErrorAction SilentlyContinue) { throw "VM '$NewName' already exists." }
    $src    = Get-SingleVM $Source
    $paths  = Get-HostPaths
    $vmDir  = Join-Path $paths.Vm  $NewName
    $vhdDir = Join-Path $paths.Vhd $NewName
    if (Test-Path -LiteralPath $vhdDir) { throw "Disk folder already exists: $vhdDir" }

    $new = New-FullClone $src $NewName $vmDir $vhdDir

    Set-CommonVMDefaults $new

    $static = @(Get-VMNetworkAdapter -VM $new | Where-Object { -not $_.DynamicMacAddressEnabled })
    if ($static.Count) {
        Write-Warning 'Source uses a static MAC. The clone has the same MAC; change it with Set-VMNetworkAdapter -StaticMacAddress.'
    }

    if ($Start) { Start-VM -VM $new }
    Show-VM $new
    Write-Host 'Reminder: reset machine-id, SSH host keys, and hostname in the guest (or sysprep for Windows).'
}

function New-FullClone($Src, [string]$NewName, [string]$VmDir, [string]$VhdDir) {
    $export = Join-Path ([IO.Path]::GetTempPath()) ("hvc-clone-" + [guid]::NewGuid())
    try {
        Write-Host "Exporting $($Src.Name)..."
        Export-VM -VM $Src -Path $export

        $config = Get-ChildItem -LiteralPath $export -Recurse -File -Include *.vmcx, *.xml |
                  Where-Object { $_.DirectoryName -like '*Virtual Machines*' } |
                  Select-Object -First 1
        if (-not $config) { throw 'Export produced no VM configuration file.' }

        Write-Host "Importing as $NewName..."
        $new = Import-VM -Path $config.FullName -Copy -GenerateNewId `
                         -VirtualMachinePath   $VmDir `
                         -VhdDestinationPath   $VhdDir `
                         -SnapshotFilePath     $VmDir `
                         -SmartPagingFilePath  $VmDir
        Rename-VM -VM $new -NewName $NewName
        Get-VM -Id $new.Id
    }
    finally {
        if (Test-Path -LiteralPath $export) { Remove-Item -LiteralPath $export -Recurse -Force }
    }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

try {
    if (-not (Test-Path -LiteralPath $script:Hvc)) { throw "Real hvc.exe not found at $script:Hvc" }
    if ($script:AllArgs.Count -eq 0) { Write-Usage; & $script:Hvc; exit 0 }

    $cmd  = ([string]$script:AllArgs[0]).ToLowerInvariant()
    $rest = @($script:AllArgs | Select-Object -Skip 1)

    switch ($cmd) {
        'create' {
            Assert-HyperV
            $p = Split-Arguments $rest `
                -Switches 'DynamicMemory', 'NoSecureBoot', 'Start', 'Windows' `
                -Options  'Cpu', 'Disk', 'FromVhd', 'Generation', 'Iso', 'Memory', 'Switch'
            if ($p.Positional.Count -ne 1) { throw 'Usage: hvc create <name> [options]' }
            $named = $p.Named
            Invoke-Create -Name $p.Positional[0] @named
        }
        'delete' {
            Assert-HyperV
            $p = Split-Arguments $rest -Switches 'Force', 'KeepDisks'
            if ($p.Positional.Count -ne 1) { throw 'Usage: hvc delete <name> [-KeepDisks] [-Force]' }
            $named = $p.Named
            Invoke-Delete -Name $p.Positional[0] @named
        }
        'clone' {
            Assert-HyperV
            $p = Split-Arguments $rest -Switches 'Start'
            if ($p.Positional.Count -ne 2) { throw 'Usage: hvc clone <source> <new-name> [-Start]' }
            $named = $p.Named
            Invoke-Clone -Source $p.Positional[0] -NewName $p.Positional[1] @named
        }
        { $_ -in 'help', '-h', '--help', '/?' } {
            Write-Usage
            & $script:Hvc
        }
        default {
            & $script:Hvc @script:AllArgs
            exit $LASTEXITCODE
        }
    }
}
catch {
    Write-Host "hvc: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
