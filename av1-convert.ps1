# Version v6.5 
# inca nu merge cancelable hibernate
# AV1 Converter - Fixed heartbeat, accurate final display

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object Windows.Forms.Form
$form.Text = "Av1 Converter - v6.5"
$form.Size = '800,730'
$form.MinimumSize = '800,730'
$form.StartPosition = "CenterScreen"
$form.AllowDrop = $true

$fontMain = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Regular)
$fontBold = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Bold)

$configPath = Join-Path $PSScriptRoot "config.ini"
$config = @{}

# === Variabile globale pentru heartbeat și control conversie ===
$global:conversionActive = $false
$global:stopRequested = $false
$global:currentProgress = 0
$global:totalFiles = 0
$global:hibernateCancelled = $false

# === Funcție pentru citire config.ini ===
function Load-Config {
    if (Test-Path $configPath) {
        $lines = Get-Content $configPath
        foreach ($line in $lines) {
            if ($line -match "^\s*(\w+)\s*=\s*(.+?)\s*$") {
                $config[$matches[1]] = $matches[2]
            }
        }
    }
}

# === Funcție pentru salvare config.ini ===
function Save-Config {
    $content = @(
        "CRF=$($textBoxCRF.Text)"
        "FFmpegPath=$($textBoxFFmpeg.Text)"
        "InputFolder=$($textBoxInput.Text)"
        "OutputFolder=$($textBoxOutput.Text)"
        "ParallelJobs=$($comboParallel.SelectedItem)"
        "DeleteOriginal=$($checkDeleteOriginal.Checked)"
    )
    $content | Set-Content $configPath
}

# === Funcție pentru log thread-safe ===
function Write-LogMessage {
    param($message, $color = "#cccccc")
    
    try {
        $textBoxLog.SelectionColor = [System.Drawing.ColorTranslator]::FromHtml($color)
        $textBoxLog.AppendText("$message`r`n")
        $textBoxLog.SelectionStart = $textBoxLog.Text.Length
        $textBoxLog.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        Write-Host $message
    }
}

# === Funcție pentru update progress ===
function Update-ProgressBar {
    param($current, $total)
    
    try {
        $global:currentProgress = $current
        $global:totalFiles = $total
        if ($total -gt 0) {
            $progressBar.Value = [math]::Min(100, [math]::Round(($current / $total) * 100))
        }
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        # Ignore errors
    }
}

# === Funcție pentru ștergere fișier original ===
function Remove-OriginalFile {
    param($filePath, $fileName)
    
    try {
        Remove-Item -Path $filePath -Force
        Write-LogMessage "    [DEL] Deleted original: $fileName" "Orange"
        return $true
    } catch {
        Write-LogMessage "    [ERR] Failed to delete: $fileName - $($_.Exception.Message)" "Red"
        return $false
    }
}

# === Afișam durata frumos mm : ss ===
function Format-Duration($ts) {
    if ($ts.TotalMinutes -ge 1) {
        return "$($ts.Minutes) min : $($ts.Seconds) sec"
    } else {
        return "$($ts.Seconds) sec"
    }
}

Load-Config

#====================================
# === Afișare controale interfață ===
#====================================

# === Clear Log Button ===
$buttonClearLog = New-Object Windows.Forms.Button
$buttonClearLog.Text = "Clear Log"
$buttonClearLog.Location = '670,220'  # Poziționat lângă eticheta "Conversion Log"
$buttonClearLog.Size = '90,30'
$buttonClearLog.Font = $fontMain
$buttonClearLog.Add_Click({
    $textBoxLog.Clear()
    Write-LogMessage "=== Log cleared ===" "Gray"
})
$form.Controls.Add($buttonClearLog)

# === FFmpeg Output Checkbox ===
$checkFFmpegOutput = New-Object Windows.Forms.CheckBox
$checkFFmpegOutput.Text = "Show FFmpeg log"
$checkFFmpegOutput.Location = '480,220'  # Poziționat deasupra log-ului
$checkFFmpegOutput.Size = '220,30'
$checkFFmpegOutput.Font = $fontMain
$form.Controls.Add($checkFFmpegOutput)

