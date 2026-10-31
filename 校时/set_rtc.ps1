param([ValidatePattern('^COM[0-9]+$')][string]$Port,[switch]$ListPorts)
$ErrorActionPreference='Stop'
try { Add-Type -AssemblyName System.IO.Ports -ErrorAction Stop }
catch { Add-Type -AssemblyName System }
$rtcPorts=[System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
$rtcMap=Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM' -ErrorAction SilentlyContinue
$rtcBluetooth=@($rtcMap.PSObject.Properties | Where-Object {$_.Name -match 'BthModem'} | ForEach-Object {$_.Value})
$rtcPorts=@($rtcPorts | Where-Object {$_ -notin $rtcBluetooth})
if($ListPorts) { Write-Output $rtcPorts; exit 0 }
if(!$Port) {
    if($rtcPorts.Count -eq 0) { throw 'No wired serial port found. Connect the board USB-UART Type-C port to the PC; USB-JTAG alone is insufficient.' }
    Write-Host ('Available ports: '+($rtcPorts -join ', '))
    $Port=Read-Host 'Enter the board USB-UART port (e.g. COM6)'
}
if($Port -notmatch '^COM[0-9]+$') { throw 'Expected COM followed by a port number.' }
if($Port -in $rtcBluetooth) { throw 'That is a Bluetooth virtual port. Select the board USB-UART port.' }
$rtcSerial=[System.IO.Ports.SerialPort]::new($Port,115200,[System.IO.Ports.Parity]::None,8,[System.IO.Ports.StopBits]::One)
$rtcSerial.ReadTimeout=5000; $rtcSerial.WriteTimeout=2000
$rtcSerial.DtrEnable=$false; $rtcSerial.RtsEnable=$false
try {
    $rtcSerial.Open(); $rtcSerial.DiscardInBuffer(); $rtcSerial.DiscardOutBuffer()
    # Always UTC+8 (Beijing), regardless of the PC's configured display zone.
    $rtcNow=[DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
    if($rtcNow.Year -lt 2000 -or $rtcNow.Year -gt 2099) { throw 'RTC tool supports years 2000..2099.' }
    $rtcValues=@($rtcNow.Second,$rtcNow.Minute,$rtcNow.Hour,([int]$rtcNow.DayOfWeek+1),$rtcNow.Day,$rtcNow.Month,($rtcNow.Year-2000))
    $rtcPacket=[byte[]]::new(12)
    [Text.Encoding]::ASCII.GetBytes('RTC1').CopyTo($rtcPacket,0)
    for($rtcIndex=0;$rtcIndex -lt 7;$rtcIndex++) {
        $rtcValue=$rtcValues[$rtcIndex]
        $rtcPacket[4+$rtcIndex]=[byte](([math]::Floor($rtcValue/10)*16)+($rtcValue%10))
    }
    $rtcChecksum=0
    for($rtcIndex=0;$rtcIndex -lt 11;$rtcIndex++) { $rtcChecksum=$rtcChecksum -bxor $rtcPacket[$rtcIndex] }
    $rtcPacket[11]=[byte]$rtcChecksum
    $rtcSerial.Write($rtcPacket,0,$rtcPacket.Length)
    $rtcReply=$rtcSerial.ReadByte()
    switch($rtcReply) {
        75 { Write-Host ('DS3231 accepted the time and returned a valid read: '+$rtcNow.ToString('yyyy-MM-dd HH:mm:ss')+' Beijing time') -ForegroundColor Green }
        69 { throw 'Board returned E: invalid packet/calendar or RTC communication/oscillator failure. Check the four wires and 3.3V pull-ups.' }
        66 { throw 'Board returned B: another calibration is in progress. Wait briefly and retry.' }
        default { throw ('Unexpected board response: '+$rtcReply) }
    }
} catch [System.TimeoutException] {
    throw 'No RTC firmware response. Verify the RTC candidate is loaded, the COM port is USB-UART (not USB-JTAG), and no terminal is using it.'
} finally { if($rtcSerial.IsOpen) { $rtcSerial.Close() }; $rtcSerial.Dispose() }
