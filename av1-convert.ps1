# Version v6.9.11 - Enhanced UI with GroupBox organization
# AV1 Converter - Distinction between STOP and PAUSE operations
# Data: 09.NOV.2025 >> Ora : 01:56

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object Windows.Forms.Form
$form.Text = "Av1 Converter - v6.9.11"
$form.Size = '820,960'
$form.MinimumSize = '820,960'
$form.StartPosition = "CenterScreen"
$form.AllowDrop = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)

$fontMain = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Regular)
$fontBold = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Bold)

$configPath = if ($MyInvocation.MyCommand.Path) {
    Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "config.ini"
} else {
    Join-Path $PWD.Path "config.ini"
}
$config = @{ }

# global flags
$global:PauseRequested = $false
$global:StopRequested = $false
$JobFile = "resume.job"
$JobData = @{ Files = @(); InputFolder = ""; OutputFolder = ""; CRT = "" }

$script:files = $null
$script:convertedFiles = @()
$script:totalFilesForJob = 0

$global:conversionActive = $false
$global:currentProgress = 0
$global:totalFiles = 0
$global:hibernateCancelled = $false
$global:resumeTriggered = $false
$global:resumeCompleted = $false

function Load-Config {
    try {
        if (Test-Path $configPath) {
            $lines = Get-Content $configPath -ErrorAction Stop
            foreach ($line in $lines) {
                if ($line -match "^\s*(\w+)\s*=\s*(.+?)\s*$") {
                    $config[$matches[1]] = $matches[2]
                }
            }
        }
    } catch {
        Write-LogMessage ("[WARNING] Nu s-a putut incarca config.ini: " + $_.Exception.Message) "Yellow"
    }
}

function Save-Config {
    try {
        $content = @(
            "CRF=$($textBoxCRF.Text)"
            "FFmpegPath=$($textBoxFFmpeg.Text)"
            "InputFolder=$($textBoxInput.Text)"
            "OutputFolder=$($textBoxOutput.Text)"
            "ParallelJobs=$($comboParallel.SelectedItem)"
            "DeleteOriginal=$($checkDeleteOriginal.Checked)"
        )
        $configDir = Split-Path -Parent $configPath
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        $content | Set-Content $configPath -ErrorAction Stop
        Write-LogMessage ("[INFO] Configuratie salvata in " + $configPath) "Green"
    } catch {
        Write-LogMessage ("[ERROR] Nu s-a putut salva config.ini: " + $_.Exception.Message) "Red"
    }
}

function Save-JobState {
    try {
        $out = @{
            Files = $JobData.Files
            InputFolder = $JobData.InputFolder
            OutputFolder = $JobData.OutputFolder
            CRT = $JobData.CRT
        }
        $out | ConvertTo-Json -Depth 5 | Set-Content $JobFile -Encoding UTF8
    } catch {
        Write-LogMessage ("[ERROR] Nu s-a putut salva resume.job: " + $_.Exception.Message) "Red"
    }
}

function Load-JobState {
    if (Test-Path $JobFile) {
        try {
            $tmp = Get-Content $JobFile -ErrorAction Stop | ConvertFrom-Json
            if ($tmp -is [System.Management.Automation.PSCustomObject]) {
                if ($tmp.Files) { $JobData.Files = @(); $JobData.Files += $tmp.Files }
                if ($tmp.InputFolder) { $JobData.InputFolder = $tmp.InputFolder }
                if ($tmp.OutputFolder) { $JobData.OutputFolder = $tmp.OutputFolder }
                if ($tmp.CRT) { $JobData.CRT = $tmp.CRT }
                return $JobData.Files
            } else {
                return @()
            }
        } catch {
            Write-LogMessage ("[ERROR] Nu s-a putut citi resume.job: " + $_.Exception.Message) "Red"
            return @()
        }
    }
    return @()
}

function Clear-JobData {
    $JobData.Files = @()
    $JobData.InputFolder = ""
    $JobData.OutputFolder = ""
    $JobData.CRT = ""
    if (Test-Path $JobFile) {
        try { Remove-Item $JobFile -Force -ErrorAction SilentlyContinue } catch { }
    }
    Write-LogMessage "[INFO] Job data cleared and file resume.job deleted." "Green"
    Update-ResumeButton
}

