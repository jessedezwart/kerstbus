<#
Kerstbus Modrinth Sync (first-time setup + subsequent pulls)

What it does:
- Finds Modrinth profiles under: %APPDATA%\ModrinthApp\profiles
- Lets the user pick a profile folder
- First run (no .git): installs Git + Git LFS (via winget), git init -b main, sets remote, fetches + hard-resets to remote + LFS
- Next runs (.git exists): fetch + hard-reset to remote + LFS
- Overwrites all local files to match remote (deletes untracked files not in .gitignore)

Run:
powershell -ExecutionPolicy Bypass -File .\kerstbus-sync.ps1
#>

$ErrorActionPreference = "Stop"

# PowerShell 7+: prevent native stderr from being promoted to PowerShell errors
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$RepoUrl      = "https://github.com/jessedezwart/kerstbus.git"
$Branch       = "main"
$ProfilesRoot = Join-Path $env:APPDATA "ModrinthApp\profiles"

# Fancy CLI symbols
$script:CheckMark = "[+]"
$script:CrossMark = "[X]"
$script:Arrow     = ">>>"
$script:Bullet    = "  *"

function Write-Success {
  param([string]$Message)
  Write-Host "$script:CheckMark $Message" -ForegroundColor Green
}

function Write-Info {
  param([string]$Message)
  Write-Host "$script:Arrow $Message" -ForegroundColor Cyan
}

function Write-Error-Custom {
  param([string]$Message)
  Write-Host "$script:CrossMark $Message" -ForegroundColor Red
}

function Write-Step {
  param([string]$Message)
  Write-Host "`n$script:Arrow $Message" -ForegroundColor Yellow
}

function Require-Winget {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "winget is not available. Install 'App Installer' from the Microsoft Store or install Git/Git LFS manually."
  }
}

function Ensure-AppInstalled {
  param(
    [Parameter(Mandatory=$true)][string]$ExeName,
    [Parameter(Mandatory=$true)][string]$WingetId
  )

  if (Get-Command $ExeName -ErrorAction SilentlyContinue) { 
    Write-Success "$ExeName is installed"
    return 
  }

  Write-Info "Installing $ExeName..."
  Require-Winget
  & winget install --id $WingetId --exact --silent --accept-source-agreements --accept-package-agreements | Out-Host

  # Refresh PATH from registry after installation
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machinePath;$userPath"

  if (-not (Get-Command $ExeName -ErrorAction SilentlyContinue)) {
    throw "Installed $WingetId but $ExeName is not on PATH. Close/reopen the terminal and run the script again."
  }
  Write-Success "$ExeName installed successfully"
}

function Select-ModrinthProfileFolder {
  if (-not (Test-Path -LiteralPath $ProfilesRoot)) {
    throw "Modrinth profiles folder not found: $ProfilesRoot"
  }

  $dirs = Get-ChildItem -LiteralPath $ProfilesRoot -Directory | Sort-Object Name
  if (-not $dirs -or $dirs.Count -eq 0) {
    throw "No Modrinth profile folders found in: $ProfilesRoot"
  }

  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Select your Modrinth profile folder (e.g., KerstBus 25-26)"
    $dlg.SelectedPath = $ProfilesRoot
    $dlg.ShowNewFolderButton = $false
    $result = $dlg.ShowDialog()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and (Test-Path -LiteralPath $dlg.SelectedPath)) {
      $selectedPath = $dlg.SelectedPath
      $modsFolder = Join-Path $selectedPath "mods"
      if (-not (Test-Path -LiteralPath $modsFolder)) {
        throw "Selected folder does not appear to be a valid Modrinth profile (no 'mods' folder found): $selectedPath"
      }
      return $selectedPath
    }
  } catch {
    # fall back to console picker
  }

  Write-Host "Found Modrinth profiles in: $ProfilesRoot"
  for ($i=0; $i -lt $dirs.Count; $i++) {
    Write-Host ("[{0}] {1}" -f ($i+1), $dirs[$i].Name)
  }

  while ($true) {
    $choice = Read-Host "Choose a profile number"
    if ($choice -match '^\d+$') {
      $idx = [int]$choice
      if ($idx -ge 1 -and $idx -le $dirs.Count) {
        $selectedPath = $dirs[$idx-1].FullName
        $modsFolder = Join-Path $selectedPath "mods"
        if (-not (Test-Path -LiteralPath $modsFolder)) {
          Write-Host "Error: Selected folder does not appear to be a valid Modrinth profile (no 'mods' folder found)."
          Write-Host "Please choose a different profile."
          continue
        }
        return $selectedPath
      }
    }
    Write-Host "Invalid choice. Try again."
  }
}

