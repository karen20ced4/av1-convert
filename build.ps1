#Builder Version 1.0
[CmdletBinding()]
param()

# === Configurare ===
$buildConfig = @{
    Version = "6.8"
    BuildDir = ".\build-v6.8"
    OutputName = "AV1-Converter-v6.8.exe"
    NoConsole = $true
}

function Write-BuildLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARN"  { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

# === Pregătire mediu ===
try {
    Write-BuildLog "=== Început proces build AV1 Converter v$($buildConfig.Version) ==="
    
    # Verifică PS2EXE
    if (-not (Get-Module -ListAvailable -Name ps2exe)) {
        Write-BuildLog "Instalare modul PS2EXE..." "WARN"
        Install-Module ps2exe -Force -Scope CurrentUser -AllowClobber
    }
    Import-Module ps2exe -Force
    
    # Creare director build
    if (-not (Test-Path $buildConfig.BuildDir)) {
        New-Item -ItemType Directory -Path $buildConfig.BuildDir -Force | Out-Null
    }
    Write-BuildLog "Director build creat: $($buildConfig.BuildDir)"

    # Combină fișierele sursă
    $combinedPath = Join-Path $buildConfig.BuildDir "combined.ps1"
    $sourceFiles = @(
        ".\av1-convert.ps1"
        ".\engine.ps1"
    )

    $combinedContent = @"
<#
    AV1 Converter v$($buildConfig.Version)
    Build: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
#>

"@

    foreach ($file in $sourceFiles) {
        if (Test-Path $file) {
            $content = Get-Content $file -Raw -Encoding UTF8
            $combinedContent += "`n# === Început $file ===`n"
            $combinedContent += $content
            $combinedContent += "`n# === Sfârșit $file ===`n"
            Write-BuildLog "Procesat: $file"
        }
        else {
            throw "Fișierul $file nu există!"
        }
    }

    $combinedContent | Out-File $combinedPath -Encoding UTF8
    Write-BuildLog "Fișierele au fost combinate în: $combinedPath"

    # Creare README
    $readmePath = Join-Path $buildConfig.BuildDir "README.txt"
    $readmeContent = @"
AV1 Converter v$($buildConfig.Version)
Build generat la: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Fișiere incluse:
- $($buildConfig.OutputName)
- combined.ps1 (cod sursă combinat)
"@
    $readmeContent | Out-File $readmePath -Encoding UTF8
    Write-BuildLog "README generat: $readmePath"

    # Compilare în EXE
    $outputPath = Join-Path $buildConfig.BuildDir $buildConfig.OutputName
    Write-BuildLog "Creare executabil: $outputPath"

    $ps2exeParams = @{
        InputFile = $combinedPath
        OutputFile = $outputPath
        NoConsole = $buildConfig.NoConsole
        NoOutput = $true
        NoError = $true
        NoConfigFile = $true
        STA = $true
    }

    # Rulează PS2EXE
    Write-BuildLog "Compilare..." "INFO"
    Invoke-ps2exe @ps2exeParams -ErrorAction Stop

    # Verifică rezultatul
    if (Test-Path $outputPath) {
        Write-BuildLog "Executabil creat cu succes în: $outputPath" "SUCCESS"
    }
    else {
        throw "Executabilul nu a fost creat!"
    }

    # Curățare fișier temporar
    Remove-Item $combinedPath -Force
    Write-BuildLog "Fișier combinat eliminat: $combinedPath"

    Write-BuildLog "=== Build finalizat cu succes! ===" "SUCCESS"
}
catch {
    Write-BuildLog "EROARE: $($_.Exception.Message)" "ERROR"
    Write-BuildLog "Stack Trace: $($_.ScriptStackTrace)" "ERROR"
    exit 1
}
