# Registry paths and policy names
$policyPath = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
$policyName = "NoClose"
$lockScreenPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization"

# OPNOVA Logo & Tagline
Write-Host ""
Write-Host "    ●✶ OPNOVA" -ForegroundColor Cyan
Write-Host "   Take rework out of work" -ForegroundColor Gray
Write-Host ""

function Disable-All {
    Write-Host "`n[Disabling All Settings]"

    Write-Host "-> Disabling Power Control..."
    Set-ItemProperty -Path $policyPath -Name $policyName -Value 1 -Type DWord
    Write-Host "✓ Power Control disabled."

    Write-Host "-> Disabling Hibernation..."
    powercfg -hibernate off
    Write-Host "✓ Hibernation disabled."

    Write-Host "-> Disabling Sleep (AC/DC)..."
    powercfg -change -standby-timeout-ac 0
    powercfg -change -standby-timeout-dc 0
    Write-Host "✓ Sleep disabled for both AC and DC."

    Write-Host "-> Disabling Lock Screen..."
    if (!(Test-Path $lockScreenPath)) {
        New-Item -Path $lockScreenPath -Force | Out-Null
        Write-Host "✓ Lock Screen policy folder created."
    }
    Set-ItemProperty -Path $lockScreenPath -Name "NoLockScreen" -Value 1 -Type DWord
    Write-Host "✓ Lock Screen disabled."

    Write-Host "-> Updating system policies..."
    gpupdate /force
    Write-Host "✓ Policies updated successfully."

    Write-Host "`n✔ All features have been successfully disabled!"
}

function Restore-All {
    Write-Host "`n[Restoring Default Settings]"

    Write-Host "-> Restoring Power Control..."
    Remove-ItemProperty -Path $policyPath -Name $policyName -ErrorAction SilentlyContinue
    Write-Host "✓ Power Control restored."

    Write-Host "-> Enabling Hibernation..."
    powercfg -hibernate on
    Write-Host "✓ Hibernation enabled."

    Write-Host "-> Restoring Sleep (15min AC / 5min DC)..."
    powercfg -change -standby-timeout-ac 15
    powercfg -change -standby-timeout-dc 5
    Write-Host "✓ Sleep restored with default timers."

    Write-Host "-> Enabling Lock Screen..."
    Remove-ItemProperty -Path $lockScreenPath -Name "NoLockScreen" -ErrorAction SilentlyContinue
    Write-Host "✓ Lock Screen re-enabled."

    Write-Host "-> Updating system policies..."
    gpupdate /force
    Write-Host "✓ Policies updated successfully."

    Write-Host "`n✔ All settings have been successfully restored to defaults!"
}

# Main Menu
Write-Host "`n========= MAIN MENU ========="
Write-Host "1. Disable All    - Prevent shutdown, sleep, hibernate, and lock screen"
Write-Host "2. Restore All    - Re-enable all system defaults"
$choice = Read-Host "Enter your choice (1 or 2)"

switch ($choice) {
    "1" { Disable-All }
    "2" { Restore-All }
    default { Write-Host "Invalid option. Exiting script." }
}