function Invoke-Git {
  param([Parameter(Mandatory=$true)][string[]]$GitArgs)

  $ea = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & git @GitArgs 2>&1 | ForEach-Object { $_.ToString() }
    $code = $LASTEXITCODE
    return [PSCustomObject]@{ ExitCode = $code; Output = $out }
  } finally {
    $ErrorActionPreference = $ea
  }
}

function Ensure-RepoSetup {
  param([Parameter(Mandatory=$true)][string]$Path)

  Set-Location -LiteralPath $Path

  if (-not (Test-Path -LiteralPath ".git")) {
    Write-Info "Initializing git repository..."
    $r = Invoke-Git @("init","-b",$Branch)
    if ($r.ExitCode -ne 0) { throw "git init failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")" }
    Write-Success "Git initialized"
  }

  $r = Invoke-Git @("remote")
  $hasOrigin = ($r.Output | Select-String -SimpleMatch "origin") -ne $null

  if (-not $hasOrigin) {
    Write-Info "Adding remote origin..."
    $r = Invoke-Git @("remote","add","origin",$RepoUrl)
    if ($r.ExitCode -ne 0) { throw "git remote add failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")" }
    Write-Success "Remote configured"
  } else {
    $r = Invoke-Git @("remote","set-url","origin",$RepoUrl)
    if ($r.ExitCode -ne 0) { throw "git remote set-url failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")" }
  }
}

function Ensure-LfsReady {
  Write-Info "Configuring Git LFS..."
  $r = Invoke-Git @("lfs","install")
  if ($r.ExitCode -ne 0) { throw "git lfs install failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")" }
  Write-Success "Git LFS ready"
}

function Show-SyncPreview {
  param([Parameter(Mandatory=$true)][string]$BranchName)

  Write-Info "Analyzing changes..."

  # Check modified/deleted tracked files
  $r = Invoke-Git @("diff","--name-status","HEAD","origin/$BranchName")
  $trackedChanges = $r.Output | Where-Object { $_ -match '\S' }

  # Check untracked files that will be deleted
  $r = Invoke-Git @("clean","-fd","--dry-run")
  $untrackedFiles = $r.Output | Where-Object { $_ -match '^Would remove' } | ForEach-Object { $_ -replace '^Would remove ', '' }

  $hasChanges = $false
  $modCount = 0
  $addCount = 0
  $delCount = 0
  $remCount = 0

  if ($trackedChanges -and $trackedChanges.Count -gt 0) {
    $hasChanges = $true
    Write-Host ""
    Write-Host "=== FILES TO BE UPDATED ===" -ForegroundColor Yellow
    foreach ($line in $trackedChanges) {
      if ($line -match '^M\s+(.+)') {
        Write-Host "  [~] $($matches[1])" -ForegroundColor Yellow
        $modCount++
      } elseif ($line -match '^A\s+(.+)') {
        Write-Host "  [+] $($matches[1])" -ForegroundColor Green
        $addCount++
      } elseif ($line -match '^D\s+(.+)') {
        Write-Host "  [-] $($matches[1])" -ForegroundColor Red
        $delCount++
      } else {
        Write-Host "  $line"
      }
    }
  }

  if ($untrackedFiles -and $untrackedFiles.Count -gt 0) {
    $hasChanges = $true
    Write-Host ""
    Write-Host "=== UNTRACKED FILES TO BE REMOVED ===" -ForegroundColor Red
    foreach ($file in $untrackedFiles) {
      Write-Host "  [-] $file" -ForegroundColor Red
      $remCount++
    }
  }

  if (-not $hasChanges) {
    Write-Host ""
    Write-Success "No changes detected. Profile is already up to date."
    return $false
  }

  Write-Host ""
  Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
  if ($addCount -gt 0) { Write-Host "  [+] Added:    $addCount file(s)" -ForegroundColor Green }
  if ($modCount -gt 0) { Write-Host "  [~] Modified: $modCount file(s)" -ForegroundColor Yellow }
  if ($delCount -gt 0) { Write-Host "  [-] Deleted:  $delCount file(s)" -ForegroundColor Red }
  if ($remCount -gt 0) { Write-Host "  [-] Removed:  $remCount file(s)" -ForegroundColor Red }
  Write-Host ""
  
  $confirm = Read-Host "$script:Arrow Continue with sync? (Y/N)"
  return ($confirm -match '^[Yy]')
}

