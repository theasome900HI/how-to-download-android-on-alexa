param()

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$FASTBOOT = Join-Path $ScriptDir "bin\fastboot.exe"

$DeviceMap = @{
    "CRONOS"   = "Echo Show 5 2nd Generation - 2021"
    "CROWN"    = "Echo Show 8 1st Generation - 2019"
    "CHECKERS" = "Echo Show 5 1st Generation - 2019"
}

$SupportedDevices = @("CHECKERS")

function Run-Fastboot($arguments, $timeoutSeconds = 0) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FASTBOOT
    $psi.Arguments = $arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null

    if ($timeoutSeconds -gt 0) {
        $exited = $process.WaitForExit($timeoutSeconds * 1000)
        if (-not $exited) {
            $process.Kill() | Out-Null
            return @{ Output = ""; TimedOut = $true }
        }
    } else {
        $process.WaitForExit()
    }

    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    return @{ Output = $stdout + $stderr; TimedOut = $false }
}

function Check-Device {
    Write-Host "Make sure device is in fastboot mode and connected!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To enter fastboot mode:" -ForegroundColor Yellow
    Write-Host "  1. Power off the device" -ForegroundColor Yellow
    Write-Host "  2. Hold Volume Down + Volume Up + Mute buttons simultaneously" -ForegroundColor Yellow
    Write-Host "  3. Keep holding until the fastboot screen appears" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "If the device is already in fastboot mode, just connect it via USB." -ForegroundColor Yellow
    Write-Host ""

    do {
        $result = Run-Fastboot "getvar product"
        $output = $result.Output

        if ($output -match "waiting for any device" -or $output -match "< waiting for any device >") {
            Start-Sleep -Seconds 1
            continue
        }

        $productLine = $output | Select-String "product:"
        if (-not $productLine) {
            Start-Sleep -Seconds 1
            continue
        }

        $product = ($productLine.Line -split '\s+')[1]

        if ($DeviceMap.ContainsKey($product)) {
            $friendlyName = $DeviceMap[$product]
        } else {
            $friendlyName = "Unknown device"
        }

        Write-Host "Detected: $product - $friendlyName" -ForegroundColor Cyan

        if ($product -notin $SupportedDevices) {
            Write-Host ""
            if ($DeviceMap.ContainsKey($product)) {
                Write-Host "This device ($friendlyName) is not yet supported by this script." -ForegroundColor Red
            } else {
                Write-Host "Unknown device: $product" -ForegroundColor Red
            }
            Write-Host ""
            Write-Host "Currently supported devices:" -ForegroundColor Yellow
            foreach ($supported in $SupportedDevices) {
                Write-Host "  - $supported ($($DeviceMap[$supported]))" -ForegroundColor Yellow
            }
            exit 1
        }

        return
    } while ($true)
}

function Detect-Image {
    $result = Run-Fastboot "getvar lk_build_desc"
    $buildLine = $result.Output | Select-String "lk_build_desc:"

    if ($buildLine) {
        $buildDesc = ($buildLine.Line -split '\s+', 2)[1].Trim()
        $buildDesc = ($buildDesc -split '\r?\n')[0].Trim()
        Write-Host "LK build: $buildDesc" -ForegroundColor Cyan
    }

    switch ($buildDesc) {
        "3c87b1c-20220128_020937" {
            $script:FULL_IMAGE = Join-Path $ScriptDir "bin\fastbrick-20220128.img"
        }
        "44072a3-20240709_170103" {
            $script:FULL_IMAGE = Join-Path $ScriptDir "bin\fastbrick-20240709.img"
        }
        default {
            $script:FULL_IMAGE = Join-Path $ScriptDir "bin\fastbrick.img"
        }
    }

    Write-Host "Will use payload: $(Split-Path $script:FULL_IMAGE -Leaf)" -ForegroundColor Cyan

    if (-not (Test-Path $script:FULL_IMAGE)) {
        Write-Host "Error: Payload file not found: $script:FULL_IMAGE" -ForegroundColor Red
        exit 1
    }
}

function Flash-Payload {
    Write-Host "Sending payload, this might take a few attempts..." -ForegroundColor Yellow
    $attempt = 1
    while ($true) {
        $result = Run-Fastboot "flash brick `"$($script:FULL_IMAGE)`"" 8

        if ($result.Output -match "eMMC-RO") {
            Write-Host ""
            Write-Host "eMMC is in permanent read-only mode!" -ForegroundColor Red
            Write-Host ""
            Write-Host "This device's storage has reached the end of its life and has" -ForegroundColor Red
            Write-Host "locked itself read-only. Writes report success but never persist," -ForegroundColor Red
            Write-Host "so the bootloader cannot be unlocked and nothing can be flashed." -ForegroundColor Red
            Write-Host ""

            if ($result.Output -match "boots=(\d+)") {
                $boots = [int]$matches[1]
                Write-Host "For reference, this device has booted $boots times." -ForegroundColor Yellow
                if ($boots -lt 100) {
                    Write-Host "Damn... only $boots boots and the flash already gave out." -ForegroundColor Yellow
                    Write-Host "You must've been seriously unlucky with this one." -ForegroundColor Yellow
                }
                Write-Host ""
            }

            Write-Host "This is a hardware failure - the eMMC chip would need to be" -ForegroundColor Red
            Write-Host "physically replaced. The device was not modified and is safe to" -ForegroundColor Red
            Write-Host "reboot." -ForegroundColor Red
            exit 1
        }

        if ($result.Output -match "Device mismatch") {
            Write-Host ""
            Write-Host "Device mismatch detected!" -ForegroundColor Red
            Write-Host ""
            Write-Host "The payload is not compatible with your device. You may be running" -ForegroundColor Red
            Write-Host "this script on an unsupported device or with the wrong payload." -ForegroundColor Red
            Write-Host ""
            Write-Host "Please verify your device and try again with the correct payload." -ForegroundColor Red
            exit 1
        }

        if ($result.TimedOut) {
            Write-Host "Exploit most likely successful!" -ForegroundColor Green
            return
        }

        Start-Sleep -Seconds 2
        $attempt++
    }
}

Clear-Host

Write-Host @"
                                   _   
                                  | |  
   __ _ _ __ ___   ___  _ __   ___| |_ 
  / _' | '_ ' _ \ / _ \| '_ \ / _ \ __|
 | (_| | | | | | | (_) | | | |  __/ |_  (-fastbrick)
  \__,_|_| |_| |_|\___/|_| |_|\___|\__|
            by k4y0z & r0rt1z2         
                                       
"@ -ForegroundColor DarkMagenta

Check-Device
Detect-Image

Write-Host ""
$confirmation = Read-Host 'Run amonet-fastbrick to unlock the bootloader? (Type "YES" to continue)'

if ($confirmation -eq "YES") {
    Write-Host ""
    Flash-Payload
    Write-Host ""
    Write-Host "Please wait until the process finishes and DO NOT INTERRUPT IT." -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "Aborting." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")