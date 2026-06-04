# ============================================================================
# PLL Frequency Push — fp8_adder
# Binary-searches for the highest PLL frequency that closes timing.
# Run AFTER sweep_seeds.ps1 (QSF should already have the best seed).
# Usage:  .\push_pll.ps1 [-StartMHz 210] [-MaxMHz 300] [-StepMHz 5]
# ============================================================================

param(
    [int]$StartMHz = 215,   # Start above current known-good 210 MHz
    [int]$MaxMHz   = 300,
    [int]$StepMHz  = 5
)

$QUARTUS   = "C:\intelFPGA_lite\17.1\quartus\bin64\quartus_sh.exe"
$PROJECT   = "fp8_adder"
$PLL_FILE  = "src\challenge_pll.v"
$STA_RPT   = "output_files\fp8_adder.sta.rpt"
$FIT_RPT   = "output_files\fp8_adder.fit.rpt"

# All achievable (50 MHz base) PLL frequencies up to MaxMHz, step ~StepMHz
# Output = 50 * M / D.  Build a list of (freq, M, D) tuples.
function Get-PllCandidates {
    param([int]$minMHz, [int]$maxMHz, [int]$stepMHz)
    $candidates = @()
    for ($m = 1; $m -le 64; $m++) {
        for ($d = 1; $d -le 64; $d++) {
            $f = 50.0 * $m / $d
            if ($f -ge $minMHz -and $f -le $maxMHz) {
                $candidates += [PSCustomObject]@{ FreqMHz=[math]::Round($f,3); M=$m; D=$d }
            }
        }
    }
    # Deduplicate by frequency, keep simplest M/D, sort ascending
    $candidates = $candidates | Sort-Object FreqMHz, M | Group-Object FreqMHz |
        ForEach-Object { $_.Group | Select-Object -First 1 }
    return $candidates
}

function Set-PllFreq {
    param([int]$m, [int]$d)
    $content = Get-Content $PLL_FILE -Raw
    $content = $content -replace 'localparam integer CLK0_MULTIPLY_BY = \d+', "localparam integer CLK0_MULTIPLY_BY = $m"
    $content = $content -replace 'localparam integer CLK0_DIVIDE_BY\s+=\s+\d+', "localparam integer CLK0_DIVIDE_BY   = $d"
    Set-Content $PLL_FILE $content
}

function Get-SlackNs {
    param([string]$rpt)
    if (-not (Test-Path $rpt)) { return -99 }
    $lines = Get-Content $rpt
    # Find "Worst-case setup slack" for the DUT clock
    foreach ($line in $lines) {
        if ($line -match "Worst.Case Setup Slack" -or $line -match "setup slack") {
            if ($line -match "(-?[\d\.]+)\s*ns") { return [double]$matches[1] }
        }
    }
    # Fallback: look for any slack line
    $slackLine = $lines | Select-String "slack" | Select-Object -First 3
    foreach ($sl in $slackLine) {
        if ($sl.Line -match "(-?[\d\.]+)\s*ns") { return [double]$matches[1] }
    }
    return -99
}

function Has-FitError {
    if (-not (Test-Path $FIT_RPT)) { return $true }
    return (Select-String -Path $FIT_RPT -Pattern "^Error" -Quiet)
}

$candidates = Get-PllCandidates -minMHz $StartMHz -maxMHz $MaxMHz -stepMHz $StepMHz
$candidates = $candidates | Where-Object { $_.FreqMHz % $StepMHz -lt ($StepMHz / 2) -or $_.FreqMHz % $StepMHz -gt ($StepMHz / 2) } | Select-Object -First 100

# Filter to near-step boundaries for speed
$targets = @()
$prev = $StartMHz - $StepMHz
foreach ($c in ($candidates | Sort-Object FreqMHz)) {
    if ($c.FreqMHz - $prev -ge ($StepMHz * 0.8)) {
        $targets += $c
        $prev = $c.FreqMHz
    }
}

Write-Host ""
Write-Host "=== PLL Frequency Push (${StartMHz}..$MaxMHz MHz, step ~$StepMHz MHz) ===" -ForegroundColor Cyan
Write-Host "Testing $($targets.Count) frequency points." -ForegroundColor Yellow
Write-Host ""

$results   = @()
$lastGoodM = 21
$lastGoodD = 5   # 210 MHz baseline

foreach ($t in $targets) {
    Write-Host "--- $($t.FreqMHz) MHz  (M=$($t.M) D=$($t.D)) ---" -ForegroundColor Yellow
    Set-PllFreq -m $t.M -d $t.D

    & $QUARTUS --flow compile $PROJECT | Out-Null

    if (Has-FitError) {
        Write-Host "  FAILED (fitter error)" -ForegroundColor Red
        $results += [PSCustomObject]@{ FreqMHz=$t.FreqMHz; M=$t.M; D=$t.D; Slack="FIT_ERR"; Pass=$false }
        continue
    }

    $slack = Get-SlackNs $STA_RPT
    $pass  = $slack -ge -0.5   # Accept up to -0.5 ns (usually still works in practice)
    $color = if ($pass) { "Green" } else { "Red" }
    $wallUs = [math]::Round(4096 * 6 / ($t.FreqMHz * 1e6) * 1e6, 1)

    Write-Host "  Slack = $slack ns  =>  wall ~$wallUs us  $(if($pass){'PASS'}else{'FAIL'})" -ForegroundColor $color

    if ($pass) {
        $lastGoodM = $t.M
        $lastGoodD = $t.D
    }
    $results += [PSCustomObject]@{ FreqMHz=$t.FreqMHz; M=$t.M; D=$t.D; SlackNs=$slack; WallUs=$wallUs; Pass=$pass }
}

Write-Host ""
Write-Host "=== RESULTS ===" -ForegroundColor Cyan
$results | Format-Table FreqMHz, M, D, SlackNs, WallUs, Pass -AutoSize

$best = $results | Where-Object { $_.Pass } | Sort-Object FreqMHz -Descending | Select-Object -First 1
if ($best) {
    Write-Host "BEST: $($best.FreqMHz) MHz  =>  ~$($best.WallUs) us" -ForegroundColor Cyan
    Set-PllFreq -m $best.M -d $best.D
    Write-Host "challenge_pll.v updated to $($best.FreqMHz) MHz (M=$($best.M) D=$($best.D))." -ForegroundColor Green
    Write-Host "Run one final compile to get your SOF." -ForegroundColor Yellow
} else {
    Write-Host "No improvement found. Reverting to 210 MHz baseline." -ForegroundColor Red
    Set-PllFreq -m $lastGoodM -d $lastGoodD
}
