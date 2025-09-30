# Universal PowerShell Builder v2.1
# Builder generalizat cu interfață grafică pentru proiecte PowerShell
# Autor: Assistant
# Data: 2025

[CmdletBinding()]
param()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# === Variabile globale ===
$script:sourceFiles = @()
$script:buildSettings = @{
    NoConsole     = $false
    RequireAdmin  = $false
    IconPath      = ""
    Version       = "1.0.0"
    CompanyName   = ""
    ProductName   = ""
    Copyright     = ""
    Description   = ""
}

# === Funcții helper ===
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logEntry  = "[$timestamp] [$Level] $Message"

    if ($script:logTextBox) {
        $color = switch ($Level) {
            "ERROR"   { [System.Drawing.Color]::Red }
            "WARN"    { [System.Drawing.Color]::Orange }
            "SUCCESS" { [System.Drawing.Color]::Green }
            default   { [System.Drawing.Color]::Black }
        }
        $script:logTextBox.SelectionStart  = $script:logTextBox.TextLength
        $script:logTextBox.SelectionColor  = $color
        $script:logTextBox.AppendText("$logEntry`r`n")
        $script:logTextBox.ScrollToCaret()
    }

    Write-Host $logEntry -ForegroundColor $(
        switch ($Level) {
            "ERROR"   { "Red" }
            "WARN"    { "Yellow" }
            "SUCCESS" { "Green" }
            default   { "White" }
        }
    )
}

function Test-PS2EXE {
    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "Modulul PS2EXE nu este instalat. Doriti să îl instalăm acum?",
            "PS2EXE Lipsă",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log "Instalare modul PS2EXE..." "WARN"
            try {
                Install-Module ps2exe -Force -Scope CurrentUser -AllowClobber
                Import-Module ps2exe -Force
                Write-Log "PS2EXE instalat cu succes!" "SUCCESS"
                return $true
            }
            catch {
                Write-Log "Eroare la instalarea PS2EXE: $_" "ERROR"
                return $false
            }
        }
        return $false
    }
    Import-Module ps2exe -Force
    return $true
}

function Show-HelpDialog {
    $helpForm = New-Object System.Windows.Forms.Form
    $helpForm.Text           = "Ajutor – Universal PowerShell Builder"
    $helpForm.Size           = New-Object System.Drawing.Size(600,500)
    $helpForm.StartPosition  = "CenterParent"

    $helpText = New-Object System.Windows.Forms.RichTextBox
    $helpText.Multiline      = $true
    $helpText.ScrollBars     = "Vertical"
    $helpText.ReadOnly       = $true
    $helpText.Dock           = "Fill"
    $helpText.Font           = New-Object System.Drawing.Font("Segoe UI",10)
    $helpText.Text           = @"
UNIVERSAL POWERSHELL BUILDER v2.1
==================================

DESCRIERE:
Acest instrument permite compilarea mai multor fișiere PowerShell într-un singur executabil.

CARACTERISTICI PRINCIPALE:
• Suportă până la 7 fișiere sursă PowerShell
• Interfață grafică intuitivă
• Opțiuni de compilare personalizabile
• Salvare/încărcare configurații
• Log detaliat al procesului de build

UTILIZARE:
1. Adăugați fișierele sursă (maxim 7)
   - Click pe 'Adaugă Fișier' sau
   - Drag & drop direct în listă

2. Configurați setările:
   - No Console Window: Ascunde fereastra consolei
   - Require Administrator: Solicită drepturi admin
   - Completați metadatele (opțional)

3. Specificați fișierul de ieșire (.exe)

4. Click pe 'Start Compile'

SHORTCUTS:
• Ctrl+B - Start Build
• Ctrl+S - Salvează Configurația
• Ctrl+O - Încarcă Configurație
• F1 - Acest ajutor

CERINȚE:
• PowerShell 5.0 sau mai nou
• Modulul PS2EXE (se instalează automat)

NOTĂ:
Ordinea fișierelor este importantă! Folosiți butoanele 
'Mută Sus/Jos' pentru a organiza corect secvența de execuție.

Pentru suport sau raportare probleme, contactați dezvoltatorul.
"@

    $helpForm.Controls.Add($helpText)
    $helpForm.ShowDialog()
}