# === CRF Label ===
$labelCRF = New-Object Windows.Forms.Label
$labelCRF.Text = "CRF (1 - 63  low = hi quality) :"
$labelCRF.Location = '20,20'
$labelCRF.Size = '230,30'
$labelCRF.Font = $fontMain
$form.Controls.Add($labelCRF)

# === TextBox pentru CRF cu validare live ===
$textBoxCRF = New-Object Windows.Forms.TextBox
$textBoxCRF.Location = '260,20'
$textBoxCRF.Size = '60,30'
$textBoxCRF.Font = $fontMain
$textBoxCRF.Text = if ($config.ContainsKey("CRF")) { $config["CRF"] } else { "30" }
$form.Controls.Add($textBoxCRF)

# Label avertizare
$labelCRFWarning = New-Object Windows.Forms.Label
$labelCRFWarning.Text = ""
$labelCRFWarning.Location = '260,50'
$labelCRFWarning.AutoSize = $true
$labelCRFWarning.ForeColor = [System.Drawing.Color]::Orange
$labelCRFWarning.Font = $fontMain
$form.Controls.Add($labelCRFWarning)

# Timer pentru dispariția mesajului
$warningTimer = New-Object Windows.Forms.Timer
$warningTimer.Interval = 2000
$warningTimer.Add_Tick({
    $labelCRFWarning.Text = ""
    $warningTimer.Stop()
})

# Flag pentru a evita bucle infinite
$global:ignoreTextChanged = $false

# Validare live
$textBoxCRF.Add_TextChanged({
    if ($global:ignoreTextChanged) { return }

    $value = 0
    if (-not [int]::TryParse($textBoxCRF.Text, [ref]$value)) {
        $labelCRFWarning.Text = "Only numbers allowed"
        $warningTimer.Stop(); $warningTimer.Start()
        $global:ignoreTextChanged = $true
        $textBoxCRF.Text = "30"
        $textBoxCRF.SelectionStart = $textBoxCRF.Text.Length
        $global:ignoreTextChanged = $false
    }
    elseif ($value -lt 1) {
        $labelCRFWarning.Text = "Value too low, reset to 1"
        $warningTimer.Stop(); $warningTimer.Start()
        $global:ignoreTextChanged = $true
        $textBoxCRF.Text = "1"
        $textBoxCRF.SelectionStart = $textBoxCRF.Text.Length
        $global:ignoreTextChanged = $false
    }
    elseif ($value -gt 63) {
        $labelCRFWarning.Text = "Value too high, reset to 63"
        $warningTimer.Stop(); $warningTimer.Start()
        $global:ignoreTextChanged = $true
        $textBoxCRF.Text = "63"
        $textBoxCRF.SelectionStart = $textBoxCRF.Text.Length
        $global:ignoreTextChanged = $false
    }
    else {
        $labelCRFWarning.Text = ""
    }
})

# === FFmpeg Path + Browse ===
$labelFFmpeg = New-Object Windows.Forms.Label
$labelFFmpeg.Text = "FFmpeg Path:"
$labelFFmpeg.Location = '350,20'
$labelFFmpeg.Size = '115,30'
$labelFFmpeg.Font = $fontMain
$form.Controls.Add($labelFFmpeg)

$textBoxFFmpeg = New-Object Windows.Forms.TextBox
$textBoxFFmpeg.Text = if ($config.ContainsKey("FFmpegPath")) { $config["FFmpegPath"] } else { "" }
$textBoxFFmpeg.Location = '470,20'
$textBoxFFmpeg.Size = '210,30'
$textBoxFFmpeg.Font = $fontMain
$form.Controls.Add($textBoxFFmpeg)

$buttonFFmpegBrowse = New-Object Windows.Forms.Button
$buttonFFmpegBrowse.Text = "Browse"
$buttonFFmpegBrowse.Location = '690,20'
$buttonFFmpegBrowse.Size = '80,30'
$buttonFFmpegBrowse.Font = $fontMain
$buttonFFmpegBrowse.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter = "Executable (*.exe)|*.exe|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq "OK") {
        $textBoxFFmpeg.Text = $dialog.FileName
    }
})
$form.Controls.Add($buttonFFmpegBrowse)