function Reset-JobList {
    Clear-JobData
    Write-LogMessage "[RESET] The job list has been completely cleared." "Cyan"
    [System.Windows.Forms.MessageBox]::Show("The job list has been reset!", "Reset Job", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}

function Update-ResumeButton {
    # Verifica daca exista fisiere neconvertite
    $hasResumeFiles = $false
    
    if (Test-Path $JobFile) {
        try {
            $tmp = Get-Content $JobFile -ErrorAction Stop | ConvertFrom-Json
            if ($tmp.Files -and $tmp.Files.Count -gt 0) {
                $hasResumeFiles = $true
            }
        } catch { }
    }
    
    if ($JobData.Files -and $JobData.Files.Count -gt 0) {
        $hasResumeFiles = $true
    }
    
    if ($hasResumeFiles -and -not $conversionRunning) {
        $pauseResumeButton.Text = "Resume"
        $pauseResumeButton.BackColor = 'Gold'
    } else {
        $pauseResumeButton.Text = "Pause"
        $pauseResumeButton.BackColor = 'LightGray'
    }
}

function MarkFileAsConverted($fileFullPath) {
    if ($JobData -and $JobData.Files) {
        $JobData.Files = $JobData.Files | Where-Object { $_ -ne $fileFullPath }
        Save-JobState
    }
	
	# Check if this was the last file in a resume session
	if ($global:resumeTriggered -and $JobData.Files.Count -eq 0) {
		Write-LogMessage "[INFO] Resume session completed - all files converted." "Green"
		$global:resumeCompleted = $true
		Clear-JobData
	}
}

function Write-LogMessage {
    param($message, $color = "#cccccc")
    try {
        if ($null -ne $textBoxLog) {
            $textBoxLog.SelectionColor = [System.Drawing.ColorTranslator]::FromHtml($color)
            $textBoxLog.AppendText("$message`r`n")
            $textBoxLog.SelectionStart = $textBoxLog.Text.Length
            $textBoxLog.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        } else {
            Write-Host $message
        }
    } catch {
        Write-Host $message
    }
}

function Update-ProgressBar {
    param($current, $total)
    try {
        $global:currentProgress = $current
        $global:totalFiles = $total
        if ($total -gt 0 -and $null -ne $progressBar) {
            $progressBar.Value = [math]::Min(100, [math]::Round(($current / $total) * 100))
        }
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }
}

function Update-CountsLabel {
    try {
        $converted = if ($script:convertedFiles) { $script:convertedFiles.Count } else { 0 }
        $remaining = 0
        if ($JobData.Files) {
            $remaining = $JobData.Files.Count
        } elseif ($script:totalFilesForJob) {
            $remaining = [math]::Max(0, $script:totalFilesForJob - $converted)
        }
        if ($null -ne $labelCounts) { $labelCounts.Text = "Converted: $converted  /  Remaining: $remaining" }
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }
}

function Remove-OriginalFile {
    param($filePath, $fileName)
    try {
        Remove-Item -Path $filePath -Force
        Write-LogMessage ("    [DEL] Deleted original: " + $fileName) "Orange"
        return $true
    } catch {
        Write-LogMessage ("    [ERR] Failed to delete: " + $fileName + " - " + $_.Exception.Message) "Red"
        return $false
    }
}

function Format-Duration($ts) {
    if ($ts.TotalMinutes -ge 1) { return "$($ts.Minutes) min : $($ts.Seconds) sec" } else { return "$($ts.Seconds) sec" }
}

# Ensure config file exists
if (-not (Test-Path $configPath)) {
    try {
        $null = New-Item -ItemType File -Path $configPath -Force
        Write-LogMessage ("[INFO] Creat fisier nou config.ini in " + $configPath) "Green"
    } catch {
        Write-LogMessage ("[WARNING] Nu s-a putut crea config.ini: " + $_.Exception.Message) "Yellow"
        $configPath = Join-Path $PWD.Path "config.ini"
        Write-LogMessage ("[INFO] Se va folosi calea alternativa: " + $configPath) "Yellow"
    }
}
Load-Config

# Load resume.job on startup
$hasResumeJobFiles = $false
if (Test-Path $JobFile) {
    try {
        $tmp = Get-Content $JobFile -ErrorAction Stop | ConvertFrom-Json
        if ($tmp.Files -and $tmp.Files.Count -gt 0) {
            $hasResumeJobFiles = $true
            $JobData.Files = @(); $JobData.Files += $tmp.Files
            if ($tmp.InputFolder) { $JobData.InputFolder = $tmp.InputFolder }
            if ($tmp.OutputFolder) { $JobData.OutputFolder = $tmp.OutputFolder }
            if ($tmp.CRT) { $JobData.CRT = $tmp.CRT }
            Write-LogMessage "[INFO] Job salvat detectat. Poti apasa Resume pentru a continua conversia." "Yellow"
        } else {
            Write-LogMessage "[INFO] resume.job gasit, dar fara fisiere. Nu se activeaza Resume." "Yellow"
        }
    } catch {
        Write-LogMessage ("[ERROR] resume.job corupt sau inaccesibil: " + $_.Exception.Message) "Red"
    }
}

# UI Controls - Enhanced with GroupBox organization

# GROUP 1: CONFIGURATION
$groupConfig = New-Object Windows.Forms.GroupBox
$groupConfig.Text = "Configuration"
$groupConfig.Location = New-Object System.Drawing.Point(15, 15)
$groupConfig.Size = New-Object System.Drawing.Size(780, 120)
$groupConfig.Font = $fontBold
$groupConfig.ForeColor = [System.Drawing.Color]::DarkBlue
$form.Controls.Add($groupConfig)

# CRF Controls (inside Configuration group)
$labelCRF = New-Object Windows.Forms.Label
$labelCRF.Text = "CRF (1 - 63  low = hi quality) :"
$labelCRF.Location = '15,25'
$labelCRF.Size = '230,30'
$labelCRF.Font = $fontMain
$groupConfig.Controls.Add($labelCRF)

$textBoxCRF = New-Object Windows.Forms.TextBox
$textBoxCRF.Location = '250,25'
$textBoxCRF.Size = '60,30'
$textBoxCRF.Font = $fontMain
$textBoxCRF.Text = if ($config.ContainsKey("CRF")) { $config["CRF"] } else { "30" }
$groupConfig.Controls.Add($textBoxCRF)

$labelCRFWarning = New-Object Windows.Forms.Label
$labelCRFWarning.Text = ""
$labelCRFWarning.Location = '250,55'
$labelCRFWarning.AutoSize = $true
$labelCRFWarning.ForeColor = [System.Drawing.Color]::Orange
$labelCRFWarning.Font = $fontMain
$groupConfig.Controls.Add($labelCRFWarning)

$warningTimer = New-Object Windows.Forms.Timer
$warningTimer.Interval = 2000
$warningTimer.Add_Tick({ $labelCRFWarning.Text = ""; $warningTimer.Stop() })

$global:ignoreTextChanged = $false
$textBoxCRF.Add_TextChanged({
    if ($global:ignoreTextChanged) { return }
    $value = 0
    if (-not [int]::TryParse($textBoxCRF.Text, [ref]$value)) {
        $labelCRFWarning.Text = "Only numbers allowed"; $warningTimer.Stop(); $warningTimer.Start()
        $global:ignoreTextChanged = $true; $textBoxCRF.Text = "30"; $textBoxCRF.SelectionStart = $textBoxCRF.Text.Length; $global:ignoreTextChanged = $false
    } elseif ($value -lt 1) {
        $labelCRFWarning.Text = "Value too low, reset to 1"; $warningTimer.Stop(); $warningTimer.Start()
        $global:ignoreTextChanged = $true; $textBoxCRF.Text = "1"; $textBoxCRF.SelectionStart = $textBoxCRF.Text.Length; $global:ignoreTextChanged = $false
    } elseif ($value -gt 63) {
        $labelCRFWarning.Text = "Value too high, reset to 63"; $warningTimer.Stop(); $warningTimer.Start()
        $global:ignoreTextChanged = $true; $textBoxCRF.Text = "63"; $textBoxCRF.SelectionStart = $textBoxCRF.Text.Length; $global:ignoreTextChanged = $false
    } else { $labelCRFWarning.Text = "" }
})

# FFmpeg Path (inside Configuration group)
$labelFFmpeg = New-Object Windows.Forms.Label
$labelFFmpeg.Text = "FFmpeg Path:"
$labelFFmpeg.Location = '330,25'
$labelFFmpeg.Size = '115,30'
$labelFFmpeg.Font = $fontMain
$groupConfig.Controls.Add($labelFFmpeg)

$textBoxFFmpeg = New-Object Windows.Forms.TextBox
$textBoxFFmpeg.Text = if ($config.ContainsKey("FFmpegPath")) { $config["FFmpegPath"] } else { "" }
$textBoxFFmpeg.Location = '450,25'
$textBoxFFmpeg.Size = '210,30'
$textBoxFFmpeg.Font = $fontMain
$groupConfig.Controls.Add($textBoxFFmpeg)

$buttonFFmpegBrowse = New-Object Windows.Forms.Button
$buttonFFmpegBrowse.Text = "Browse"
$buttonFFmpegBrowse.Location = '670,25'
$buttonFFmpegBrowse.Size = '80,30'
$buttonFFmpegBrowse.Font = $fontMain
$buttonFFmpegBrowse.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Filter = "Executable (*.exe)|*.exe|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq "OK") { $textBoxFFmpeg.Text = $dialog.FileName }
})
$groupConfig.Controls.Add($buttonFFmpegBrowse)