function Start-BuildProcess {
    Write-Log "=== Început proces build ===" "INFO"

    if ($script:sourceFiles.Count -eq 0) {
        Write-Log "Nu au fost selectate fișiere sursă!" "ERROR"
        [System.Windows.Forms.MessageBox]::Show(
            "Vă rog selectați cel puțin un fișier sursă!",
            "Eroare",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return
    }
    if (-not $script:outputPathTextBox.Text) {
        Write-Log "Nu a fost specificat fișierul de ieșire!" "ERROR"
        [System.Windows.Forms.MessageBox]::Show(
            "Vă rog specificați calea fișierului de ieșire!",
            "Eroare",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return
    }
    if (-not (Test-PS2EXE)) {
        return
    }

    try {
        $script:startButton.Enabled = $false
        $script:progressBar.Value = 0
        $script:progressBar.Visible = $true

        $tempDir = Join-Path $env:TEMP "PSBuilder_$(Get-Date -Format 'yyyyMMddHHmmss')"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        Write-Log "Director temporar creat: $tempDir"

        $script:progressBar.Value = 20

        $combinedPath    = Join-Path $tempDir "combined.ps1"
        $combinedContent = @"
<#
    $($script:buildSettings.ProductName)
    Version: $($script:buildSettings.Version)
    Build: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Company: $($script:buildSettings.CompanyName)
    Copyright: $($script:buildSettings.Copyright)
    Description: $($script:buildSettings.Description)
#>
"@

        foreach ($file in $script:sourceFiles) {
            if (Test-Path $file) {
                $fileName = Split-Path $file -Leaf
                Write-Log "Procesare fișier: $fileName"
                $content = Get-Content $file -Raw -Encoding UTF8
                $combinedContent += "`n# === Început $fileName ===`n"
                $combinedContent += $content
                $combinedContent += "`n# === Sfârșit $fileName ===`n"
            }
            else {
                throw "Fișierul $file nu există!"
            }
        }
        $combinedContent | Out-File $combinedPath -Encoding UTF8
        Write-Log "Fișiere combinate cu succes"

        $script:progressBar.Value = 50

        $ps2exeParams = @{
            InputFile    = $combinedPath
            OutputFile   = $script:outputPathTextBox.Text
            NoConsole    = $script:noConsoleCheckBox.Checked
            NoOutput     = $true
            NoError      = $true
            NoConfigFile = $true
            STA          = $true
        }
        if ($script:requireAdminCheckBox.Checked)   { $ps2exeParams.RequireAdmin = $true }
        if ($script:buildSettings.IconPath -and (Test-Path $script:buildSettings.IconPath)) {
            $ps2exeParams.IconFile = $script:buildSettings.IconPath
        }
        if ($script:buildSettings.Version)     { $ps2exeParams.Version   = $script:buildSettings.Version }
        if ($script:buildSettings.CompanyName) { $ps2exeParams.Company   = $script:buildSettings.CompanyName }
        if ($script:buildSettings.ProductName) { $ps2exeParams.Product   = $script:buildSettings.ProductName }
        if ($script:buildSettings.Copyright)   { $ps2exeParams.Copyright = $script:buildSettings.Copyright }
        if ($script:buildSettings.Description) { $ps2exeParams.Description = $script:buildSettings.Description }

        $script:progressBar.Value = 70

        Write-Log "Începe compilarea..." "INFO"
        Invoke-ps2exe @ps2exeParams -ErrorAction Stop

        $script:progressBar.Value = 90

        if (Test-Path $script:outputPathTextBox.Text) {
            $fileInfo = Get-Item $script:outputPathTextBox.Text
            Write-Log "Build finalizat cu succes!" "SUCCESS"
            Write-Log "Fișier creat: $($fileInfo.FullName)" "SUCCESS"
            Write-Log "Dimensiune: $([math]::Round($fileInfo.Length / 1MB, 2)) MB" "INFO"

            $infoPath = Join-Path (Split-Path $script:outputPathTextBox.Text -Parent) "build_info.txt"
            $infoContent = @"
Build Information
================
Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Output: $($script:outputPathTextBox.Text)
Size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB

Source Files:
$($script:sourceFiles | ForEach-Object { "- $_" } | Out-String)

Settings:
- No Console: $($script:noConsoleCheckBox.Checked)
- Require Admin: $($script:requireAdminCheckBox.Checked)
- Version: $($script:buildSettings.Version)
- Product: $($script:buildSettings.ProductName)
- Company: $($script:buildSettings.CompanyName)
"@
            $infoContent | Out-File $infoPath -Encoding UTF8
            Write-Log "Fișier info salvat: $infoPath" "INFO"

            $result = [System.Windows.Forms.MessageBox]::Show(
                "Build finalizat cu succes! Doriți să deschideți folder-ul cu fișierul creat?",
                "Succes",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                Start-Process explorer.exe -ArgumentList "/select,$($script:outputPathTextBox.Text)"
            }
        }
        else {
            throw "Executabilul nu a fost creat!"
        }

        $script:progressBar.Value = 100
        Remove-Item $tempDir -Recurse -Force
        Write-Log "Fișiere temporare șterse"
    }
    catch {
        Write-Log "EROARE: $($_.Exception.Message)" "ERROR"
        [System.Windows.Forms.MessageBox]::Show(
            "Eroare la build: $($_.Exception.Message)",
            "Eroare",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
    finally {
        $script:startButton.Enabled = $true
        $script:progressBar.Visible = $false
    }
}

# === Creare interfață grafică ===
$mainForm = New-Object System.Windows.Forms.Form
$mainForm.Text             = "Universal PowerShell Builder v2.1"
$mainForm.Size             = New-Object System.Drawing.Size(900,800)
$mainForm.StartPosition    = "CenterScreen"
$mainForm.FormBorderStyle  = "FixedSingle"
$mainForm.MaximizeBox      = $false

# === Panel superior – Fișiere sursă ===
$filesGroupBox = New-Object System.Windows.Forms.GroupBox
$filesGroupBox.Text     = ""
$filesGroupBox.Text     = "Fișiere Sursă (maxim 7)"
$filesGroupBox.Location = New-Object System.Drawing.Point(10,30)
$filesGroupBox.Size     = New-Object System.Drawing.Size(860,180)

$filesListBox = New-Object System.Windows.Forms.ListBox
$filesListBox.Location      = New-Object System.Drawing.Point(10,25)
$filesListBox.Size          = New-Object System.Drawing.Size(650,140)
$filesListBox.SelectionMode = "One"

$addFileButton = New-Object System.Windows.Forms.Button
$addFileButton.Text     = "Adaugă Fișier"
$addFileButton.Location = New-Object System.Drawing.Point(670,25)
$addFileButton.Size     = New-Object System.Drawing.Size(180,30)
$addFileButton.Add_Click({
    if ($script:sourceFiles.Count -ge 7) {
        [System.Windows.Forms.MessageBox]::Show(
            "Puteți adăuga maxim 7 fișiere!",
            "Limită atinsă",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "PowerShell Scripts (*.ps1)|*.ps1|All Files (*.*)|*.*"
    $ofd.Title  = "Selectați fișier PowerShell"
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:sourceFiles += $ofd.FileName
        $filesListBox.Items.Add((Split-Path $ofd.FileName -Leaf))
        Write-Log "Fișier adăugat: $(Split-Path $ofd.FileName -Leaf)" "INFO"
    }
})

$removeFileButton = New-Object System.Windows.Forms.Button
$removeFileButton.Text     = "Elimină Fișier"
$removeFileButton.Location = New-Object System.Drawing.Point(670,60)
$removeFileButton.Size     = New-Object System.Drawing.Size(180,30)
$removeFileButton.Add_Click({
    if ($filesListBox.SelectedIndex -ge 0) {
        $removedFile = $script:sourceFiles[$filesListBox.SelectedIndex]
        $script:sourceFiles = $script:sourceFiles | Where-Object { $_ -ne $removedFile }
        $filesListBox.Items.RemoveAt($filesListBox.SelectedIndex)
        Write-Log "Fișier eliminat" "INFO"
    }
})

$moveUpButton = New-Object System.Windows.Forms.Button
$moveUpButton.Text     = "↑ Mută Sus"
$moveUpButton.Location = New-Object System.Drawing.Point(670,100)
$moveUpButton.Size     = New-Object System.Drawing.Size(85,30)
$moveUpButton.Add_Click({
    $i = $filesListBox.SelectedIndex
    if ($i -gt 0) {
        $tmp = $script:sourceFiles[$i]
        $script:sourceFiles[$i] = $script:sourceFiles[$i-1]
        $script:sourceFiles[$i-1] = $tmp
        $item = $filesListBox.Items[$i]
        $filesListBox.Items.RemoveAt($i)
        $filesListBox.Items.Insert($i-1, $item)
        $filesListBox.SelectedIndex = $i-1
    }
})

$moveDownButton = New-Object System.Windows.Forms.Button
$moveDownButton.Text     = "↓ Mută Jos"
$moveDownButton.Location = New-Object System.Drawing.Point(765,100)
$moveDownButton.Size     = New-Object System.Drawing.Size(85,30)
$moveDownButton.Add_Click({
    $i = $filesListBox.SelectedIndex
    if ($i -ge 0 -and $i -lt $filesListBox.Items.Count - 1) {
        $tmp = $script:sourceFiles[$i]
        $script:sourceFiles[$i] = $script:sourceFiles[$i+1]
        $script:sourceFiles[$i+1] = $tmp
        $item = $filesListBox.Items[$i]
        $filesListBox.Items.RemoveAt($i)
        $filesListBox.Items.Insert($i+1, $item)
        $filesListBox.SelectedIndex = $i+1
    }
})

$clearAllButton = New-Object System.Windows.Forms.Button
$clearAllButton.Text     = "Șterge Tot"
$clearAllButton.Location = New-Object System.Drawing.Point(670,135)
$clearAllButton.Size     = New-Object System.Drawing.Size(180,30)
$clearAllButton.Add_Click({
    $script:sourceFiles = @()
    $filesListBox.Items.Clear()
    Write-Log "Toate fișierele au fost eliminate" "INFO"
})

$filesGroupBox.Controls.AddRange(@(
    $filesListBox, $addFileButton, $removeFileButton,
    $moveUpButton, $moveDownButton, $clearAllButton
))

# === Panel mijloc – Setări ===
$settingsGroupBox = New-Object System.Windows.Forms.GroupBox
$settingsGroupBox.Text     = "Setări Build"
$settingsGroupBox.Location = New-Object System.Drawing.Point(10,220)
$settingsGroupBox.Size     = New-Object System.Drawing.Size(860,200)

$script:noConsoleCheckBox = New-Object System.Windows.Forms.CheckBox
$script:noConsoleCheckBox.Text    = "No Console Window"
$script:noConsoleCheckBox.Location= New-Object System.Drawing.Point(10,25)
$script:noConsoleCheckBox.Size    = New-Object System.Drawing.Size(200,25)
$script:noConsoleCheckBox.Checked = $true

$script:requireAdminCheckBox = New-Object System.Windows.Forms.CheckBox
$script:requireAdminCheckBox.Text    = "Require Administrator"
$script:requireAdminCheckBox.Location= New-Object System.Drawing.Point(10,55)
$script:requireAdminCheckBox.Size    = New-Object System.Drawing.Size(200,25)

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text     = "Fișier Ieșire (.exe):"
$outputLabel.Location = New-Object System.Drawing.Point(10,90)
$outputLabel.Size     = New-Object System.Drawing.Size(120,20)

$script:outputPathTextBox = New-Object System.Windows.Forms.RichTextBox
$script:outputPathTextBox.Location= New-Object System.Drawing.Point(10,110)
$script:outputPathTextBox.Size    = New-Object System.Drawing.Size(300,25)

$browseOutputButton = New-Object System.Windows.Forms.Button
$browseOutputButton.Text     = "Browse..."
$browseOutputButton.Location = New-Object System.Drawing.Point(320,108)
$browseOutputButton.Size     = New-Object System.Drawing.Size(80,25)
$browseOutputButton.Add_Click({
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter     = "Executable Files (*.exe)|*.exe"
    $sfd.Title      = "Salvare fișier executabil"
    $sfd.DefaultExt = "exe"
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:outputPathTextBox.Text = $sfd.FileName
    }
})

$iconLabel = New-Object System.Windows.Forms.Label
$iconLabel.Text     = "Icon (opțional):"
$iconLabel.Location = New-Object System.Drawing.Point(10,140)
$iconLabel.Size     = New-Object System.Drawing.Size(120,20)

$iconPathTextBox = New-Object System.Windows.Forms.RichTextBox
$iconPathTextBox.Location = New-Object System.Drawing.Point(10,160)
$iconPathTextBox.Size = New-Object System.Drawing.Size(300,25)
$iconPathTextBox.ReadOnly = $true

$browseIconButton = New-Object System.Windows.Forms.Button
$browseIconButton.Text     = "Browse..."
$browseIconButton.Location = New-Object System.Drawing.Point(320,158)
$browseIconButton.Size     = New-Object System.Drawing.Size(80,25)
$browseIconButton.Add_Click({
    $ofd2 = New-Object System.Windows.Forms.OpenFileDialog
    $ofd2.Filter = "Icon Files (*.ico)|*.ico"
    $ofd2.Title  = "Selectați fișier icon"
    if ($ofd2.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $iconPathTextBox.Text          = $ofd2.FileName
        $script:buildSettings.IconPath = $ofd2.FileName
    }
})

$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text     = "Versiune:"
$versionLabel.Location = New-Object System.Drawing.Point(420,25)
$versionLabel.Size     = New-Object System.Drawing.Size(100,20)

$versionTextBox = New-Object System.Windows.Forms.RichTextBox
$versionTextBox.Text     = "1.0.0"
$versionTextBox.Location = New-Object System.Drawing.Point(530,22)
$versionTextBox.Size     = New-Object System.Drawing.Size(150,25)
$versionTextBox.Add_TextChanged({ $script:buildSettings.Version = $versionTextBox.Text })

$productLabel = New-Object System.Windows.Forms.Label
$productLabel.Text     = "Nume Produs:"
$productLabel.Location = New-Object System.Drawing.Point(420,55)
$productLabel.Size     = New-Object System.Drawing.Size(100,20)

$productTextBox = New-Object System.Windows.Forms.RichTextBox
$productTextBox.Location            = New-Object System.Drawing.Point(530,52)
$productTextBox.Size                = New-Object System.Drawing.Size(320,25)
$productTextBox.Add_TextChanged({ $script:buildSettings.ProductName = $productTextBox.Text })

$companyLabel = New-Object System.Windows.Forms.Label
$companyLabel.Text     = "Companie:"
$companyLabel.Location = New-Object System.Drawing.Point(420,85)
$companyLabel.Size     = New-Object System.Drawing.Size(100,20)

$companyTextBox = New-Object System.Windows.Forms.RichTextBox
$companyTextBox.Location             = New-Object System.Drawing.Point(530,82)
$companyTextBox.Size                 = New-Object System.Drawing.Size(320,25)
$companyTextBox.Add_TextChanged({ $script:buildSettings.CompanyName = $companyTextBox.Text })

$copyrightLabel = New-Object System.Windows.Forms.Label
$copyrightLabel.Text     = "Copyright:"
$copyrightLabel.Location = New-Object System.Drawing.Point(420,115)
$copyrightLabel.Size     = New-Object System.Drawing.Size(100,20)

$copyrightTextBox = New-Object System.Windows.Forms.RichTextBox
$copyrightTextBox.Text     = "© $(Get-Date -Format 'yyyy')"
$copyrightTextBox.Location = New-Object System.Drawing.Point(530,112)
$copyrightTextBox.Size     = New-Object System.Drawing.Size(320,25)
$copyrightTextBox.Add_TextChanged({ $script:buildSettings.Copyright = $copyrightTextBox.Text })

$descriptionLabel = New-Object System.Windows.Forms.Label
$descriptionLabel.Text     = "Descriere:"
$descriptionLabel.Location = New-Object System.Drawing.Point(420,145)
$descriptionLabel.Size     = New-Object System.Drawing.Size(100,20)

$descriptionTextBox = New-Object System.Windows.Forms.RichTextBox
$descriptionTextBox.Location = New-Object System.Drawing.Point(530,142)
$descriptionTextBox.Size     = New-Object System.Drawing.Size(320,40)
$descriptionTextBox.Multiline    = $true
$descriptionTextBox.Add_TextChanged({ $script:buildSettings.Description = $descriptionTextBox.Text })

$settingsGroupBox.Controls.AddRange(@(
    $script:noConsoleCheckBox, $script:requireAdminCheckBox,
    $outputLabel, $script:outputPathTextBox, $browseOutputButton,
    $iconLabel, $iconPathTextBox, $browseIconButton,
    $versionLabel, $versionTextBox,
    $productLabel, $productTextBox,
    $companyLabel, $companyTextBox,
    $copyrightLabel, $copyrightTextBox,
    $descriptionLabel, $descriptionTextBox
))

# === Panel Log ===
$logGroupBox = New-Object System.Windows.Forms.GroupBox
$logGroupBox.Text     = "Log Build"
$logGroupBox.Location = New-Object System.Drawing.Point(10,430)
$logGroupBox.Size     = New-Object System.Drawing.Size(860,180)

$script:logTextBox = New-Object System.Windows.Forms.RichTextBox
$script:logTextBox.Location  = New-Object System.Drawing.Point(10,20)
$script:logTextBox.Size      = New-Object System.Drawing.Size(840,150)
$script:logTextBox.Multiline = $true
$script:logTextBox.ScrollBars= "Vertical"
$script:logTextBox.ReadOnly  = $true
$script:logTextBox.Font      = New-Object System.Drawing.Font("Consolas",9)

$logGroupBox.Controls.Add($script:logTextBox)

# === ProgressBar & Controls ===
$script:progressBar            = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Location   = New-Object System.Drawing.Point(10,600)
$script:progressBar.Size       = New-Object System.Drawing.Size(860,20)
$script:progressBar.Style      = "Continuous"
$script:progressBar.Visible    = $false

$script:startButton            = New-Object System.Windows.Forms.Button
$script:startButton.Text       = "▶ Start Compile"
$script:startButton.Location   = New-Object System.Drawing.Point(250,670)
$script:startButton.Size       = New-Object System.Drawing.Size(180,40)
$script:startButton.Font       = New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold)
$script:startButton.BackColor  = [System.Drawing.Color]::LightGreen
$script:startButton.Add_Click({ Start-BuildProcess })

$saveConfigButton = New-Object System.Windows.Forms.Button
$saveConfigButton.Text     = "💾 Salvează Config"
$saveConfigButton.Location = New-Object System.Drawing.Point(60,670)
$saveConfigButton.Size     = New-Object System.Drawing.Size(150,40)
$saveConfigButton.Add_Click({
    $sfd2 = New-Object System.Windows.Forms.SaveFileDialog
    $sfd2.Filter = "JSON Files (*.json)|*.json"
    $sfd2.Title  = "Salvare configurație"
    if ($sfd2.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $config = @{
            SourceFiles = $script:sourceFiles
            OutputPath  = $script:outputPathTextBox.Text
            Settings    = $script:buildSettings
            NoConsole   = $script:noConsoleCheckBox.Checked
            RequireAdmin= $script:requireAdminCheckBox.Checked
        }
        $config | ConvertTo-Json -Depth 3 | Out-File $sfd2.FileName -Encoding UTF8
        Write-Log "Configurație salvată: $($sfd2.FileName)" "SUCCESS"
    }
})

$loadConfigButton = New-Object System.Windows.Forms.Button
$loadConfigButton.Text     = "📂 Încarcă Config"
$loadConfigButton.Location = New-Object System.Drawing.Point(470,670)
$loadConfigButton.Size     = New-Object System.Drawing.Size(150,40)
$loadConfigButton.Add_Click({
    $ofd3 = New-Object System.Windows.Forms.OpenFileDialog
    $ofd3.Filter = "JSON Files (*.json)|*.json"
    $ofd3.Title  = "Încărcare configurație"
    if ($ofd3.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $config = Get-Content $ofd3.FileName -Raw | ConvertFrom-Json
            $script:sourceFiles = @($config.SourceFiles)
            $filesListBox.Items.Clear()
            foreach ($f in $script:sourceFiles) {
                $filesListBox.Items.Add((Split-Path $f -Leaf))
            }
            $script:outputPathTextBox.Text        = $config.OutputPath
            $script:noConsoleCheckBox.Checked     = $config.NoConsole
            $script:requireAdminCheckBox.Checked  = $config.RequireAdmin
            $script:buildSettings                 = $config.Settings
            $versionTextBox.Text                  = $config.Settings.Version
            $productTextBox.Text                  = $config.Settings.ProductName
            $companyTextBox.Text                  = $config.Settings.CompanyName
            $copyrightTextBox.Text                = $config.Settings.Copyright
            $descriptionTextBox.Text              = $config.Settings.Description
            $iconPathTextBox.Text                 = $config.Settings.IconPath
            Write-Log "Configurație încărcată cu succes!" "SUCCESS"
        }
        catch {
            Write-Log "Eroare la încărcarea configurației: $_" "ERROR"
        }
    }
})

$exitButton            = New-Object System.Windows.Forms.Button
$exitButton.Text       = "❌ Exit"
$exitButton.Location   = New-Object System.Drawing.Point(660,670)
$exitButton.Size       = New-Object System.Drawing.Size(150,40)
$exitButton.BackColor  = [System.Drawing.Color]::LightCoral
$exitButton.Add_Click({ $mainForm.Close() })

$mainForm.Controls.AddRange(@(
    $filesGroupBox,
    $settingsGroupBox,
    $logGroupBox,
    $script:progressBar,
    $script:startButton,
    $saveConfigButton,
    $loadConfigButton,
    $exitButton
))

# === Inițializare ===
Write-Log "Universal PowerShell Builder v2.1 pornit" "INFO"
Write-Log "Verificare mediu..." "INFO"
if (Get-Module -ListAvailable -Name ps2exe) {
    Write-Log "PS2EXE detectat ✓" "SUCCESS"
}
else {
    Write-Log "PS2EXE nu este instalat. Va fi necesar pentru compilare." "WARN"
}

# === Drag & Drop ===
$filesListBox.AllowDrop = $true
$filesListBox.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$filesListBox.Add_DragDrop({
    param($sender, $e)
    $files = $e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    foreach ($f in $files) {
        if ($f -like "*.ps1" -and $script:sourceFiles.Count -lt 4) {
            if ($script:sourceFiles -notcontains $f) {
                $script:sourceFiles += $f
                $filesListBox.Items.Add((Split-Path $f -Leaf))
                Write-Log "Fișier adăugat prin drag & drop: $(Split-Path $f -Leaf)" "INFO"
            }
        }
    }
})

# === Shortcuts și Help ===
$mainForm.KeyPreview = $true
$mainForm.Add_KeyDown({
    param($sender, $e)
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::B) {
        if ($script:startButton.Enabled) { Start-BuildProcess }
    }
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::S) {
        $saveConfigButton.PerformClick()
    }
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::O) {
        $loadConfigButton.PerformClick()
    }
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F1) {
        Show-HelpDialog
    }
})

