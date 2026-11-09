[CmdletBinding()]
param(
    [string]$Profile = "default",
    [string]$Region = "ap-southeast-2"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-AwsJson {
    param([string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & aws @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        $details = ($output -join [Environment]::NewLine).Trim()
        throw "AWS CLI command failed (exit code $exitCode): $details"
    }
    $jsonOutput = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join [Environment]::NewLine
    return ($jsonOutput | ConvertFrom-Json)
}

function Assert-SecretDoesNotExist {
    param([string]$SecretName, [string[]]$AwsOptions)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $probe = & aws secretsmanager describe-secret --secret-id $SecretName @AwsOptions 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -eq 0) {
        throw "Secret '$SecretName' already exists. This script will not overwrite it."
    }

    $probeText = $probe -join [Environment]::NewLine
    if ($probeText -notmatch "ResourceNotFoundException") {
        throw "Could not safely check whether '$SecretName' exists. AWS CLI said: $probeText"
    }
}

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    throw "AWS CLI was not found on PATH. Install AWS CLI v2 and open a new PowerShell window."
}

$appId = (Read-Host "GitHub App ID").Trim()
$installationId = (Read-Host "GitHub App installation ID").Trim()
$privateKeyPath = (Read-Host "Path to the downloaded GitHub App private key PEM").Trim().Trim('"')

if ($appId -notmatch '^\d+$') { throw "The GitHub App ID must contain digits only." }
if ($installationId -notmatch '^\d+$') { throw "The installation ID must contain digits only." }
if (-not (Test-Path -LiteralPath $privateKeyPath -PathType Leaf)) {
    throw "Private key file was not found: $privateKeyPath"
}

$privateKey = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $privateKeyPath).Path)
if ([string]::IsNullOrWhiteSpace($privateKey) -or $privateKey -notmatch "BEGIN .*PRIVATE KEY") {
    throw "The selected file does not look like a PEM private key."
}

$awsOptions = @("--region", $Region, "--output", "json")
if (-not [string]::IsNullOrWhiteSpace($Profile)) {
    $awsOptions += @("--profile", $Profile)
}

$identity = Invoke-AwsJson (@("sts", "get-caller-identity") + $awsOptions)
Write-Host "AWS account: $($identity.Account)"
Write-Host "AWS region:  $Region"
$confirmation = Read-Host "Type the AWS account ID above to create the two secrets"
if ($confirmation -cne [string]$identity.Account) {
    throw "Account confirmation did not match. No secrets were created."
}

$appSecretName = "pr-goblin/github-app"
$webhookSecretName = "pr-goblin/webhook"
Assert-SecretDoesNotExist -SecretName $appSecretName -AwsOptions $awsOptions
Assert-SecretDoesNotExist -SecretName $webhookSecretName -AwsOptions $awsOptions

$randomBytes = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $rng.GetBytes($randomBytes)
}
finally {
    $rng.Dispose()
}
$webhookSecret = [Convert]::ToBase64String($randomBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
[Array]::Clear($randomBytes, 0, $randomBytes.Length)

$appSecretJson = [ordered]@{
    app_id          = $appId
    installation_id = $installationId
    private_key_pem = $privateKey
} | ConvertTo-Json -Depth 4

$tempDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("pr-goblin-secrets-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempDirectory | Out-Null
$appSecretFile = Join-Path $tempDirectory "github-app.json"
$webhookSecretFile = Join-Path $tempDirectory "webhook.txt"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

try {
    [System.IO.File]::WriteAllText($appSecretFile, $appSecretJson, $utf8NoBom)
    [System.IO.File]::WriteAllText($webhookSecretFile, $webhookSecret, $utf8NoBom)

    $appSecret = Invoke-AwsJson (@(
        "secretsmanager", "create-secret",
        "--name", $appSecretName,
        "--description", "PR Goblin GitHub App credentials",
        "--secret-string", "file://$appSecretFile"
    ) + $awsOptions)

    $webhookSecretResult = Invoke-AwsJson (@(
        "secretsmanager", "create-secret",
        "--name", $webhookSecretName,
        "--description", "PR Goblin GitHub webhook HMAC secret",
        "--secret-string", "file://$webhookSecretFile"
    ) + $awsOptions)

    Write-Host ""
    Write-Host "Created Secrets Manager secrets:"
    Write-Host "APP_CREDENTIALS_SECRET_ARN=$($appSecret.ARN)"
    Write-Host "WEBHOOK_SECRET_ARN=$($webhookSecretResult.ARN)"
    Write-Host ""
    Write-Host "Set this webhook secret on your GitHub App now (shown once):"
    Write-Host $webhookSecret
    Write-Host ""
    Write-Host "Add the two ARNs as GitHub Actions variables. Keep the webhook secret value in GitHub App settings and AWS Secrets Manager; do not commit it or paste it into chat."
}
finally {
    if (Test-Path -LiteralPath $tempDirectory) {
        Remove-Item -LiteralPath $tempDirectory -Recurse -Force
    }
    $privateKey = $null
    $appSecretJson = $null
    $webhookSecret = $null
}

