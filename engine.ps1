# Version v6.1 - Engine
# AV1 Converter - Conversie paralelă

param (
    [string]$InputFolder,
    [string]$OutputFolder,
    [string]$FFmpegPath,
    [int]$CRF,
    [bool]$Hibernate,
    [int]$ParallelJobs,
    $LogControl,
    $ProgressControl
)

# Verifică dacă Start-ThreadJob este disponibil
if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
    Write-Error "Start-ThreadJob is not available. Please install the ThreadJob module manually."
    exit
}


# Extensii suportate
$extensions = "*.mp4","*.avi","*.mov","*.wmv","*.flv","*.webm","*.mkv"
$files = Get-ChildItem -Path $InputFolder -Include $extensions -Recurse
$total = $files.Count

$LogControl.SelectionColor = [System.Drawing.Color]::Yellow
$LogControl.AppendText("[INFO] Found $total file(s) to convert.`r`n")
$LogControl.SelectionStart = $LogControl.Text.Length
$LogControl.ScrollToCaret()
$LogControl.SelectionColor = [System.Drawing.ColorTranslator]::FromHtml("#cccccc")

$counter = 0
$failedFiles = @()
$startTime = Get-Date

function Format-Duration($ts) {
    if ($ts.TotalMinutes -ge 1) {
        return "$($ts.Minutes) min : $($ts.Seconds) sec"
    } else {
        return "$($ts.Seconds) sec"
    }
}

$jobs = @()

foreach ($file in $files) {
    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $ParallelJobs) {
        Start-Sleep -Milliseconds 500
    }

    $relativePath = $file.FullName.Substring($InputFolder.Length).TrimStart("\")
    $relativeDir = Split-Path $relativePath -Parent
    $outputDir = Join-Path $OutputFolder $relativeDir
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir | Out-Null
    }

    $newFileName = $file.BaseName + "-av1" + $file.Extension
    $destPath = Join-Path $outputDir $newFileName

    $LogControl.SelectionColor = [System.Drawing.ColorTranslator]::FromHtml("#cccccc")
    $LogControl.AppendText("[>>] Converting: $($file.FullName)`r`n")
    $LogControl.SelectionStart = $LogControl.Text.Length
    $LogControl.ScrollToCaret()

    $job = Start-ThreadJob -ScriptBlock {
		param($ffmpegPath, $filePath, $destPath, $crf)

		$arguments = "-y -i `"$filePath`" -c:v libsvtav1 -crf $crf `"$destPath`""
		$process = Start-Process -FilePath $ffmpegPath -ArgumentList $arguments -NoNewWindow -Wait -PassThru

		$fileName = if ($filePath) { Split-Path $filePath -Leaf } else { "Unknown" }

		return @{ ExitCode = $process.ExitCode; FileName = $fileName }
	} -ArgumentList $FFmpegPath, $file.FullName, $destPath, $CRF


	$global:jobList += $job   # pentru interfață (puls vizual)
	$jobs += $job             # pentru procesare și log	
}

# Așteaptă finalizarea și procesează rezultatele
foreach ($job in $jobs) {
    Wait-Job -Job $job
	$result = Receive-Job -Job $job
	Remove-Job -Job $job

    $counter++
    $ProgressControl.Value = [math]::Round(($counter / $total) * 100)

    if ($result.ExitCode -eq 0) {
        $LogControl.SelectionColor = [System.Drawing.Color]::LightGreen
        $LogControl.AppendText("[OK] SUCCESS: $($result.FileName)`r`n")
    } else {
        $LogControl.SelectionColor = [System.Drawing.Color]::Red
        $LogControl.AppendText("[X] ERROR: $($result.FileName)`r`n")
        $failedFiles += $result.FileName
    }

    $LogControl.SelectionStart = $LogControl.Text.Length
    $LogControl.ScrollToCaret()
}

$endTime = Get-Date
$duration = $endTime - $startTime

# Scriere fișiere eșuate într-un fișier temporar
if ($failedFiles.Count -gt 0) {
    $failedListPath = Join-Path $env:TEMP "av1_failed_files.txt"
    $failedFiles | Set-Content $failedListPath
}

# Finalizare
$LogControl.SelectionColor = [System.Drawing.ColorTranslator]::FromHtml("#cccccc")
$LogControl.AppendText("[END] Conversion complete.`r`n")
$LogControl.SelectionStart = $LogControl.Text.Length
$LogControl.ScrollToCaret()

# Hibernare dacă e bifată
if ($Hibernate) {
    $LogControl.SelectionColor = [System.Drawing.Color]::Yellow
    $LogControl.AppendText("[>>>>] System will hibernate in 10 seconds...`r`n")
    $LogControl.SelectionStart = $LogControl.Text.Length
    $LogControl.ScrollToCaret()
    Start-Sleep -Seconds 10
    & rundll32.exe powrprof.dll,SetSuspendState Hibernate
}