# === Tooltips ===
$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.SetToolTip($script:noConsoleCheckBox,     "Execuția fără fereastră de consolă vizibilă")
$tooltip.SetToolTip($script:requireAdminCheckBox,  "Executabilul va solicita drepturi de administrator")
$tooltip.SetToolTip($addFileButton,               "Adaugă un fișier PowerShell la proiect (Maxim 4)")
$tooltip.SetToolTip($removeFileButton,            "Elimină fișierul selectat din listă")
$tooltip.SetToolTip($moveUpButton,                "Mută fișierul selectat mai sus în ordine")
$tooltip.SetToolTip($moveDownButton,              "Mută fișierul selectat mai jos în ordine")
$tooltip.SetToolTip($clearAllButton,              "Șterge toate fișierele din listă")
$tooltip.SetToolTip($browseOutputButton,          "Selectează locația și numele pentru executabilul generat")
$tooltip.SetToolTip($browseIconButton,            "Selectează o iconiță pentru executabil (opțional)")
$tooltip.SetToolTip($saveConfigButton,            "Salvează configurația curentă pentru utilizare ulterioară")
$tooltip.SetToolTip($loadConfigButton,            "Încarcă o configurație salvată anterior")
$tooltip.SetToolTip($script:startButton,          "Începe procesul de compilare (Ctrl+B)")