# === Input Folder ===
$labelInput = New-Object Windows.Forms.Label
$labelInput.Text = "Input Folder:"
$labelInput.Location = '20,70'
$labelInput.Size = '150,30'
$labelInput.Font = $fontMain
$form.Controls.Add($labelInput)

$textBoxInput = New-Object Windows.Forms.TextBox
$textBoxInput.Text = if ($config.ContainsKey("InputFolder")) { $config["InputFolder"] } else { "" }
$textBoxInput.Location = '180,70'
$textBoxInput.Size = '500,30'
$textBoxInput.Font = $fontMain
$form.Controls.Add($textBoxInput)

$buttonInput = New-Object Windows.Forms.Button
$buttonInput.Text = "Browse"
$buttonInput.Location = '690,70'
$buttonInput.Size = '80,30'
$buttonInput.Font = $fontMain
$buttonInput.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq "OK") {
        $textBoxInput.Text = $dialog.SelectedPath
    }
})
$form.Controls.Add($buttonInput)

# === Output Folder ===
$labelOutput = New-Object Windows.Forms.Label
$labelOutput.Text = "Output Folder:"
$labelOutput.Location = '20,120'
$labelOutput.Size = '150,30'
$labelOutput.Font = $fontMain
$form.Controls.Add($labelOutput)

$textBoxOutput = New-Object Windows.Forms.TextBox
$textBoxOutput.Text = if ($config.ContainsKey("OutputFolder")) { $config["OutputFolder"] } else { "" }
$textBoxOutput.Location = '180,120'
$textBoxOutput.Size = '500,30'
$textBoxOutput.Font = $fontMain
$form.Controls.Add($textBoxOutput)

$buttonOutput = New-Object Windows.Forms.Button
$buttonOutput.Text = "Browse"
$buttonOutput.Location = '690,120'
$buttonOutput.Size = '80,30'
$buttonOutput.Font = $fontMain
$buttonOutput.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq "OK") {
        $textBoxOutput.Text = $dialog.SelectedPath
    }
})
$form.Controls.Add($buttonOutput)

# === Hibernate Checkbox ===
$checkHibernate = New-Object Windows.Forms.CheckBox
$checkHibernate.Text = "Hibernate after conversion"
$checkHibernate.Location = '20,170'
$checkHibernate.Size = '250,30'
$checkHibernate.Font = $fontMain
$form.Controls.Add($checkHibernate)

# === Parallel Jobs Control ===
$labelParallel = New-Object Windows.Forms.Label
$labelParallel.Text = "Parallel jobs:"
$labelParallel.Location = '280,172'
$labelParallel.Size = '120,30'
$labelParallel.Font = $fontMain
$form.Controls.Add($labelParallel)

$comboParallel = New-Object Windows.Forms.ComboBox
$comboParallel.Location = '400,170'
$comboParallel.Size = '60,30'
$comboParallel.DropDownStyle = 'DropDownList'
$comboParallel.Items.AddRange(@(2,3,4,5,6,7,8))
$comboParallel.Font = $fontMain
if ($config.ContainsKey("ParallelJobs") -and $config["ParallelJobs"]) {
    try {
        $comboParallel.SelectedItem = [int]$config["ParallelJobs"]
    } catch {
        $comboParallel.SelectedIndex = 0
    }
} else {
    $comboParallel.SelectedIndex = 0
}
$form.Controls.Add($comboParallel)

# === Heartbeat Visual ===
$pulseBox = New-Object Windows.Forms.RichTextBox
$pulseBox.ReadOnly = $true
$pulseBox.BorderStyle = 'None'
$pulseBox.Location = '550,170'
$pulseBox.Size = '300,80'
$pulseBox.Font = New-Object System.Drawing.Font("Consolas", 14, [System.Drawing.FontStyle]::Bold)
$pulseBox.BackColor = $form.BackColor
$pulseBox.ForeColor = [System.Drawing.Color]::DarkGreen
$pulseBox.Text = "Ready..."
$form.Controls.Add($pulseBox)