function Fetch-FromRemote {
  param([Parameter(Mandatory=$true)][string]$BranchName)

  $r = Invoke-Git @("fetch","--prune","origin",$BranchName)
  if ($r.ExitCode -ne 0) {
    throw "git fetch failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")"
  }
}

function Apply-SyncChanges {
  param([Parameter(Mandatory=$true)][string]$BranchName)

  Write-Info "Resetting to origin/$BranchName..."
  $r = Invoke-Git @("reset","--hard","origin/$BranchName")
  if ($r.ExitCode -ne 0) {
    throw "git reset --hard failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")"
  }
  Write-Success "Files updated"

  Write-Info "Removing untracked files..."
  $r = Invoke-Git @("clean","-fd")
  if ($r.ExitCode -ne 0) {
    throw "git clean failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")"
  }
  Write-Success "Untracked files removed"

  Write-Info "Pulling LFS files..."
  $r = Invoke-Git @("lfs","pull")
  if ($r.ExitCode -ne 0) {
    throw "git lfs pull failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")"
  }
  Write-Success "LFS files downloaded"
}

# --- Main ---
try {
  Write-Host "" 
  Write-Host "================================" -ForegroundColor Cyan
  Write-Host "   KERSTBUS SYNC TOOL" -ForegroundColor Cyan
  Write-Host "================================" -ForegroundColor Cyan
  Write-Host ""

  $profilePath = Select-ModrinthProfileFolder
  Write-Success "Selected profile: $profilePath"

  Write-Step "Checking for required software..."
  Ensure-AppInstalled -ExeName "git"     -WingetId "Git.Git"
  Ensure-AppInstalled -ExeName "git-lfs" -WingetId "GitHub.GitLFS"

  Write-Step "Setting up repository..."
  Ensure-RepoSetup -Path $profilePath
  Ensure-LfsReady
  Write-Success "Repository configured"

  Write-Step "Checking for updates..."
  Fetch-FromRemote -BranchName $Branch
  Write-Success "Updates fetched"

  if (-not (Show-SyncPreview -BranchName $Branch)) {
    Write-Host ""
    Write-Info "Sync cancelled or no changes needed."
  } else {
    Write-Step "Applying changes..."
    Apply-SyncChanges -BranchName $Branch
    Write-Host ""
    Write-Host "================================" -ForegroundColor Green
    Write-Success "Profile is up to date!"
    Write-Host "================================" -ForegroundColor Green
  }
} catch {
  Write-Host ""
  Write-Host "================================" -ForegroundColor Red
  Write-Error-Custom "$($_.Exception.Message)"
  Write-Host "================================" -ForegroundColor Red
  Write-Host ""
  Write-Host "Full error details:" -ForegroundColor Yellow
  Write-Host $_.Exception | Format-List -Force
  Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
}

Read-Host "`nPress Enter to exit"
