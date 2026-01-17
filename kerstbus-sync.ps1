<#
Kerstbus Modrinth Sync (first-time setup + subsequent pulls + pre-backup)

What it does:
- Finds Modrinth profiles under: %APPDATA%\ModrinthApp\profiles
- Lets the user pick a profile folder
- Optional ZIP backup of the selected profile BEFORE syncing
- First run (no .git): installs Git + Git LFS (via winget), git init -b main, sets remote, fetches + hard-resets to remote + LFS
- Next runs (.git exists): fetch + hard-reset to remote + LFS
- Overwrites tracked files to match remote
- Does NOT delete untracked files (files not in git)

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

  if (Get-Command $ExeName -ErrorAction SilentlyContinue) { return }

  Require-Winget
  & winget install --id $WingetId --exact --silent --accept-source-agreements --accept-package-agreements | Out-Host

  # Refresh PATH from registry after installation
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machinePath;$userPath"

  if (-not (Get-Command $ExeName -ErrorAction SilentlyContinue)) {
    throw "Installed $WingetId but $ExeName is not on PATH. Close/reopen the terminal and run the script again."
  }
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

function New-ProfileBackupZip {
  param([Parameter(Mandatory=$true)][string]$ProfilePath)

  $profileName = Split-Path -Path $ProfilePath -Leaf
  $backupRoot  = Join-Path (Split-Path -Path $ProfilePath -Parent) "_backups"
  New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null

  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $zipPath   = Join-Path $backupRoot ("{0}-{1}.zip" -f $profileName, $timestamp)

  $temp = Join-Path $env:TEMP ("kerstbus-backup-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temp -Force | Out-Null
  $staging = Join-Path $temp $profileName

  Copy-Item -LiteralPath $ProfilePath -Destination $staging -Recurse -Force

  $nestedBackups = Join-Path $staging "_backups"
  if (Test-Path -LiteralPath $nestedBackups) {
    Remove-Item -LiteralPath $nestedBackups -Recurse -Force
  }

  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $true)

  Remove-Item -LiteralPath $temp -Recurse -Force
  Write-Host "Backup created: $zipPath"
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
    $r = Invoke-Git @("init","-b",$Branch)
    $r.Output | Out-Host
    if ($r.ExitCode -ne 0) { throw "git init failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")" }
  }

  $r = Invoke-Git @("remote")
  $hasOrigin = ($r.Output | Select-String -SimpleMatch "origin") -ne $null

  if (-not $hasOrigin) {
    $r = Invoke-Git @("remote","add","origin",$RepoUrl)
    $r.Output | Out-Host
    if ($r.ExitCode -ne 0) { throw "git remote add failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")" }
  } else {
    $r = Invoke-Git @("remote","set-url","origin",$RepoUrl)
    $r.Output | Out-Host
    if ($r.ExitCode -ne 0) { throw "git remote set-url failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")" }
  }
}

function Ensure-LfsReady {
  $r = Invoke-Git @("lfs","install")
  $r.Output | Out-Host
  if ($r.ExitCode -ne 0) { throw "git lfs install failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")" }
}

function Sync-ToRemote {
  param([Parameter(Mandatory=$true)][string]$BranchName)

  Write-Host "Fetching from repository..."
  $r = Invoke-Git @("fetch","--prune","origin",$BranchName)
  $r.Output | Out-Host
  if ($r.ExitCode -ne 0) {
    throw "git fetch failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")"
  }

  Write-Host "Overwriting tracked files to match origin/$BranchName (keeping untracked files)..."
  $r = Invoke-Git @("reset","--hard","origin/$BranchName")
  $r.Output | Out-Host
  if ($r.ExitCode -ne 0) {
    throw "git reset --hard failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")"
  }

  # Important: do NOT run git clean -fd (would delete untracked files)

  Write-Host "Pulling LFS files..."
  $r = Invoke-Git @("lfs","pull")
  $r.Output | Out-Host
  if ($r.ExitCode -ne 0) {
    throw "git lfs pull failed with exit code: $($r.ExitCode)`n$(@($r.Output) -join "`n")"
  }
}

# --- Main ---
try {
  $profilePath = Select-ModrinthProfileFolder
  Write-Host "Selected profile: $profilePath"

  Write-Host "Checking for required software..."
  Ensure-AppInstalled -ExeName "git"     -WingetId "Git.Git"
  Ensure-AppInstalled -ExeName "git-lfs" -WingetId "GitHub.GitLFS"

  $createBackup = Read-Host "Create backup before syncing? (Y/N)"
  if ($createBackup -match '^[Yy]') {
    Write-Host "Creating backup..."
    New-ProfileBackupZip -ProfilePath $profilePath
  } else {
    Write-Host "Skipping backup..."
  }

  Write-Host "Setting up repository..."
  Ensure-RepoSetup -Path $profilePath
  Ensure-LfsReady

  Write-Host "Syncing with repository..."
  Sync-ToRemote -BranchName $Branch

  Write-Host "Done. Profile is up to date."
} catch {
  Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "`nFull error details:" -ForegroundColor Yellow
  Write-Host $_.Exception | Format-List -Force
  Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
}

Read-Host "`nPress Enter to exit"
