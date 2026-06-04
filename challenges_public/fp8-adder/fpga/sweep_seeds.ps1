# ============================================================================
# Seed Sweep — fp8_adder
# Tries seeds 1..N, records Fmax from STA report, prints ranked table.
# Run from the fpga/ project folder.
# Usage:  .\sweep_seeds.ps1 [-MaxSeed 30]
# ============================================================================

param(
    [int]$MaxSeed = 30
)

$QUARTUS = "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe"
$PROJECT = "fp8_adder"
$QSF     = "fp8_adder.qsf"
$STA_RPT = "output_files\fp8_adder.sta.rpt"

# Parse Fmax (slow-corner) from STA report
function Get-Fmax {
    param([string]$rpt)
    if (-not (Test-Path $rpt)) { return $null }
    # Look for the DUT PLL clock Fmax line — format: "X.XXX MHz  (period= Y.YYY ns)"
    $lines = Get-Content $rpt
    foreach ($line in $lines) {
        if ($line -match "user_pll.*clk\[0\]" -or $line -match "dut_clk") {
            # Next non-empty line usually has the Fmax
        }
        # Pattern: "  210.000 MHz  (period = 4.762 ns)" in the Fmax summary table
        if ($line -match "^\s+([\d\.]+)\s+MHz\s+\(period\s*=\s*[\d\.]+\s*ns\)") {
            return [double]$matches[1]
        }
    }
    # Fallback: find any Fmax line for the DUT clock group
    $fmax_lines = $lines | Select-String "Fmax" | Select-Object -First 5
    foreach ($fl in $fmax_lines) {
        if ($fl.Line -match "([\d\.]+)\s*MHz") {
            return [double]$matches[1]
        }
    }
    return $null
}

# Check for compile errors
function Has-Errors {
    param([string]$rpt)
    if (-not (Test-Path $rpt)) { return $true }
    $errors = Select-String -Path $rpt -Pattern "^Error" -Quiet
    return $errors
}

$results = @()

Write-Host ""
Write-Host "=== fp8_adder Seed Sweep (seeds 1..$MaxSeed) ===" -ForegroundColor Cyan
Write-Host "Each compile ~5-10 min. Go get a coffee." -ForegroundColor Yellow
Write-Host ""

for ($seed = 1; $seed -le $MaxSeed; $seed++) {

    # Patch the seed in the QSF
    (Get-Content $QSF) -replace 'set_global_assignment -name SEED \d+', "set_global_assignment -name SEED $seed" |
        Set-Content $QSF

    Write-Host "--- Seed $seed ---" -ForegroundColor Yellow
    $t0 = Get-Date

    # Full compile
    & $QUARTUS --flow compile $PROJECT | Out-Null

    $elapsed = ((Get-Date) - $t0).TotalSeconds

    # Check for errors
    $mapRpt = "output_files\$PROJECT.map.rpt"
    $fitRpt = "output_files\$PROJECT.fit.rpt"

    if ((Has-Errors $mapRpt) -or (Has-Errors $fitRpt)) {
        Write-Host "  FAILED (compile error)" -ForegroundColor Red
        $results += [PSCustomObject]@{ Seed=$seed; Fmax="ERROR"; ElapsedS=[int]$elapsed }
        continue
    }

    $fmax = Get-Fmax $STA_RPT
    if ($fmax -eq $null) { $fmax = 0 }

    $wallUs = if ($fmax -gt 0) { [math]::Round(4096 * 6 / ($fmax * 1e6) * 1e6, 1) } else { 9999 }

    Write-Host "  Fmax = $fmax MHz  =>  wall time ~$wallUs us" -ForegroundColor Green
    $results += [PSCustomObject]@{ Seed=$seed; Fmax=$fmax; WallUs=$wallUs; ElapsedS=[int]$elapsed }
}

Write-Host ""
Write-Host "=== RESULTS (best first) ===" -ForegroundColor Cyan
$results | Sort-Object -Property Fmax -Descending | Format-Table -AutoSize

$best = $results | Where-Object { $_.Fmax -ne "ERROR" } | Sort-Object -Property Fmax -Descending | Select-Object -First 1
if ($best) {
    Write-Host "WINNER: Seed $($best.Seed)  =>  $($best.Fmax) MHz  =>  ~$($best.WallUs) us" -ForegroundColor Cyan

    # Leave QSF set to the best seed
    (Get-Content $QSF) -replace 'set_global_assignment -name SEED \d+', "set_global_assignment -name SEED $($best.Seed)" |
        Set-Content $QSF
    Write-Host "QSF updated to best seed $($best.Seed)." -ForegroundColor Green
}