# Parallel Jobs (inside Configuration group)
$labelParallel = New-Object Windows.Forms.Label
$labelParallel.Text = "Parallel jobs:"
$labelParallel.Location = '15,70'
$labelParallel.Size = '120,30'
$labelParallel.Font = $fontMain
$groupConfig.Controls.Add($labelParallel)

$comboParallel = New-Object Windows.Forms.ComboBox
$comboParallel.Location = '140,68'
$comboParallel.Size = '60,30'
$comboParallel.DropDownStyle = 'DropDownList'
$comboParallel.Items.AddRange(@(2,3,4,5,6,7,8))
$comboParallel.Font = $fontMain
if ($config.ContainsKey("ParallelJobs") -and $config["ParallelJobs"]) {
    try { $comboParallel.SelectedItem = [int]$config["ParallelJobs"] } catch { $comboParallel.SelectedIndex = 0 }
} else { $comboParallel.SelectedIndex = 0 }
$groupConfig.Controls.Add($comboParallel)

# GROUP 2: FOLDERS
$groupFolders = New-Object Windows.Forms.GroupBox
$groupFolders.Text = "Folders"
$groupFolders.Location = New-Object System.Drawing.Point(15, 150)
$groupFolders.Size = New-Object System.Drawing.Size(780, 100)
$groupFolders.Font = $fontBold
$groupFolders.ForeColor = [System.Drawing.Color]::DarkGreen
$form.Controls.Add($groupFolders)

# Input Folder (inside Folders group)
$labelInput = New-Object Windows.Forms.Label
$labelInput.Text = "Input Folder:"
$labelInput.Location = '15,25'
$labelInput.Size = '150,30'
$labelInput.Font = $fontMain
$groupFolders.Controls.Add($labelInput)

$textBoxInput = New-Object Windows.Forms.TextBox
$textBoxInput.Text = if ($config.ContainsKey("InputFolder")) { $config["InputFolder"] } else { $JobData.InputFolder }
$textBoxInput.Location = '170,25'
$textBoxInput.Size = '490,30'
$textBoxInput.Font = $fontMain
$groupFolders.Controls.Add($textBoxInput)

$buttonInput = New-Object Windows.Forms.Button
$buttonInput.Text = "Browse"
$buttonInput.Location = '670,25'
$buttonInput.Size = '80,30'
$buttonInput.Font = $fontMain
$buttonInput.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq "OK") { $textBoxInput.Text = $dialog.SelectedPath }
})
$groupFolders.Controls.Add($buttonInput)

# Output Folder (inside Folders group)
$labelOutput = New-Object Windows.Forms.Label
$labelOutput.Text = "Output Folder:"
$labelOutput.Location = '15,60'
$labelOutput.Size = '150,30'
$labelOutput.Font = $fontMain
$groupFolders.Controls.Add($labelOutput)

$textBoxOutput = New-Object Windows.Forms.TextBox
$textBoxOutput.Text = if ($config.ContainsKey("OutputFolder")) { $config["OutputFolder"] } else { $JobData.OutputFolder }
$textBoxOutput.Location = '170,60'
$textBoxOutput.Size = '490,30'
$textBoxOutput.Font = $fontMain
$groupFolders.Controls.Add($textBoxOutput)

$buttonOutput = New-Object Windows.Forms.Button
$buttonOutput.Text = "Browse"
$buttonOutput.Location = '670,60'
$buttonOutput.Size = '80,30'
$buttonOutput.Font = $fontMain
$buttonOutput.Add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    if ($dialog.ShowDialog() -eq "OK") { $textBoxOutput.Text = $dialog.SelectedPath }
})
$groupFolders.Controls.Add($buttonOutput)

# GROUP 3: CONTROL PANEL
$groupControl = New-Object Windows.Forms.GroupBox
$groupControl.Text = "Control Panel"
$groupControl.Location = New-Object System.Drawing.Point(15, 265)
$groupControl.Size = New-Object System.Drawing.Size(780, 140)
$groupControl.Font = $fontBold
$groupControl.ForeColor = [System.Drawing.Color]::DarkRed
$form.Controls.Add($groupControl)

# Control buttons (inside Control Panel group)
$buttonResetJob = New-Object Windows.Forms.Button
$buttonResetJob.Text = "Reset Job"
$buttonResetJob.Location = New-Object System.Drawing.Point(15, 25)
$buttonResetJob.Size = New-Object System.Drawing.Size(100, 30)
$buttonResetJob.BackColor = 'Orange'
$buttonResetJob.Font = $fontMain
$buttonResetJob.Add_Click({ Reset-JobList })
$groupControl.Controls.Add($buttonResetJob)

