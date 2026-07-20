$ErrorActionPreference = "SilentlyContinue"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

if (-not (Test-Path ".git")) { exit 0 }

$branch = (git rev-parse --abbrev-ref HEAD 2>$null)
if ($branch -ne "dev") {
    git checkout dev 2>$null
    if ($LASTEXITCODE -ne 0) { exit 0 }
}

$status = git status --porcelain 2>$null
if ($status) {
    git add -A
    $msg = "Auto-push to dev $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
    git commit -m $msg 2>$null
}

git push origin dev 2>$null
exit 0