# === Menu Bar ===
$menuBar = New-Object System.Windows.Forms.MenuStrip

$fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$fileMenu.Text = "&File"

$newProjectItem = New-Object System.Windows.Forms.ToolStripMenuItem
$newProjectItem.Text        = "&New Project"
$newProjectItem.ShortcutKeys= [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::N
$newProjectItem.Add_Click({
    $res = [System.Windows.Forms.MessageBox]::Show(
        "Doriți să creați un proiect nou? Toate setările curente vor fi pierdute.",
        "Proiect Nou",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($res -eq [System.Windows.Forms.DialogResult]::Yes) {
        $script:sourceFiles = @()
        $filesListBox.Items.Clear()
        $script:outputPathTextBox.Clear()
        $script:noConsoleCheckBox.Checked    = $true
        $script:requireAdminCheckBox.Checked = $false
        $versionTextBox.Text                 = "1.0.0"
        $productTextBox.Clear()
        $companyTextBox.Clear()
        $copyrightTextBox.Text               = "© $(Get-Date -Format 'yyyy')"
        $descriptionTextBox.Clear()
        $iconPathTextBox.Clear()
        $script:logTextBox.Clear()
        Write-Log "Proiect nou creat" "INFO"
    }
})


# 1. Creează item-ul “New Project”
$newProjectItem = New-Object System.Windows.Forms.ToolStripMenuItem
$newProjectItem.Text         = "&New Project"
$newProjectItem.ShortcutKeys = [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::N
$newProjectItem.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Doriți să creați un proiect nou? Toate setările curente vor fi pierdute.",
        "Proiect Nou",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        # reset controale…
    }
})