$pauseResumeButton = New-Object Windows.Forms.Button
$pauseResumeButton.Text = if ($hasResumeJobFiles) { "Resume" } else { "Pause" }
$pauseResumeButton.Location = New-Object System.Drawing.Point(125, 25)
$pauseResumeButton.Size = New-Object System.Drawing.Size(100, 30)
if ($hasResumeJobFiles) { $pauseResumeButton.BackColor = 'Gold' } else { $pauseResumeButton.BackColor = 'LightGray' }
$groupControl.Controls.Add($pauseResumeButton)

#$buttonClearLog = New-Object Windows.Forms.Button
#$buttonClearLog.Text = "Clear Log"
#$buttonClearLog.Location = '235,25'
#$buttonClearLog.Size = '90,30'
#$buttonClearLog.Font = $fontMain
#$buttonClearLog.Add_Click({ $textBoxLog.Clear(); Write-LogMessage "=== Log cleared ===" "Gray" })
#$groupControl.Controls.Add($buttonClearLog)


# CREATE CLEAR LOG LINK-STYLE BUTTON (under log area)
################# Start Clear Log button ###############
$buttonClearLog = New-Object Windows.Forms.Button
$buttonClearLog.Text = "Clear Log"
$buttonClearLog.Location = '-10,858'  # Under the log area
$buttonClearLog.Size = '95,27'
#$buttonClearLog.Font = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Underline)
$buttonClearLog.Font = New-Object System.Drawing.Font("Segoe UI", 12.5)
$buttonClearLog.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#333")#[System.Drawing.Color]::Gray
$buttonClearLog.BackColor = [System.Drawing.Color]::Transparent
$buttonClearLog.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$buttonClearLog.FlatAppearance.BorderSize = 0
$buttonClearLog.FlatAppearance.MouseOverBackColor = [System.Drawing.ColorTranslator]::FromHtml("#333")
$buttonClearLog.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::LightSteelBlue
$buttonClearLog.Cursor = [System.Windows.Forms.Cursors]::Hand
$buttonClearLog.Add_Click({ 
    $textBoxLog.Clear()
    Write-LogMessage "=== Log cleared ===" "Gray" 
})

# Add hover effects
$buttonClearLog.Add_MouseEnter({
    $buttonClearLog.ForeColor = [System.Drawing.Color]::LightGreen
})
$buttonClearLog.Add_MouseLeave({
    $buttonClearLog.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#333")
})

$form.Controls.Add($buttonClearLog)  # Add to form, not to groupControl
################# End Clear Log button ###############



# Control checkboxes (inside Control Panel group)
$checkFFmpegOutput = New-Object Windows.Forms.CheckBox
$checkFFmpegOutput.Text = "Show FFmpeg log"
$checkFFmpegOutput.Location = '125,70'
$checkFFmpegOutput.Size = '180,25'
$checkFFmpegOutput.Font = $fontMain
$groupControl.Controls.Add($checkFFmpegOutput)

$checkLimitCPU = New-Object Windows.Forms.CheckBox
$checkLimitCPU.Text = "Limit CPU usage"
$checkLimitCPU.Location = '125, 100'
$checkLimitCPU.Size = '280,25'
$checkLimitCPU.Font = $fontMain
$groupControl.Controls.Add($checkLimitCPU)

# Control checkboxes Row 2 (moved from Options group)
$checkDeleteOriginal = New-Object Windows.Forms.CheckBox
$checkDeleteOriginal.Text = "Delete original after conversion"
$checkDeleteOriginal.Location = '450,70'
$checkDeleteOriginal.Size = '300,25'
$checkDeleteOriginal.Font = $fontMain
$checkDeleteOriginal.ForeColor = [System.Drawing.Color]::DarkRed
if ($config.ContainsKey("DeleteOriginal")) { $checkDeleteOriginal.Checked = [System.Convert]::ToBoolean($config["DeleteOriginal"]) }
$groupControl.Controls.Add($checkDeleteOriginal)

$checkHibernate = New-Object Windows.Forms.CheckBox
$checkHibernate.Text = "Hibernate after conversion"
$checkHibernate.Location = '450,100'
$checkHibernate.Size = '250,25'
$checkHibernate.Font = $fontMain
$groupControl.Controls.Add($checkHibernate)

# Pause/Resume click handler - FIXED: distinction between PAUSE and STOP
$pauseResumeButton.Add_Click({
    if ($pauseResumeButton.Tag -eq 'clicked') { return }
    $pauseResumeButton.Tag = 'clicked'
    Start-Sleep -Milliseconds 80
    $pauseResumeButton.Tag = $null

    if ($pauseResumeButton.Text -eq "Pause") {
        if (-not $conversionRunning) {
            Write-LogMessage "[INFO] Conversia nu este activa. Nu se poate pune pe pauza." "Yellow"
            [System.Windows.Forms.MessageBox]::Show("Conversia nu este activa. Nu se poate pune pe pauza.")
            return
        }

        # Set PAUSE flag (different from STOP)
        $global:PauseRequested = $true
        $pauseResumeButton.Text = "Resume"
        $pauseResumeButton.BackColor = 'Gold'
        Write-LogMessage "[PAUSE] Pauza solicitata. Joburile active vor termina, apoi se va opri." "Orange"
        [System.Windows.Forms.MessageBox]::Show("Conversia va fi intrerupta dupa joburile curente. Apasa Resume pentru a continua mai tarziu.")
    } else {
        # Resume path
        if ($conversionRunning) {
            Write-LogMessage "[INFO] Conversia este deja activa. Nu se poate relua." "Yellow"
            return
        }

        # Reload job if needed
        if (-not ($JobData.Files -and $JobData.Files.Count -gt 0)) {
            if (Test-Path $JobFile) {
                try {
                    $tmp = Get-Content $JobFile -ErrorAction Stop | ConvertFrom-Json
                    if ($tmp.Files -and $tmp.Files.Count -gt 0) {
                        $JobData.Files = @(); $JobData.Files += $tmp.Files
                        if ($tmp.InputFolder) { $JobData.InputFolder = $tmp.InputFolder }
                        if ($tmp.OutputFolder) { $JobData.OutputFolder = $tmp.OutputFolder }
                        if ($tmp.CRT) { $JobData.CRT = $tmp.CRT }
                        Write-LogMessage ("[INFO] resume.job reincarcat de pe disc. Fisiere: " + $JobData.Files.Count) "Yellow"
                    }
                } catch {
                    Write-LogMessage ("[WARNING] Nu s-a putut reincarca resume.job: " + $_.Exception.Message) "Yellow"
                }
            }
        }

        $hasResumeFiles = ($JobData.Files -and $JobData.Files.Count -gt 0)
        if (-not $hasResumeFiles) {
            Write-LogMessage "[INFO] Nu exista fisiere salvate pentru reluare. Resume anulat." "Yellow"
            [System.Windows.Forms.MessageBox]::Show("Nu exista fisiere salvate pentru reluare.")
            Update-ResumeButton
            return
        }

        # Start resume
        $global:PauseRequested = $false
        $global:StopRequested = $false
        $global:resumeTriggered = $true
        $global:resumeCompleted = $false
        $pauseResumeButton.Text = "Pause"
        $pauseResumeButton.BackColor = 'LightGray'
        Write-LogMessage ("[INFO] Resume: Continuare cu " + $JobData.Files.Count + " fisiere ramase.") "Cyan"
        if (-not $conversionRunning) { $buttonStart.PerformClick() }
    }
})



