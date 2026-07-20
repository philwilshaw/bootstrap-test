# Commit all changes and push to the dev branch (triggers Cloud Run deploy via GitHub Actions).
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne "dev") {
    git checkout dev | Out-Null
}

$status = git status --porcelain
if ($status) {
    git add -A
    $msg = if ($args.Count -gt 0) { $args -join " " } else { "Auto-push to dev $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" }
    git commit -m $msg
}

git push origin dev
Write-Host "Pushed to dev — GitHub Actions will deploy to Cloud Run."
