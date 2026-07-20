<#
.SYNOPSIS
  Bootstrap a new GCP + GitHub project the same way as Bedtime / hello-world.

.DESCRIPTION
  Collects every parameter up front, shows one confirmation, then runs the full
  setup non-interactively (gcloud --quiet). The only mid-flow pause is the
  required browser step to authorize the Cloud Build GitHub App.

  What this does:
    1. Create GCP project + link billing
    2. Enable APIs + IAM for Cloud Run / Cloud Build
    3. Scaffold a Flask hello-world app (if missing)
    4. Deploy Cloud Run services (dev + prod)
    5. Create GitHub repo, commit, push main + dev
    6. Create GitHub Actions deploy SA + secrets
    7. Create Cloud Build GitHub connection, link repo, create triggers

.EXAMPLE
  .\scripts\bootstrap-new-project.ps1

.EXAMPLE
  .\scripts\bootstrap-new-project.ps1 -AppName "my-app" -ProjectId "my-app-project-gcp" -Yes
#>
[CmdletBinding()]
param(
    [string]$AppName,
    [string]$ProjectId,
    [string]$ProjectDisplayName,
    [string]$BillingAccountId,
    [string]$Region = "europe-west1",
    [string]$RepoOwner,
    [string]$RepoName,
    [ValidateSet("public", "private")]
    [string]$RepoVisibility = "public",
    [string]$DevServiceName,
    [string]$ProdServiceName,
    [string]$GitHubConnectionName = "github-conn",
    [string]$SourceDir,
    [switch]$SkipScaffold,
    [switch]$SkipInitialDeploy,
    [switch]$SkipGitHub,
    [switch]$SkipCloudBuild,
    [switch]$SkipGitHubActions,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok([string]$Message) {
    Write-Host "    OK: $Message" -ForegroundColor Green
}

function Write-Warn([string]$Message) {
    Write-Host "    WARN: $Message" -ForegroundColor Yellow
}

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name. Install it and re-run."
    }
}

function Read-Default([string]$Prompt, [string]$Default) {
    if ([string]::IsNullOrWhiteSpace($Default)) {
        $value = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "A value is required for: $Prompt"
        }
        return $value.Trim()
    }
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

function Invoke-Gcloud {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GcloudArgs)
    & gcloud @GcloudArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gcloud failed ($LASTEXITCODE): gcloud $($GcloudArgs -join ' ')"
    }
}

function Test-GcloudQuiet {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GcloudArgs)
    & gcloud @GcloudArgs 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-Slug([string]$Value) {
    $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9-]+', '-' -replace '-+', '-' -replace '^-|-$', ''
    if ([string]::IsNullOrWhiteSpace($slug)) { throw "Could not derive a slug from '$Value'" }
    return $slug
}

