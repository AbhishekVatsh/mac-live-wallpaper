# Installs the latest Live Wallpaper for Windows and opens it.
# Usage (PowerShell): irm https://raw.githubusercontent.com/AbhishekVatsh/mac-live-wallpaper/main/windows/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster

$repo    = 'AbhishekVatsh/mac-live-wallpaper'
$url     = "https://github.com/$repo/releases/latest/download/LiveWallpaper-Windows.zip"
$target  = Join-Path $env:LOCALAPPDATA 'Programs\LiveWallpaper'
$tmp     = Join-Path ([IO.Path]::GetTempPath()) ("LiveWallpaper-" + [guid]::NewGuid())
$zip     = Join-Path $tmp 'LiveWallpaper-Windows.zip'

New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Write-Host 'Downloading Live Wallpaper...'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing

    Write-Host "Installing to $target..."
    # Stop a running copy so its files can be replaced. The new copy puts the wallpaper back.
    Get-Process -Name LiveWallpaper -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process -Name mpv -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like "$target*" } | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    if (Test-Path $target) { Remove-Item $target -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $target -Force

    # Start Menu shortcut, so it's in Start and search.
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Live Wallpaper.lnk'))
    $shortcut.TargetPath = Join-Path $target 'LiveWallpaper.exe'
    $shortcut.WorkingDirectory = $target
    $shortcut.Description = 'Use any video as a looping live wallpaper'
    $shortcut.Save()

    Start-Process (Join-Path $target 'LiveWallpaper.exe')
    Write-Host 'Done. Live Wallpaper is running. Look for its icon in the system tray, by the clock.'
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