# 2. Separator
$separatorMenuItem = New-Object System.Windows.Forms.ToolStripSeparator

# 3. Creează item-ul “Exit”
$exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitMenuItem.Text         = "E&xit"
$exitMenuItem.ShortcutKeys = [System.Windows.Forms.Keys]::Alt -bor [System.Windows.Forms.Keys]::F4
$exitMenuItem.Add_Click({ $mainForm.Close() })

# 4. Adaugă-le în File menu
$fileMenu.DropDownItems.AddRange(@(
    $newProjectItem,
    $separatorMenuItem,
    $exitMenuItem
))



$toolsMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$toolsMenu.Text = "&Tools"

$clearLogItem = New-Object System.Windows.Forms.ToolStripMenuItem
$clearLogItem.Text = "Clear &Log"
$clearLogItem.Add_Click({
    $script:logTextBox.Clear()
    Write-Log "Log șters" "INFO"
})


$testPS2EXE = New-Object System.Windows.Forms.ToolStripMenuItem
$testPS2EXE.Text = "Test PS2EXE Installation"
$testPS2EXE.Add_Click({
    if (Test-PS2EXE) {
        $versionInfo = "Versiune necunoscută"
        try {
            $ver = (Get-Module ps2exe).Version
            if ($ver) {
                $versionInfo = "Versiune PS2EXE: $ver"
            }
        }
        catch {
            $versionInfo = "Versiunea nu a putut fi determinată"
        }

        [System.Windows.Forms.MessageBox]::Show(
            "PS2EXE este instalat și funcțional!`n$versionInfo",
            "Test Reușit",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    }
})


$toolsMenu.DropDownItems.AddRange(@($clearLogItem, $testPS2EXE))

$helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$helpMenu.Text = "&Help"

$helpItem = New-Object System.Windows.Forms.ToolStripMenuItem
$helpItem.Text        = "&Help"
$helpItem.ShortcutKeys= [System.Windows.Forms.Keys]::F1
$helpItem.Add_Click({ Show-HelpDialog })

$aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem
$aboutItem.Text = "&About"
$aboutItem.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "Universal PowerShell Builder v2.1`n`nInstrument pentru compilarea scripturilor PowerShell.`n`nDezvoltat cu PowerShell și PS2EXE`n`n© 2025",
        "Despre",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
})

$helpMenu.DropDownItems.AddRange(@($helpItem, $aboutItem))

$menuBar.Items.AddRange(@($fileMenu, $toolsMenu, $helpMenu))
$mainForm.MainMenuStrip = $menuBar
$mainForm.Controls.Add($menuBar)

# === Status Bar ===
$statusBar   = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Pregătit"
$statusBar.Items.Add($statusLabel)
$mainForm.Controls.Add($statusBar)

# === Confirmare la închidere ===
$mainForm.Add_FormClosing({
    param($sender, $e)
    if ($script:sourceFiles.Count -gt 0) {
        $res = [System.Windows.Forms.MessageBox]::Show(
            "Aveți fișiere nesalvate în proiect. Sigur doriți să ieșiți?",
            "Confirmare Ieșire",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($res -eq [System.Windows.Forms.DialogResult]::No) {
            $e.Cancel = $true
        }
    }
})

Write-Log "Aplicația este pregătită pentru utilizare" "SUCCESS"
Write-Log "Folosiți F1 pentru ajutor sau Ctrl+B pentru compilare rapidă" "INFO"

[System.Windows.Forms.Application]::Run($mainForm)