function Ensure-File {
    param(
        [string]$Path,
        [string]$Content,
        [switch]$Overwrite
    )
    if ((Test-Path $Path) -and -not $Overwrite) {
        Write-Ok "Exists (kept): $Path"
        return
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
    Write-Ok "Wrote: $Path"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

Assert-Command "gcloud"
Assert-Command "git"

$gcloudAccount = (gcloud config get-value account 2>$null)
if ([string]::IsNullOrWhiteSpace($gcloudAccount) -or $gcloudAccount -eq "(unset)") {
    throw "gcloud is not authenticated. Run: gcloud auth login"
}

if (-not $SourceDir) {
    $SourceDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}
$SourceDir = (Resolve-Path $SourceDir).Path
Set-Location $SourceDir

# ---------------------------------------------------------------------------
# Collect parameters up front
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "New GCP + GitHub project bootstrap" -ForegroundColor White
Write-Host "Working directory: $SourceDir"
Write-Host "gcloud account:     $gcloudAccount"
Write-Host ""

if (-not $AppName) {
    $AppName = Read-Default "App / product name (e.g. bedtime)" ""
}
$appSlug = Get-Slug $AppName

if (-not $ProjectDisplayName) {
    $ProjectDisplayName = if ($Yes) { $AppName } else { Read-Default "GCP project display name" $AppName }
}

if (-not $ProjectId) {
    $defaultProjectId = "$appSlug-project-gcp"
    $ProjectId = if ($Yes) { $defaultProjectId } else { Read-Default "GCP project ID (globally unique)" $defaultProjectId }
}
$ProjectId = Get-Slug $ProjectId

if (-not $BillingAccountId) {
    $billingList = gcloud billing accounts list --filter="open=true" --format="value(name.basename())" 2>$null
    $billingDefault = @($billingList) | Select-Object -First 1
    if (-not $billingDefault) {
        throw "No open billing accounts found. Create/link one in GCP Console first."
    }
    $BillingAccountId = if ($Yes) { $billingDefault } else { Read-Default "Billing account ID" $billingDefault }
}
$BillingAccountId = $BillingAccountId -replace '^billingAccounts/', ''

if (-not $Region) {
    $Region = "europe-west1"
}
if (-not $Yes) {
    $Region = Read-Default "Cloud Run / Cloud Build region" $Region
}

if (-not $RepoOwner) {
    $ghUser = $null
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        $ghUser = (gh api user --jq .login 2>$null)
    }
    $defaultOwner = if ($ghUser) { $ghUser } else { "philwilshaw" }
    $RepoOwner = if ($Yes) { $defaultOwner } else { Read-Default "GitHub owner / org" $defaultOwner }
}

if (-not $RepoName) {
    $RepoName = if ($Yes) { $appSlug } else { Read-Default "GitHub repository name" $appSlug }
}

if (-not $Yes) {
    $RepoVisibility = Read-Default "GitHub visibility (public/private)" $RepoVisibility
    if ($RepoVisibility -notin @("public", "private")) {
        throw "RepoVisibility must be public or private"
    }
}

if (-not $ProdServiceName) {
    $ProdServiceName = $appSlug
}
if (-not $DevServiceName) {
    $DevServiceName = "$ProdServiceName-dev"
}
if (-not $Yes) {
    $ProdServiceName = Read-Default "Cloud Run prod service name" $ProdServiceName
    $DevServiceName = Read-Default "Cloud Run dev service name" $DevServiceName
}

$ProdServiceName = Get-Slug $ProdServiceName
$DevServiceName = Get-Slug $DevServiceName

Write-Host ""
Write-Host "========== CONFIRM ONCE ==========" -ForegroundColor Yellow
Write-Host " App name:            $AppName"
Write-Host " GCP project ID:      $ProjectId"
Write-Host " GCP display name:    $ProjectDisplayName"
Write-Host " Billing account:     $BillingAccountId"
Write-Host " Region:              $Region"
Write-Host " Cloud Run (dev):     $DevServiceName"
Write-Host " Cloud Run (prod):    $ProdServiceName"
Write-Host " GitHub:              $RepoOwner/$RepoName ($RepoVisibility)"
Write-Host " Source dir:          $SourceDir"
Write-Host " Skip scaffold:       $SkipScaffold"
Write-Host " Skip initial deploy: $SkipInitialDeploy"
Write-Host " Skip GitHub:         $SkipGitHub"
Write-Host " Skip Cloud Build:    $SkipCloudBuild"
Write-Host " Skip GitHub Actions: $SkipGitHubActions"
Write-Host "==================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "After you confirm, the script runs non-interactively."
Write-Host "You will only be paused once for Cloud Build GitHub browser auth (if needed)."
Write-Host ""

if (-not $Yes) {
    $confirm = Read-Host "Type YES to proceed"
    if ($confirm -ne "YES") {
        Write-Host "Aborted."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# 1) GCP project + billing
# ---------------------------------------------------------------------------

Write-Step "Create / select GCP project"
$projectExists = Test-GcloudQuiet projects describe $ProjectId
if ($projectExists) {
    Write-Ok "Project already exists: $ProjectId"
}
else {
    Invoke-Gcloud projects create $ProjectId --name=$ProjectDisplayName --quiet
    Write-Ok "Created project $ProjectId"
}

Invoke-Gcloud config set project $ProjectId --quiet
Invoke-Gcloud billing projects link $ProjectId --billing-account=$BillingAccountId --quiet
Write-Ok "Billing linked"

$projectNumber = (gcloud projects describe $ProjectId --format="value(projectNumber)").Trim()
if (-not $projectNumber) { throw "Could not resolve project number for $ProjectId" }
Write-Ok "Project number: $projectNumber"

# ---------------------------------------------------------------------------
# 2) APIs
# ---------------------------------------------------------------------------

Write-Step "Enable APIs"
$apis = @(
    "run.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "pubsub.googleapis.com",
    "containerregistry.googleapis.com",
    "cloudtrace.googleapis.com",
    "servicemanagement.googleapis.com",
    "serviceusage.googleapis.com"
)
Invoke-Gcloud services enable @apis --project=$ProjectId --quiet
Write-Ok "Core APIs enabled"

# ---------------------------------------------------------------------------
# 3) IAM
# ---------------------------------------------------------------------------

Write-Step "Configure IAM for Cloud Run / Cloud Build"
$computeSa = "$projectNumber-compute@developer.gserviceaccount.com"
$buildSa = "$projectNumber@cloudbuild.gserviceaccount.com"

foreach ($member in @("serviceAccount:$computeSa", "serviceAccount:$buildSa")) {
    foreach ($role in @("roles/run.admin", "roles/iam.serviceAccountUser")) {
        Invoke-Gcloud projects add-iam-policy-binding $ProjectId `
            --member=$member `
            --role=$role `
            --quiet | Out-Null
    }
}
Write-Ok "Granted run.admin + iam.serviceAccountUser to compute and Cloud Build SAs"

# ---------------------------------------------------------------------------
# 4) Scaffold app (optional)
# ---------------------------------------------------------------------------

if (-not $SkipScaffold) {
    Write-Step "Scaffold hello-world app files (skip existing)"

    $mainPy = @"
import os

from flask import Flask

app = Flask(__name__)

ENVIRONMENT = os.environ.get("ENVIRONMENT", "local")


@app.route("/")
def hello():
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$AppName — Hello World</title>
  <style>
    body {{
      font-family: system-ui, sans-serif;
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background: linear-gradient(160deg, #0f172a 0%, #1e293b 45%, #312e81 100%);
      color: #e2e8f0;
    }}
    main {{ text-align: center; padding: 2rem; }}
    h1 {{ font-size: clamp(2rem, 5vw, 3rem); margin-bottom: 0.5rem; }}
    .env {{
      display: inline-block;
      margin-top: 1rem;
      padding: 0.35rem 0.85rem;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.12);
      font-size: 0.95rem;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }}
  </style>
</head>
<body>
  <main>
    <h1>Hello, World!</h1>
    <p>Welcome to $AppName.</p>
    <span class="env">{ENVIRONMENT}</span>
  </main>
</body>
</html>"""


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
"@

    $cloudbuildDev = @"
substitutions:
  _SERVICE_NAME: $DevServiceName
  _ENVIRONMENT: dev
  _REGION: $Region

steps:
  - name: gcr.io/google.com/cloudsdktool/cloud-sdk
    entrypoint: gcloud
    args:
      - run
      - deploy
      - `${_SERVICE_NAME}
      - --source
      - .
      - --region
      - `${_REGION}
      - --allow-unauthenticated
      - --update-env-vars
      - ENVIRONMENT=`${_ENVIRONMENT}

options:
  logging: CLOUD_LOGGING_ONLY
"@

    $cloudbuildProd = @"
substitutions:
  _SERVICE_NAME: $ProdServiceName
  _ENVIRONMENT: prod
  _REGION: $Region

steps:
  - name: gcr.io/google.com/cloudsdktool/cloud-sdk
    entrypoint: gcloud
    args:
      - run
      - deploy
      - `${_SERVICE_NAME}
      - --source
      - .
      - --region
      - `${_REGION}
      - --allow-unauthenticated
      - --update-env-vars
      - ENVIRONMENT=`${_ENVIRONMENT}

options:
  logging: CLOUD_LOGGING_ONLY
"@

    $workflowDev = @"
name: Deploy to Dev

on:
  push:
    branches:
      - dev

env:
  SERVICE_NAME: $DevServiceName
  REGION: $Region
  ENVIRONMENT: dev

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          credentials_json: `${{ secrets.GCP_SA_KEY }}

      - name: Set up Cloud SDK
        uses: google-github-actions/setup-gcloud@v2

      - name: Deploy to Cloud Run (dev)
        run: |
          gcloud run deploy "`$SERVICE_NAME" \
            --source . \
            --region "`$REGION" \
            --project "`${{ secrets.GCP_PROJECT_ID }}" \
            --allow-unauthenticated \
            --set-env-vars "ENVIRONMENT=`$ENVIRONMENT"
"@

    $workflowProd = @"
name: Deploy to Prod

on:
  push:
    branches:
      - main

env:
  SERVICE_NAME: $ProdServiceName
  REGION: $Region
  ENVIRONMENT: prod

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          credentials_json: `${{ secrets.GCP_SA_KEY }}

      - name: Set up Cloud SDK
        uses: google-github-actions/setup-gcloud@v2

      - name: Deploy to Cloud Run (prod)
        run: |
          gcloud run deploy "`$SERVICE_NAME" \
            --source . \
            --region "`$REGION" \
            --project "`${{ secrets.GCP_PROJECT_ID }}" \
            --allow-unauthenticated \
            --set-env-vars "ENVIRONMENT=`$ENVIRONMENT"
"@

    Ensure-File (Join-Path $SourceDir "main.py") $mainPy
    Ensure-File (Join-Path $SourceDir "requirements.txt") "flask`ngunicorn`n"
    Ensure-File (Join-Path $SourceDir "cloudbuild.dev.yaml") $cloudbuildDev
    Ensure-File (Join-Path $SourceDir "cloudbuild.prod.yaml") $cloudbuildProd
    Ensure-File (Join-Path $SourceDir ".gitignore") "__pycache__/`n*.py[cod]`n.Python`n.env`n.venv/`nvenv/`n*.log`n"
    Ensure-File (Join-Path $SourceDir ".github\workflows\deploy-dev.yml") $workflowDev
    Ensure-File (Join-Path $SourceDir ".github\workflows\deploy-prod.yml") $workflowProd
}

# ---------------------------------------------------------------------------
# 5) Initial Cloud Run deploys
# ---------------------------------------------------------------------------

$devUrl = $null
$prodUrl = $null

if (-not $SkipInitialDeploy) {
    Write-Step "Deploy Cloud Run services (this can take several minutes)"
    Write-Host "    Deploying $DevServiceName ..."
    Invoke-Gcloud run deploy $DevServiceName `
        --source=. `
        --region=$Region `
        --project=$ProjectId `
        --allow-unauthenticated `
        --update-env-vars="ENVIRONMENT=dev" `
        --quiet
    $devUrl = (gcloud run services describe $DevServiceName --region=$Region --project=$ProjectId --format="value(status.url)").Trim()
    Write-Ok "Dev: $devUrl"

    Write-Host "    Deploying $ProdServiceName ..."
    Invoke-Gcloud run deploy $ProdServiceName `
        --source=. `
        --region=$Region `
        --project=$ProjectId `
        --allow-unauthenticated `
        --update-env-vars="ENVIRONMENT=prod" `
        --quiet
    $prodUrl = (gcloud run services describe $ProdServiceName --region=$Region --project=$ProjectId --format="value(status.url)").Trim()
    Write-Ok "Prod: $prodUrl"
}

# ---------------------------------------------------------------------------
# 6) GitHub repo + push
# ---------------------------------------------------------------------------

$repoUrl = "https://github.com/$RepoOwner/$RepoName"

if (-not $SkipGitHub) {
    Write-Step "GitHub repository + push"
    Assert-Command "gh"
    $authOk = $false
    try {
        gh auth status 2>$null | Out-Null
        $authOk = ($LASTEXITCODE -eq 0)
    } catch { $authOk = $false }
    if (-not $authOk) {
        throw "GitHub CLI is not logged in. Run: gh auth login   then re-run this script with the same answers (or -Yes)."
    }

    $repoExists = $false
    gh repo view "$RepoOwner/$RepoName" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $repoExists = $true }

    if (-not $repoExists) {
        if ($RepoVisibility -eq "private") {
            gh repo create "$RepoOwner/$RepoName" --private --description "$AppName"
        }
        else {
            gh repo create "$RepoOwner/$RepoName" --public --description "$AppName"
        }
        if ($LASTEXITCODE -ne 0) { throw "Failed to create GitHub repo $RepoOwner/$RepoName" }
        git remote remove origin 2>$null
        git remote add origin "https://github.com/$RepoOwner/$RepoName.git"
        Write-Ok "Created $repoUrl"
    }
    else {
        Write-Ok "Repo already exists: $repoUrl"
        $existingRemote = git remote get-url origin 2>$null
        if (-not $existingRemote) {
            git remote add origin "https://github.com/$RepoOwner/$RepoName.git"
        }
    }

    if (-not (Test-Path (Join-Path $SourceDir ".git"))) {
        git init | Out-Null
    }

    git add -A
    $pending = git status --porcelain
    if ($pending) {
        git commit -m "Bootstrap $AppName with Cloud Run + GitHub deploy configs."
        Write-Ok "Created commit"
    }
    else {
        # Ensure at least one commit exists
        $hasCommit = $true
        git rev-parse HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $hasCommit = $false }
        if (-not $hasCommit) {
            git commit --allow-empty -m "Bootstrap $AppName with Cloud Run + GitHub deploy configs."
        }
        Write-Ok "Working tree clean"
    }

    git branch -M main 2>$null
    git push -u origin main
    if ($LASTEXITCODE -ne 0) { throw "Failed to push main" }

    $onDev = (git branch --list dev)
    if (-not $onDev) {
        git checkout -b dev
    }
    else {
        git checkout dev
    }
    git push -u origin dev
    if ($LASTEXITCODE -ne 0) { throw "Failed to push dev" }
    Write-Ok "Pushed branches main and dev"
}

# ---------------------------------------------------------------------------
# 7) GitHub Actions deploy SA + secrets
# ---------------------------------------------------------------------------

if (-not $SkipGitHubActions -and -not $SkipGitHub) {
    Write-Step "GitHub Actions service account + secrets"
    Assert-Command "gh"

    $deploySa = "github-deploy@$ProjectId.iam.gserviceaccount.com"
    $saExists = Test-GcloudQuiet iam service-accounts describe $deploySa --project=$ProjectId
    if (-not $saExists) {
        Invoke-Gcloud iam service-accounts create github-deploy `
            --display-name="GitHub Actions deploy" `
            --project=$ProjectId `
            --quiet
        Write-Ok "Created $deploySa"
    }
    else {
        Write-Ok "Service account exists: $deploySa"
    }

    foreach ($role in @(
        "roles/run.admin",
        "roles/iam.serviceAccountUser",
        "roles/cloudbuild.builds.builder",
        "roles/artifactregistry.writer",
        "roles/storage.admin",
        "roles/logging.logWriter"
    )) {
        Invoke-Gcloud projects add-iam-policy-binding $ProjectId `
            --member="serviceAccount:$deploySa" `
            --role=$role `
            --quiet | Out-Null
    }

    $keyPath = Join-Path $env:TEMP "$ProjectId-github-deploy-key.json"
    try {
        Invoke-Gcloud iam service-accounts keys create $keyPath `
            --iam-account=$deploySa `
            --project=$ProjectId `
            --quiet
        Get-Content -Raw $keyPath | gh secret set GCP_SA_KEY --repo "$RepoOwner/$RepoName"
        if ($LASTEXITCODE -ne 0) { throw "Failed to set GCP_SA_KEY secret" }
        $ProjectId | gh secret set GCP_PROJECT_ID --repo "$RepoOwner/$RepoName"
        if ($LASTEXITCODE -ne 0) { throw "Failed to set GCP_PROJECT_ID secret" }
        Write-Ok "Set GitHub secrets GCP_SA_KEY and GCP_PROJECT_ID"
    }
    finally {
        if (Test-Path $keyPath) { Remove-Item -Force $keyPath }
    }
}

# ---------------------------------------------------------------------------
# 8) Cloud Build connection + triggers (one browser pause)
# ---------------------------------------------------------------------------

if (-not $SkipCloudBuild -and -not $SkipGitHub) {
    Write-Step "Cloud Build GitHub connection + triggers"

    $connExists = Test-GcloudQuiet builds connections describe $GitHubConnectionName `
        --region=$Region --project=$ProjectId

    if (-not $connExists) {
        Invoke-Gcloud builds connections create github $GitHubConnectionName `
            --region=$Region `
            --project=$ProjectId `
            --quiet
        Write-Ok "Created connection $GitHubConnectionName"
    }
    else {
        Write-Ok "Connection exists: $GitHubConnectionName"
    }

    $stage = (gcloud builds connections describe $GitHubConnectionName `
        --region=$Region --project=$ProjectId `
        --format="value(installationState.stage)").Trim()

    if ($stage -ne "COMPLETE") {
        $consoleUrl = "https://console.cloud.google.com/cloud-build/repositories/2nd-gen?project=$ProjectId"
        Write-Host ""
        Write-Host "---------- ONE BROWSER STEP REQUIRED ----------" -ForegroundColor Yellow
        Write-Host "Cloud Build GitHub auth cannot be fully automated."
        Write-Host "1. Open: $consoleUrl"
        Write-Host "2. Select project $ProjectId if needed"
        Write-Host "3. Complete Connect / authorize for GitHub (host connection: $GitHubConnectionName)"
        Write-Host "4. Wait until the connection shows as enabled / complete"
        Write-Host "------------------------------------------------" -ForegroundColor Yellow
        Write-Host ""
        try { Start-Process $consoleUrl } catch { }
        Read-Host "Press Enter after the connection shows COMPLETE / enabled"

        $stage = (gcloud builds connections describe $GitHubConnectionName `
            --region=$Region --project=$ProjectId `
            --format="value(installationState.stage)").Trim()
        if ($stage -ne "COMPLETE") {
            throw "Connection is still '$stage'. Finish browser auth and re-run with -SkipScaffold -SkipInitialDeploy (or only Cloud Build steps)."
        }
    }
    Write-Ok "GitHub connection COMPLETE"

    $repoResource = "projects/$ProjectId/locations/$Region/connections/$GitHubConnectionName/repositories/$RepoName"
    $linked = Test-GcloudQuiet builds repositories describe $RepoName `
        --connection=$GitHubConnectionName --region=$Region --project=$ProjectId
    if (-not $linked) {
        Invoke-Gcloud builds repositories create $RepoName `
            --remote-uri="https://github.com/$RepoOwner/$RepoName.git" `
            --connection=$GitHubConnectionName `
            --region=$Region `
            --project=$ProjectId `
            --quiet
        Write-Ok "Linked repository $RepoName"
    }
    else {
        Write-Ok "Repository already linked: $RepoName"
    }

    $computeSaResource = "projects/$ProjectId/serviceAccounts/$computeSa"

    function Ensure-Trigger {
        param(
            [string]$Name,
            [string]$Branch,
            [string]$Config
        )
        $exists = Test-GcloudQuiet builds triggers describe $Name --region=$Region --project=$ProjectId
        if ($exists) {
            Write-Ok "Trigger exists: $Name"
            return
        }
        Invoke-Gcloud builds triggers create github `
            --name=$Name `
            --repository=$repoResource `
            --branch-pattern=$Branch `
            --build-config=$Config `
            --region=$Region `
            --project=$ProjectId `
            --service-account=$computeSaResource `
            --quiet
        Write-Ok "Created trigger $Name ($Branch -> $Config)"
    }

    Ensure-Trigger -Name "deploy-dev" -Branch "^dev$" -Config "cloudbuild.dev.yaml"
    Ensure-Trigger -Name "deploy-prod" -Branch "^main$" -Config "cloudbuild.prod.yaml"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if (-not $devUrl -and -not $SkipInitialDeploy) {
    $devUrl = (gcloud run services describe $DevServiceName --region=$Region --project=$ProjectId --format="value(status.url)" 2>$null)
}
if (-not $prodUrl -and -not $SkipInitialDeploy) {
    $prodUrl = (gcloud run services describe $ProdServiceName --region=$Region --project=$ProjectId --format="value(status.url)" 2>$null)
}
if (-not $devUrl) {
    $devUrl = (gcloud run services describe $DevServiceName --region=$Region --project=$ProjectId --format="value(status.url)" 2>$null)
}
if (-not $prodUrl) {
    $prodUrl = (gcloud run services describe $ProdServiceName --region=$Region --project=$ProjectId --format="value(status.url)" 2>$null)
}

Write-Host ""
Write-Host "========== DONE ==========" -ForegroundColor Green
Write-Host " GCP project:   $ProjectId ($projectNumber)"
Write-Host " GitHub:        $repoUrl"
if ($devUrl)  { Write-Host " Dev URL:       $devUrl" }
if ($prodUrl) { Write-Host " Prod URL:      $prodUrl" }
Write-Host ""
Write-Host " Push to 'dev'  -> deploys $DevServiceName"
Write-Host " Push to 'main' -> deploys $ProdServiceName"
Write-Host "==========================" -ForegroundColor Green