# GROUP 5: PROGRESS
$groupProgress = New-Object Windows.Forms.GroupBox
$groupProgress.Text = "Progress"
$groupProgress.Location = New-Object System.Drawing.Point(15, 420)
$groupProgress.Size = New-Object System.Drawing.Size(780, 140)
$groupProgress.Font = $fontBold
$groupProgress.ForeColor = [System.Drawing.Color]::DarkCyan
$form.Controls.Add($groupProgress)

# Progress controls (inside Progress group)
$labelCounts = New-Object Windows.Forms.Label
$labelCounts.Text = "Converted: 0  /  Remaining: 0"
$labelCounts.Location = '15,25'
$labelCounts.Size = '340,30'
$labelCounts.Font = $fontMain
$labelCounts.TextAlign = 'MiddleLeft'
$groupProgress.Controls.Add($labelCounts)

$pulseBox = New-Object Windows.Forms.RichTextBox
$pulseBox.ReadOnly = $true
$pulseBox.BorderStyle = 'None'
$pulseBox.Location = '400,25'
$pulseBox.Size = '350,70'
$pulseBox.Font = New-Object System.Drawing.Font("Consolas", 14, [System.Drawing.FontStyle]::Bold)
$pulseBox.BackColor = $groupProgress.BackColor
$pulseBox.ForeColor = [System.Drawing.Color]::DarkGreen
$pulseBox.Text = "Ready..."
$groupProgress.Controls.Add($pulseBox)

$progressBar = New-Object Windows.Forms.ProgressBar
$progressBar.Location = '15,100'
$progressBar.Size = '750,20'
$progressBar.Value = 0
$groupProgress.Controls.Add($progressBar)

# LOG SECTION (outside groups)
$textBoxLog = New-Object Windows.Forms.RichTextBox
$textBoxLog.Location = '-2,580'
$textBoxLog.Size = '808,280'
$textBoxLog.ReadOnly = $true
$textBoxLog.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#333")
$textBoxLog.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#cccccc")
$textBoxLog.Font = New-Object System.Drawing.Font("Segoe UI Emoji", 12.5, [System.Drawing.FontStyle]::Regular)
$form.Controls.Add($textBoxLog)

$pulseActive = [char]0x2588
$pulseIdle   = [char]0x2591

$heartbeatTimer = New-Object Windows.Forms.Timer
$heartbeatTimer.Interval = 250
$heartbeatTimer.Add_Tick({
    if (-not $global:conversionActive) {
        $pulseBox.Text = if ($global:StopRequested) { "Stopped" } else { "Ready..." }
        return
    }
    try {
        $ffmpegRunning = @(Get-Process -Name "ffmpeg" -ErrorAction SilentlyContinue).Count
        $maxJobs = if ($comboParallel.SelectedItem) { $comboParallel.SelectedItem } else { 2 }
        $displayText = ""
        for ($i = 1; $i -le $maxJobs; $i++) {
            if ($i -le $ffmpegRunning) { $displayText += $pulseActive + " " } else { $displayText += $pulseIdle + " " }
        }
        $displayText += "`r`n[$ffmpegRunning/$maxJobs] active"
        if ($global:totalFiles -gt 0) { $displayText += "`r`n($global:currentProgress/$global:totalFiles total)" }
        $pulseBox.Text = $displayText
    } catch { $pulseBox.Text = "Heartbeat error" }
})

$conversionRunning = $false
$buttonStart = New-Object Windows.Forms.Button
$buttonStart.Text = "Start Conversion"
$buttonStart.Location = '440,870'
$buttonStart.Size = '220,40'
$buttonStart.BackColor = 'LightGreen'
$buttonStart.Font = $fontBold

