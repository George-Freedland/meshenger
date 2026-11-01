# Checks whether this PC's Bluetooth can hear nearby devices at all, with no
# Meshenger code involved. Keep Meshenger open on the other device, close it
# on this PC, then run:
#
#   powershell -ExecutionPolicy Bypass -File tool\windows_ble_check.ps1
#
# Add -Seconds 30 to listen for longer.
param([int]$Seconds = 15)

# The Windows Bluetooth API is only reachable from Windows PowerShell 5.1.
if ($PSVersionTable.PSEdition -eq 'Core') {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Seconds $Seconds
    exit $LASTEXITCODE
}

$meshengerService = [guid]'4d455348-454e-4745-5242-4c4530303031'

$running = @(Get-Process meshenger -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Host "Meshenger is running on this PC (process $($running.Id -join ', ')). Fine for comparing; for the baseline, run this with it closed." -ForegroundColor Yellow
}

Write-Host 'Bluetooth adapter:'
try {
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -Filter "DeviceClass='BLUETOOTH'" -ErrorAction Stop)
    $adapters = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction Stop |
        Where-Object { $_.InstanceId -match '^(USB|PCI|ACPI|SD|UART)\\' })
    if ($adapters.Count -eq 0) {
        Write-Host '  none found' -ForegroundColor Red
    }
    foreach ($adapter in $adapters) {
        $driver = $drivers | Where-Object { $_.DeviceID -eq $adapter.InstanceId } | Select-Object -First 1
        $date = if ($driver.DriverDate) { $driver.DriverDate.ToString('yyyy-MM-dd') } else { '?' }
        Write-Host ('  {0} ({1}), driver {2} from {3}' -f $adapter.FriendlyName, $adapter.Status, $driver.DriverVersion, $date)
    }
} catch {
    Write-Host "  couldn't read it: $($_.Exception.Message)"
}

$status = 'not started'
$received = @()
$stopped = @()
Write-Host ''
Write-Host "Listening for Bluetooth LE advertisements for $Seconds s..."
try {
    $null = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth.Advertisement, ContentType = WindowsRuntime]
    $watcher = New-Object Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher
    $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active
    $null = Register-ObjectEvent -InputObject $watcher -EventName Received -SourceIdentifier MeshengerBleReceived
    $null = Register-ObjectEvent -InputObject $watcher -EventName Stopped -SourceIdentifier MeshengerBleStopped
    $watcher.Start()
    Start-Sleep -Seconds $Seconds
    $status = $watcher.Status
    $watcher.Stop()
    Start-Sleep -Milliseconds 500
    $received = @(Get-Event -SourceIdentifier MeshengerBleReceived -ErrorAction SilentlyContinue)
    $stopped = @(Get-Event -SourceIdentifier MeshengerBleStopped -ErrorAction SilentlyContinue)
} catch {
    Write-Host "  the scan failed: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    foreach ($id in 'MeshengerBleReceived', 'MeshengerBleStopped') {
        try {
            Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
            Remove-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
        } catch {}
    }
}

# PowerShell only fills SourceEventArgs for .NET EventArgs; Windows' own
# event arguments arrive as the second of SourceArgs.
$devices = @{}
foreach ($item in $received) {
    $adv = $item.SourceArgs[1]
    $address = '{0:X12}' -f $adv.BluetoothAddress
    $device = $devices[$address]
    if ($null -eq $device) {
        $device = [pscustomobject]@{ Address = $address; Name = ''; Rssi = -127; Heard = 0; Meshenger = $false }
        $devices[$address] = $device
    }
    $device.Heard++
    if ($adv.RawSignalStrengthInDBm -gt $device.Rssi) { $device.Rssi = $adv.RawSignalStrengthInDBm }
    $name = $adv.Advertisement.LocalName
    if ($name) { $device.Name = $name }
    if ($name -eq 'MSH' -or @($adv.Advertisement.ServiceUuids) -contains $meshengerService) {
        $device.Meshenger = $true
    }
}

Write-Host ('Heard {0} advertisements from {1} devices (scan status at the end: {2}).' -f $received.Count, $devices.Count, $status)
foreach ($item in $stopped) {
    $reason = "$($item.SourceArgs[1].Error)"
    if ($reason -ne 'Success') {
        Write-Host "Windows stopped the scan: $reason" -ForegroundColor Yellow
    }
}
$devices.Values | Sort-Object Rssi -Descending | Select-Object -First 20 | ForEach-Object {
    $tag = if ($_.Meshenger) { '  <- Meshenger' } else { '' }
    Write-Host ('  {0}  {1,4} dBm  heard {2,3}x  {3}{4}' -f $_.Address, $_.Rssi, $_.Heard, $_.Name, $tag)
}

Write-Host ''
if ($received.Count -eq 0) {
    Write-Host "This PC's Bluetooth heard nothing at all, with no app involved, so the problem is Windows or its Bluetooth driver, not Meshenger." -ForegroundColor Red
    Write-Host 'Try these, running this check again after each one:'
    Write-Host '  1. Turn off Mobile hotspot, and disconnect any Bluetooth headphones or speakers.'
    Write-Host '  2. Start > Power > Restart. Use Restart, not Shut down: with Fast Startup on, Shut down does not reset the Bluetooth chip.'
    Write-Host '  3. Device Manager > Bluetooth > your adapter > Uninstall device, then Restart. Windows reinstalls the driver.'
    Write-Host "  4. Install the newest Bluetooth driver from the laptop maker's support site."
} elseif (@($devices.Values | Where-Object { $_.Meshenger }).Count -eq 0) {
    Write-Host 'Bluetooth works, but no Meshenger device was heard. Is Meshenger open on the other device?' -ForegroundColor Yellow
} else {
    Write-Host 'Bluetooth works and a Meshenger device is in range. If Meshenger on this PC still finds nothing, run it and send its log.' -ForegroundColor Green
}