# === Log Box ===
$labelLog = New-Object Windows.Forms.Label
$labelLog.Text = "Conversion Log:"
$labelLog.Location = '20,220'
$labelLog.Size = '200,30'
$labelLog.Font = $fontMain
$form.Controls.Add($labelLog)

$textBoxLog = New-Object Windows.Forms.RichTextBox
$textBoxLog.Location = '20,260'
$textBoxLog.Size = '740,300'
$textBoxLog.ReadOnly = $true
$textBoxLog.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#333")
$textBoxLog.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#cccccc")
$textBoxLog.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 12.5, [System.Drawing.FontStyle]::Regular)
$form.Controls.Add($textBoxLog)

# === Status Bar ===
$progressBar = New-Object Windows.Forms.ProgressBar
$progressBar.Location = '20,580'
$progressBar.Size = '740,20'
$progressBar.Value = 0
$form.Controls.Add($progressBar)

# === Delete Original Files Checkbox ===
$checkDeleteOriginal = New-Object Windows.Forms.CheckBox
$checkDeleteOriginal.Text = "Delete original after conversion"
$checkDeleteOriginal.Location = '20,620'
$checkDeleteOriginal.Size = '350,40'
$checkDeleteOriginal.Font = $fontMain
$checkDeleteOriginal.ForeColor = [System.Drawing.Color]::DarkRed
if ($config.ContainsKey("DeleteOriginal")) {
    $checkDeleteOriginal.Checked = [System.Convert]::ToBoolean($config["DeleteOriginal"])
}
$form.Controls.Add($checkDeleteOriginal)

# === Timer pentru Heartbeat - INTERVAL REDUS LA 500ms ===
$pulseActive = [char]0x2588  # █
$pulseIdle   = [char]0x2591  # ░

$heartbeatTimer = New-Object Windows.Forms.Timer
$heartbeatTimer.Interval = 500  # FIX: Redus de la 1000ms la 500ms pentru răspuns mai rapid

$heartbeatTimer.Add_Tick({
    if (-not $global:conversionActive) {
        $pulseBox.Text = if ($global:stopRequested) { "Stopped" } else { "Ready..." }
        return
    }
    
    try {
        $ffmpegRunning = @(Get-Process -Name "ffmpeg" -ErrorAction SilentlyContinue).Count
        $maxJobs = if ($comboParallel.SelectedItem) { $comboParallel.SelectedItem } else { 2 }
        
        $displayText = ""
        for ($i = 1; $i -le $maxJobs; $i++) {
            if ($i -le $ffmpegRunning) {
                $displayText += $pulseActive + " "
            } else {
                $displayText += $pulseIdle + " "
            }
        }

        # linia 2
        $displayText += "`r`n[$ffmpegRunning/$maxJobs] active"

        # linia 3 - FIX: Afișează întotdeauna progresul actual
        if ($global:totalFiles -gt 0) {
            $displayText += "`r`n($global:currentProgress/$global:totalFiles total)"
        }

        $pulseBox.Text = $displayText
        
    } catch {
        $pulseBox.Text = "Heartbeat error"
    }
})

# === Start/Stop Button ===
$conversionRunning = $false
$buttonStart = New-Object Windows.Forms.Button
$buttonStart.Text = "Start Conversion"
$buttonStart.Location = '380,620'
$buttonStart.Size = '200,40'
$buttonStart.BackColor = 'LightGreen'
$buttonStart.Font = $fontBold