$buttonStart.Add_Click({
    if (-not $conversionRunning) {
        # FIXED: Reset flags at start
        $global:PauseRequested = $false
        $global:StopRequested = $false
        
        # Handle completed resume
        if ($global:resumeCompleted) {
            Write-LogMessage "[INFO] Resume a fost complet. Se incepe sesiune noua." "Green"
            Clear-JobData
        }
        
        # Clean up if resume.job deleted but JobData still has data
        if (-not (Test-Path $JobFile) -and $JobData.Files.Count -gt 0) {
            Write-LogMessage "[INFO] resume.job nu mai exista. Se curata lista interna JobData.Files." "Yellow"
            $JobData.Files = @()
        }
        
        $inputDir = $textBoxInput.Text
        $outputDir = $textBoxOutput.Text
        $ffmpegPath = $textBoxFFmpeg.Text
        $deleteOriginals = $checkDeleteOriginal.Checked
        $limitCPU = $checkLimitCPU.Checked

        # FIXED: Dialog for existing resume session (only if NOT from Resume button)
        if (($JobData.Files -and $JobData.Files.Count -gt 0) -and -not $global:resumeTriggered) {
            $res = [System.Windows.Forms.MessageBox]::Show(
                "Exista o sesiune salvata cu $($JobData.Files.Count) fisiere neconvertite. Vrei sa continui acea sesiune?`nYes = continue; No = start fresh",
                "Resume session detected",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($res -eq [System.Windows.Forms.DialogResult]::No) {
                Clear-JobData
                Write-LogMessage "[INFO] Lista veche a fost resetata la cererea utilizatorului." "Yellow"
            } else {
                Write-LogMessage "[INFO] Utilizatorul a ales sa continue sesiunea salvata." "Yellow"
            }
        }

        $global:currentProgress = 0
        $global:totalFiles = 0
        $global:hibernateCancelled = $false
        $progressBar.Value = 0

        if (-not $inputDir) { Write-LogMessage "ERROR: Please set the input folder before starting conversion." "Red"; return }
        if (-not $ffmpegPath -or -not (Test-Path $ffmpegPath)) { Write-LogMessage "ERROR: Please set a valid FFmpeg path before starting conversion." "Red"; return }
        if (-not $outputDir) {
            $outputDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
            $textBoxOutput.Text = $outputDir
            Write-LogMessage "WARNING: Output folder not set. Using script directory as default." "Yellow"
        }

        if ($deleteOriginals) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                "!!! WARNING: You have enabled 'Delete original files after successful conversion'.`n`nOriginal files will be PERMANENTLY DELETED after successful conversion!`n`nAre you sure you want to continue?",
                "Delete Original Files - Confirmation",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($result -eq [System.Windows.Forms.DialogResult]::No) { Write-LogMessage "[CANCELLED] User cancelled due to delete original files warning." "Yellow"; return }
            Write-LogMessage "!!! DELETE MODE ENABLED - Original files will be deleted after successful conversion!" "Red"
        }

        $conversionRunning = $true
        $global:conversionActive = $true
        $buttonStart.Text = "Stop Conversion"
        $buttonStart.BackColor = 'IndianRed'
        $startTime = Get-Date
        $heartbeatTimer.Start()
        Save-Config
        Write-LogMessage "=== STARTING CONVERSION ===" "Cyan"

        try {
            # Ensure ThreadJob available
            if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
                Write-LogMessage "INFO: Start-ThreadJob nu este disponibil. Se incearca instalarea modulului ThreadJob..." "Yellow"
                try {
                    Install-Module -Name ThreadJob -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                    Import-Module ThreadJob -ErrorAction Stop
                    Write-LogMessage "INFO: Modulul ThreadJob instalat si importat cu succes." "Green"
                } catch {
                    Write-LogMessage ("ERROR: Nu s-a putut instala/importa ThreadJob: " + $_.Exception.Message) "Red"
                    throw "ThreadJob module not available"
                }
            }

            $extensions = "*.mp4","*.avi","*.mov","*.wmv","*.flv","*.webm","*.mkv"
            
            # File loading logic
            if ($JobData.Files -and $JobData.Files.Count -gt 0) {
                $script:files = $JobData.Files | ForEach-Object { 
                    if ($_ -is [System.IO.FileInfo]) { $_ } else { New-Object System.IO.FileInfo($_) }
                }
                Write-LogMessage ("[INFO] Using resume list. Files: " + $script:files.Count) "Yellow"
            } elseif (Test-Path $JobFile) {
                try {
                    $tmp = Get-Content $JobFile -ErrorAction Stop | ConvertFrom-Json
                    if ($tmp.Files -and $tmp.Files.Count -gt 0) {
                        $JobData.Files = @(); $JobData.Files += $tmp.Files
                        $script:files = $tmp.Files | ForEach-Object { New-Object System.IO.FileInfo($_) }
                        Write-LogMessage ("[INFO] Reloaded resume job from disk: " + $script:files.Count + " files") "Yellow"
                    } else {
                        $script:files = Get-ChildItem -Path $inputDir -Include $extensions -Recurse -ErrorAction SilentlyContinue
                        Write-LogMessage ("[INFO] Empty resume file. Fresh scan. Files: " + $script:files.Count) "Yellow"
                    }
                } catch {
                    Write-LogMessage "[WARNING] Nu s-a putut incarca resume.job, va genera lista completa." "Yellow"
                    $script:files = Get-ChildItem -Path $inputDir -Include $extensions -Recurse -ErrorAction SilentlyContinue
                    Write-LogMessage ("[INFO] Fresh scan due to error. Files: " + $script:files.Count) "Yellow"
                }
            } else {
                $script:files = Get-ChildItem -Path $inputDir -Include $extensions -Recurse -ErrorAction SilentlyContinue
                Write-LogMessage ("[INFO] Fresh scan. Files: " + $script:files.Count) "Yellow"
            }

            if (-not $script:files) { $script:files = @() }

            $script:convertedFiles = @()
            $script:totalFilesForJob = $script:files.Count
            
            # Only update JobData if not already in resume mode
            if (-not ($JobData.Files -and $JobData.Files.Count -gt 0)) {
                $JobData = @{ 
                    Files = $script:files | ForEach-Object { if ($_ -is [System.IO.FileInfo]) { $_.FullName } else { $_ } }
                    InputFolder = $inputDir
                    OutputFolder = $outputDir
                    CRT = $textBoxCRF.Text 
                }
                Save-JobState
            }
            Update-CountsLabel

            $total = $script:files.Count
            $global:totalFiles = $total
            Write-LogMessage ("[INFO] Processing " + $total + " file(s).") "Yellow"
            if ($deleteOriginals) { Write-LogMessage "[INFO] Delete mode: Original files will be removed after successful conversion." "Orange" }

            $counter = 0
            $successCount = 0
            $deletedCount = 0
            $failedFiles = @()
            $jobs = @()

            # Conversion loop
            $pauseHandled = $false
            foreach ($file in $script:files) {
                if ($global:StopRequested) {
                    Write-LogMessage "[STOP] Stopping conversion as requested..." "Red"
                    break
                }

                # PAUSE logic (saves job)
                if ($global:PauseRequested) {
                    if (-not $pauseHandled) {
                        Write-LogMessage "[PAUSE] Pauza solicitata - se opreste lansarea de joburi noi." "Orange"
                        Update-ResumeButton
                        $pauseHandled = $true

                        # Save remaining files for resume
                        $remaining = @()
                        foreach ($f in $script:files) { 
                            $path = if ($f -is [System.IO.FileInfo]) { $f.FullName } else { $f }
                            if ($path -notin $script:convertedFiles) {
                                $remaining += $path
                            }
                        }
                        $JobData.Files = $remaining
                        $JobData.InputFolder = $textBoxInput.Text
                        $JobData.OutputFolder = $textBoxOutput.Text
                        $JobData.CRT = $textBoxCRF.Text
                        Save-JobState
                    }
                    continue
                }

                # Wait for slot
                while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $comboParallel.SelectedItem) {
                    Start-Sleep -Milliseconds 200
                    [System.Windows.Forms.Application]::DoEvents()
                    if ($global:StopRequested -or $global:PauseRequested) { break }
                }
                if ($global:StopRequested -or $global:PauseRequested) { continue }

                # Prepare output path
                $relativePath = $file.FullName.Substring($inputDir.Length).TrimStart("\")
                $relativeDir = Split-Path $relativePath -Parent
                $outputDirFull = Join-Path $outputDir $relativeDir
                if ($relativeDir -and -not (Test-Path $outputDirFull)) { New-Item -ItemType Directory -Path $outputDirFull -Force | Out-Null }

                $newFileName = $file.BaseName + "-av1" + $file.Extension
                $destPath = Join-Path $outputDirFull $newFileName

                if ($global:PauseRequested -or $global:StopRequested) { continue }

                Write-LogMessage ("[>>] Converting: " + $file.Name) "White"
                [System.Windows.Forms.Application]::DoEvents()

                $job = Start-ThreadJob -ScriptBlock {
                    param($ffmpegPath, $filePath, $destPath, $crf, $showOutput, $limitCPU)
                    try {
                        $arguments = "-y -i `"$filePath`" -c:v libsvtav1 -crf $crf `"$destPath`""
                        $psi = New-Object System.Diagnostics.ProcessStartInfo
                        $psi.FileName = $ffmpegPath
                        $psi.Arguments = $arguments
                        $psi.UseShellExecute = $false
                        $psi.CreateNoWindow = $true
                        $psi.WindowStyle = 'Hidden'

                        if ($showOutput) {
                            $psi.RedirectStandardError = $true
                            $psi.RedirectStandardOutput = $true
                            $process = New-Object System.Diagnostics.Process
                            $process.StartInfo = $psi
                            $outputBuilder = New-Object System.Collections.ArrayList

                            $stdOutEvent = Register-ObjectEvent -InputObject $process -EventName 'OutputDataReceived' -Action {
                                if (-not [string]::IsNullOrEmpty($EventArgs.Data)) { $outputBuilder.Add($EventArgs.Data); Write-Host ("FFMPEG_OUTPUT: " + $EventArgs.Data) }
                            }
                            $stdErrEvent = Register-ObjectEvent -InputObject $process -EventName 'ErrorDataReceived' -Action {
                                if (-not [string]::IsNullOrEmpty($EventArgs.Data)) { $outputBuilder.Add($EventArgs.Data); Write-Host ("FFMPEG_OUTPUT: " + $EventArgs.Data) }
                            }

                            $process.Start() | Out-Null
                            if ($limitCPU) { try { $process.ProcessorAffinity = [intptr]0x0000000F } catch { Write-Host ("WARN: Could not set ProcessorAffinity: " + $_.Exception.Message) } }
                            $process.BeginOutputReadLine()
                            $process.BeginErrorReadLine()
                            $process.WaitForExit()
                            Unregister-Event -SourceIdentifier $stdOutEvent.Name
                            Unregister-Event -SourceIdentifier $stdErrEvent.Name
                            return @{ ExitCode = $process.ExitCode; FileName = (Split-Path $filePath -Leaf); FilePath = $filePath; DestPath = $destPath; FFmpegOutput = $outputBuilder.ToArray() }
                        } else {
                            $psi.RedirectStandardError = $false
                            $psi.RedirectStandardOutput = $false
                            $process = New-Object System.Diagnostics.Process
                            $process.StartInfo = $psi
                            $process.Start() | Out-Null
                            if ($limitCPU) { try { $process.ProcessorAffinity = [intptr]0x0000000F } catch { Write-Host ("WARN: Could not set ProcessorAffinity: " + $_.Exception.Message) } }
                            $process.WaitForExit()
                            return @{ ExitCode = $process.ExitCode; FileName = (Split-Path $filePath -Leaf); FilePath = $filePath; DestPath = $destPath }
                        }
                    } catch {
                        return @{ ExitCode = -1; FileName = (Split-Path $filePath -Leaf); FilePath = $filePath; Error = $_.Exception.Message }
                    }
                } -ArgumentList $ffmpegPath, $file.FullName, $destPath, ([int]$textBoxCRF.Text), $checkFFmpegOutput.Checked, $limitCPU

                $jobs += $job
            }

            # Process completed jobs
            foreach ($job in $jobs) {
                if ($global:StopRequested) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue; continue }
                Wait-Job -Job $job | Out-Null
                $result = Receive-Job -Job $job
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                $counter++
                Update-ProgressBar $counter $total

                if ($result -and $result.ExitCode -eq 0) {
                    $successCount++
                    $msg = "OK SUCCESS: " + $result.FileName
                    Write-LogMessage $msg "LimeGreen"
                    $script:convertedFiles += $result.FilePath
                    
                    MarkFileAsConverted $result.FilePath
                    Update-CountsLabel
                    
                    if ($result.FFmpegOutput) {
                        Write-LogMessage "=== FFmpeg Output ===" "Gray"
                        foreach ($line in $result.FFmpegOutput) { $l = "    " + $line; Write-LogMessage $l "Gray" }
                        Write-LogMessage "=== End FFmpeg Output ===" "Gray"
                    }
                    if ($deleteOriginals -and $result.FilePath) {
                        if (Test-Path $result.DestPath) {
                            $destSize = (Get-Item $result.DestPath).Length
                            if ($destSize -gt 0) { if (Remove-OriginalFile $result.FilePath $result.FileName) { $deletedCount++ } } else { Write-LogMessage ("    [SKIP] Destination file is empty, keeping original: " + $result.FileName) "Yellow" }
                        } else { Write-LogMessage ("    [SKIP] Destination file not found, keeping original: " + $result.FileName) "Yellow" }
                    }
                } else {
                    $fileName = if ($result) { $result.FileName } else { "Unknown file" }
                    $failedFiles += $fileName
                    Write-LogMessage ("[X] FAILED: " + $fileName) "Red"
                    if ($result -and $result.Error) { Write-LogMessage ("    Error: " + $result.Error) "Red" }
                }
                [System.Windows.Forms.Application]::DoEvents()
            }

            Update-ProgressBar $counter $total
            Update-CountsLabel
            [System.Windows.Forms.Application]::DoEvents()

            if ($global:StopRequested) { 
                Write-LogMessage "[STOPPED] Conversion stopped by user." "Orange" 
            } else { 
                Write-LogMessage ("[OK] Conversion completed. Success: " + $successCount + "/" + $total) "LimeGreen"
                
                # FIXED: Mark resume as completed
                if ($global:resumeTriggered) {
                    $global:resumeCompleted = $true
                    $global:resumeTriggered = $false
                    Write-LogMessage "[INFO] Resume operation completed." "Green"
                }
                
                if ($deleteOriginals) {
                    Write-LogMessage ("[INFO] Deleted original files: " + $deletedCount + "/" + $successCount) "Orange"
                }
            }

            # PAUSE: Save remaining files
            if ($global:PauseRequested) {
                $remaining = @()
                foreach ($f in $script:files) { 
                    $path = if ($f -is [System.IO.FileInfo]) { $f.FullName } else { $f }
                    if ($path -notin $script:convertedFiles) {
                        $remaining += $path
                    }
                }
                $JobData.Files = $remaining
                $JobData.InputFolder = $textBoxInput.Text
                $JobData.OutputFolder = $textBoxOutput.Text
                $JobData.CRT = $textBoxCRF.Text
                Save-JobState
                $remainingCount = $total - $successCount
                Write-LogMessage ("[PAUSE] Job salvat: " + $remainingCount + " fisiere ramase pentru reluare.") "Cyan"
            }
            
            # STOP: Do NOT save job (difference from PAUSE)
            if ($global:StopRequested) {
                # Do not save job state for resume
                Write-LogMessage "[STOP] Conversion stopped - no resume job saved." "Orange"
            }

            if ($failedFiles.Count -gt 0) { 
                Write-LogMessage ("[SUMMARY] Failed files: " + $failedFiles.Count) "Red"
                foreach ($failed in $failedFiles) { Write-LogMessage (" - " + $failed) "Red" }
            }

        } catch {
            Write-LogMessage ("[ERROR] Conversion failed: " + $_.Exception.Message) "Red"
        } finally {
            $endTime = Get-Date
            $duration = $endTime - $startTime
            $conversionRunning = $false
            $global:conversionActive = $false
            $buttonStart.Text = "Start Conversion"
            $buttonStart.BackColor = 'LightGreen'
            $heartbeatTimer.Stop()
            Start-Sleep -Milliseconds 200
            $pulseBox.Text = "Ready..."
            Write-LogMessage ("Total Duration: " + (Format-Duration $duration)) "Cyan"
			
			# Reset flags PRIMUL
			$global:resumeTriggered = $false
			
			# Verifica si curata jobul daca toate fisierele au fost procesate
			if ($JobData.Files -and $JobData.Files.Count -eq 0) {
				Clear-JobData
				Write-LogMessage "[INFO] Conversion completed - job list cleared." "Green"
			}

            # Reset flags
            $global:resumeTriggered = $false
            
            # Update button state
            Update-ResumeButton

            if ($checkHibernate.Checked -and -not $global:StopRequested) {
                $global:hibernateCancelled = $false
                Write-LogMessage "[INFO] System will hibernate in 10 seconds..." "Yellow"
                Write-LogMessage "[INFO] Press ESC to cancel hibernate!" "Orange"
                $escHandler = { param($sender, $e) if ($e.KeyCode -eq 'Escape') { $global:hibernateCancelled = $true } }
                $form.KeyPreview = $true
                $form.Add_KeyDown($escHandler)
                for ($i = 10; $i -gt 0; $i--) {
                    if ($global:hibernateCancelled) { Write-LogMessage "[CANCELLED] Hibernate cancelled by user." "Orange"; break }
                    Write-LogMessage ("Hibernating in " + $i + " seconds... (Press ESC to cancel)") "Yellow"
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 900
                }
                $form.Remove_KeyDown($escHandler)
                if (-not $global:hibernateCancelled) { Write-LogMessage "[HIBERNATE] Entering hibernate mode..." "Cyan"; Start-Sleep -Seconds 1; & rundll32.exe powrprof.dll,SetSuspendState Hibernate }
            }
        }
    } else {
        # FIXED: STOP button behavior - do NOT save resume job
        $global:StopRequested = $true
        $global:conversionActive = $false
        Write-LogMessage "[STOP] User requested stop conversion..." "Red"
        try {
            $processes = Get-Process -Name ffmpeg -ErrorAction SilentlyContinue
            if ($processes -and $processes.Count -gt 0) {
                $msg = "[STOP] Stopping " + $processes.Count + " ffmpeg processes..."
                Write-LogMessage $msg "Red"
                $processes | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
                Write-LogMessage "[STOP] All ffmpeg processes stopped." "Orange"
            }
        } catch {
            Write-LogMessage ("[ERROR] Failed to stop some processes: " + $_.Exception.Message) "Red"
        }
        $conversionRunning = $false
        $buttonStart.Text = "Start Conversion"
        $buttonStart.BackColor = 'LightGreen'
        
        # FIXED: Do NOT update resume button state after STOP
        # Leave job intact if it existed before STOP
    }
})
$form.Controls.Add($buttonStart)

$buttonExit = New-Object Windows.Forms.Button
$buttonExit.Text = "EXIT"
$buttonExit.Location = '680,870'
$buttonExit.Size = '100,40'
$buttonExit.Font = $fontBold
$buttonExit.BackColor = 'Pink'
$buttonExit.Add_Click({
    $heartbeatTimer.Stop()
    $global:conversionActive = $false
    $global:StopRequested = $true
    $form.Close()
})
$form.Controls.Add($buttonExit)

$form.Add_FormClosed({
    $heartbeatTimer.Stop()
    $global:conversionActive = $false
    $global:StopRequested = $true
    try { Get-Process -Name ffmpeg -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } } catch { }
})

$form.ShowDialog()