$buttonStart.Add_Click({
    if (-not $conversionRunning) {
        # === START CONVERSION ===
        $inputDir = $textBoxInput.Text
        $outputDir = $textBoxOutput.Text
        $ffmpegPath = $textBoxFFmpeg.Text
        $deleteOriginals = $checkDeleteOriginal.Checked
        
        # Reset și validări
        $global:stopRequested = $false
        $global:currentProgress = 0
        $global:totalFiles = 0
        $global:hibernateCancelled = $false
        $progressBar.Value = 0
        
        if (-not $inputDir) {
            Write-LogMessage "ERROR: Please set the input folder before starting conversion." "Red"
            return
        }

        if (-not $ffmpegPath -or -not (Test-Path $ffmpegPath)) {
            Write-LogMessage "ERROR: Please set a valid FFmpeg path before starting conversion." "Red"
            return
        }

        if (-not $outputDir) {
            $outputDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
            $textBoxOutput.Text = $outputDir
            Write-LogMessage "WARNING: Output folder not set. Using script directory as default." "Yellow"
        }

        # Avertizare pentru ștergere
        if ($deleteOriginals) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "!!! WARNING: You have enabled 'Delete original files after successful conversion'.`n`n" +
                "Original files will be PERMANENTLY DELETED after successful conversion!`n`n" +
                "Are you sure you want to continue?",
                "Delete Original Files - Confirmation",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            
            if ($result -eq [System.Windows.Forms.DialogResult]::No) {
                Write-LogMessage "[CANCELLED] User cancelled due to delete original files warning." "Yellow"
                return
            }
            
            Write-LogMessage "!!! DELETE MODE ENABLED - Original files will be deleted after successful conversion!" "Red"
        }

        # Start conversion
        $conversionRunning = $true
        $global:conversionActive = $true
        $buttonStart.Text = "Stop Conversion"
        $buttonStart.BackColor = 'IndianRed'
        $startTime = Get-Date
        $heartbeatTimer.Start()
        Save-Config
        
        Write-LogMessage "=== STARTING NEW CONVERSION ===" "Cyan"
        
        # Conversie cu ștergere opțională
        try {
            # Găsește fișierele
            $extensions = "*.mp4","*.avi","*.mov","*.wmv","*.flv","*.webm","*.mkv"
            $files = Get-ChildItem -Path $inputDir -Include $extensions -Recurse
            $total = $files.Count
            $global:totalFiles = $total
            
            Write-LogMessage "[INFO] Found $total file(s) to convert." "Yellow"
            if ($deleteOriginals) {
                Write-LogMessage "[INFO] Delete mode: Original files will be removed after successful conversion." "Orange"
            }
            
            $counter = 0
            $successCount = 0
            $deletedCount = 0
            $failedFiles = @()
            $jobs = @()
            
            # Verifică Start-ThreadJob
            if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
                Write-LogMessage "ERROR: Start-ThreadJob is not available. Please install the ThreadJob module." "Red"
                throw "ThreadJob module not available"
            }
            
            foreach ($file in $files) {
                if ($global:stopRequested) {
                    Write-LogMessage "[STOP] Stopping conversion as requested..." "Red"
                    break
                }
                
                Write-LogMessage "[>>] Converting: $($file.Name)" "White"
                [System.Windows.Forms.Application]::DoEvents()
                
                # Așteaptă slot liber - FIX: Interval redus pentru răspuns mai rapid
                while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $comboParallel.SelectedItem) {
                    Start-Sleep -Milliseconds 300  # Redus de la 500ms
                    [System.Windows.Forms.Application]::DoEvents()
                    if ($global:stopRequested) { break }
                }
                
                if ($global:stopRequested) { break }
                
                # Prepare paths
                $relativePath = $file.FullName.Substring($inputDir.Length).TrimStart("\")
                $relativeDir = Split-Path $relativePath -Parent
                $outputDirFull = Join-Path $outputDir $relativeDir
                if ($relativeDir -and -not (Test-Path $outputDirFull)) {
                    New-Item -ItemType Directory -Path $outputDirFull -Force | Out-Null
                }

                $newFileName = $file.BaseName + "-av1" + $file.Extension
                $destPath = Join-Path $outputDirFull $newFileName

                # Start job
                $job = Start-ThreadJob -ScriptBlock {
					param($ffmpegPath, $filePath, $destPath, $crf, $showOutput)
					
					try {
						$arguments = "-y -i `"$filePath`" -c:v libsvtav1 -crf $crf `"$destPath`""
						
						if ($showOutput) {
							# Captăm output-ul FFmpeg
							$process = Start-Process -FilePath $ffmpegPath -ArgumentList $arguments -NoNewWindow -Wait -PassThru -RedirectStandardOutput "temp_out.txt" -RedirectStandardError "temp_err.txt"
							$ffmpegOutput = Get-Content "temp_out.txt", "temp_err.txt" -ErrorAction SilentlyContinue
							Remove-Item "temp_out.txt", "temp_err.txt" -ErrorAction SilentlyContinue
						} else {
							# Rulăm fără a captura output-ul
							$process = Start-Process -FilePath $ffmpegPath -ArgumentList $arguments -NoNewWindow -Wait -PassThru
							$ffmpegOutput = $null
						}
						
						return @{ 
							ExitCode = $process.ExitCode
							FileName = (Split-Path $filePath -Leaf)
							FilePath = $filePath
							DestPath = $destPath
							FFmpegOutput = $ffmpegOutput
						}
					} catch {
						return @{
							ExitCode = -1
							FileName = (Split-Path $filePath -Leaf)
							FilePath = $filePath
							Error = $_.Exception.Message
						}
					}
				} -ArgumentList $ffmpegPath, $file.FullName, $destPath, ([int]$textBoxCRF.Text), $checkFFmpegOutput.Checked


                $jobs += $job
            }
            
            # Așteaptă finalizarea job-urilor
            foreach ($job in $jobs) {
                if ($global:stopRequested) {
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                    continue
                }
                
                Wait-Job -Job $job | Out-Null
                $result = Receive-Job -Job $job
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                
                $counter++
                Update-ProgressBar $counter $total  # FIX: Actualizează imediat progresul
                
				
				
				### blocul de procesare a rezultatelor
                if ($result -and $result.ExitCode -eq 0) {
                    $successCount++
                    Write-LogMessage "[OK] SUCCESS: $($result.FileName)" "LimeGreen"
                    
				# === Afișează output-ul FFmpeg dacă există și checkbox-ul este bifat ===
				if ($result.FFmpegOutput) {
					Write-LogMessage "=== FFmpeg Output ===" "Gray"
					foreach ($line in $result.FFmpegOutput) {
						Write-LogMessage "    $line" "Gray"
					}
					Write-LogMessage "=== End FFmpeg Output ===" "Gray"
				}
					
					# Șterge fișierul original dacă conversia a fost cu succes și opțiunea e activată
                    if ($deleteOriginals -and $result.FilePath) {
                        if (Test-Path $result.DestPath) {
                            $destSize = (Get-Item $result.DestPath).Length
                            if ($destSize -gt 0) {
                                if (Remove-OriginalFile $result.FilePath $result.FileName) {
                                    $deletedCount++
                                }
                            } else {
                                Write-LogMessage "    [SKIP] Destination file is empty, keeping original: $($result.FileName)" "Yellow"
                            }
                        } else {
                            Write-LogMessage "    [SKIP] Destination file not found, keeping original: $($result.FileName)" "Yellow"
                        }
                    }
                } else {
                    $fileName = if ($result) { $result.FileName } else { "Unknown file" }
                    $failedFiles += $fileName
                    Write-LogMessage "[X] FAILED: $fileName" "Red"
                    if ($result -and $result.Error) {
                        Write-LogMessage "    Error: $($result.Error)" "Red"
                    }
                }
                [System.Windows.Forms.Application]::DoEvents()
            }
            
            # FIX: Forțează update final pentru progress
            Update-ProgressBar $counter $total
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100  # Scurtă pauză pentru refresh UI
            
            # Summary
            if ($global:stopRequested) {
                Write-LogMessage "[STOPPED] Conversion stopped by user." "Orange"
            } else {
                Write-LogMessage "[OK] Conversion completed. Success: $successCount/$total" "LimeGreen"
                if ($deleteOriginals) {
                    Write-LogMessage "[INFO] Deleted original files: $deletedCount/$successCount" "Orange"
                }
            }
            
            if ($failedFiles.Count -gt 0) {
                Write-LogMessage "[SUMMARY] Failed files: $($failedFiles.Count)" "Red"
                foreach ($failed in $failedFiles) {
                    Write-LogMessage " - $failed" "Red"
                }
            }
            
        } catch {
            Write-LogMessage "[ERROR] Conversion failed: $($_.Exception.Message)" "Red"
        }

        # Cleanup
        $endTime = Get-Date
        $duration = $endTime - $startTime
        $conversionRunning = $false
        $global:conversionActive = $false
        $buttonStart.Text = "Start Conversion"
        $buttonStart.BackColor = 'LightGreen'
        $heartbeatTimer.Stop()
        
        # FIX: Forțează afișarea finală "Ready..." după finalizare
        Start-Sleep -Milliseconds 200
        $pulseBox.Text = "Ready..."
        
        Write-LogMessage "Total Duration: $(Format-Duration $duration)" "Cyan"

        # FIX: Hibernare cu posibilitate de ANULARE
		if ($checkHibernate.Checked -and -not $global:stopRequested) {
			$global:hibernateCancelled = $false
			Write-LogMessage "[INFO] System will hibernate in 10 seconds..." "Yellow"
			Write-LogMessage "[INFO] Press ESC to cancel hibernate!" "Orange"
			
			# Event handler temporar pentru anulare hibernate
			$escHandler = {
				param($sender, $e)
				if ($e.KeyCode -eq 'Escape') {
					$global:hibernateCancelled = $true
				}
			}
			
			# Adăugăm handler pentru tasta ESC
			$form.KeyPreview = $true
			$form.Add_KeyDown($escHandler)
			
			for ($i = 10; $i -gt 0; $i--) {
				if ($global:hibernateCancelled) {
					Write-LogMessage "[CANCELLED] Hibernate cancelled by user." "Orange"
					break
				}
				Write-LogMessage "Hibernating in $i seconds... (Press ESC to cancel)" "Yellow"
				[System.Windows.Forms.Application]::DoEvents()
				Start-Sleep -Milliseconds 900  # Redus pentru răspuns mai rapid la ESC
			}
			
			# Eliminăm handler-ul pentru ESC
			$form.Remove_KeyDown($escHandler)
			
			# Execută hibernate doar dacă nu a fost anulat
			if (-not $global:hibernateCancelled) {
				Write-LogMessage "[HIBERNATE] Entering hibernate mode..." "Cyan"
				Start-Sleep -Seconds 1  # Scurtă pauză pentru a permite afișarea mesajului
				& rundll32.exe powrprof.dll,SetSuspendState Hibernate
			}
		}
        
    } else {
        # === STOP CONVERSION ===
        $global:stopRequested = $true
        $global:conversionActive = $false
        
        Write-LogMessage "[STOP] User requested stop conversion..." "Red"
        
        try {
            $processes = Get-Process -Name "ffmpeg" -ErrorAction SilentlyContinue
            if ($processes.Count -gt 0) {
                Write-LogMessage "[STOP] Stopping $($processes.Count) ffmpeg processes..." "Red"
                $processes | Stop-Process -Force
                Write-LogMessage "[STOP] All ffmpeg processes stopped." "Orange"
            }
        } catch {
            Write-LogMessage "[ERROR] Failed to stop some processes: $($_.Exception.Message)" "Red"
        }
        
        # Reset UI
        $conversionRunning = $false
        $buttonStart.Text = "Start Conversion"
        $buttonStart.BackColor = 'LightGreen'
    }
})
$form.Controls.Add($buttonStart)

# === EXIT Button ===
$buttonExit = New-Object Windows.Forms.Button
$buttonExit.Text = "EXIT"
$buttonExit.Location = '590,620'
$buttonExit.Size = '100,40'
$buttonExit.Font = $fontBold
$buttonExit.Add_Click({ 
    $heartbeatTimer.Stop()
    $global:conversionActive = $false
    $global:stopRequested = $true
    $form.Close() 
})
$form.Controls.Add($buttonExit)

# === Cleanup ===
$form.Add_FormClosed({
    $heartbeatTimer.Stop()
    $global:conversionActive = $false
    $global:stopRequested = $true
    try {
        Get-Process -Name "ffmpeg" -ErrorAction SilentlyContinue | Stop-Process -Force
    } catch { }
})

# === Show Form ===
$form.ShowDialog()