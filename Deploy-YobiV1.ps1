#Requires -Version 5.1
<#
Yobi V1 - Local bootstrap deploy orchestrator

Runs Terraform (unless -SkipTerraform), checks GitHub Actions push builds and their exact ECR image tags,
prepares Kubernetes Secrets, and bootstraps ArgoCD GitOps.
Git push is performed separately after Terraform; this script waits for push-triggered GitHub Actions.
  See OPERATIONS.md for the exact Terraform -> Push -> GitOps order.

Examples (from the project root):
  .\Deploy-YobiV1.ps1                  # Terraform apply + full bootstrap
  .\Deploy-YobiV1.ps1 -SkipTerraform   # AWS infrastructure already exists

REQUIREMENTS:
- Run from Windows PowerShell 5.1+ or PowerShell 7+ with aws, terraform, kubectl, gh and git on PATH, authenticated GitHub CLI, AWS profile eks-user.
- Existing files: terraform/, msa/<service>/Dockerfile, msa/<service>/k8s/depl_svc.yml,
  msa/product/k8s/product-sa.yml, create-yobi-v1-db-secret.ps1.
- RDS master user password must be managed through AWS Secrets Manager.
- Script assumes service names, account, region, cluster and K8s Secret keys
  found in Yobi V1 as of 2026-10-12.
#>
[CmdletBinding()]
param(
    [switch]$SkipTerraform,
    [switch]$SkipActionsWait,
    [string]$AwsProfile = 'eks-user',
    [string]$AwsRegion = 'ap-northeast-2',
    [string]$ExpectedAccountId = '021158485482',
    [string]$ClusterName = 'sales-mall-dev-eks',
    [string]$RepositoryPrefix = 'sales-mall-dev',
    [string]$Namespace = 'soldesk',
    [int]$RolloutTimeoutSeconds = 300,
    [int]$ActionsTimeoutSeconds = 3600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 5.1 sends text into native programs using $OutputEncoding.
# Ensure UTF-8 text is preserved when applying manifest content via stdin.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Root = $PSScriptRoot
$TerraformDir = Join-Path $Root 'terraform'
$MsaDir = Join-Path $Root 'msa'
$HpaDir = Join-Path (Join-Path $MsaDir 'k8s') 'k8s-hpa'
$DbSecretScript = Join-Path $Root 'create-yobi-v1-db-secret.ps1'
$Services = @('apigateway', 'member', 'product', 'ordering', 'frontend')
$Registry = "${ExpectedAccountId}.dkr.ecr.${AwsRegion}.amazonaws.com"
$GitHubRepo = 'yobi84-sy/msa'
$WorkflowName = 'deploy-yobi-gitops.yml'

function Assert-ExitCode([string]$Action) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Action failed (exit code $LASTEXITCODE). Check the preceding command output."
    }
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Require-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file not found: $Path"
    }
}

function Get-SecretJson([string]$Name) {
    $result = & kubectl get secret $Name -n $Namespace --ignore-not-found -o json
    Assert-ExitCode "kubectl get secret $Name"
    $raw = ($result | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Assert-SecretKeys([string]$Name, [string[]]$Keys) {
    $secret = Get-SecretJson $Name
    if ($null -eq $secret) { throw "Kubernetes Secret missing: $Namespace/$Name" }
    foreach ($key in $Keys) {
        if ($null -eq $secret.data -or $null -eq $secret.data.PSObject.Properties[$key]) {
            throw "Kubernetes Secret $Namespace/$Name has no key '$key'."
        }
    }
}

function Apply-MemorySecret([string]$Name, [hashtable]$Values) {
    $data = @{}
    foreach ($item in $Values.GetEnumerator()) {
        $data[$item.Key] = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$item.Value))
    }
    $object = @{
        apiVersion = 'v1'
        kind = 'Secret'
        metadata = @{ name = $Name; namespace = $Namespace }
        type = 'Opaque'
        data = $data
    }
    $manifest = $object | ConvertTo-Json -Depth 6 -Compress
    try {
        $manifest | & kubectl apply --server-side --field-manager=yobi-v1-bootstrap -f -
        Assert-ExitCode "Apply Kubernetes Secret $Name"
    }
    finally {
        Remove-Variable manifest,object,data -ErrorAction SilentlyContinue
    }
}

function New-RandomBase64([int]$LengthInBytes) {
    $bytes = New-Object byte[] $LengthInBytes
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
        return [Convert]::ToBase64String($bytes)
    }
    finally {
        $random.Dispose()
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Ensure-AppSecrets {
    Write-Host '[SECRETS] Synchronizing RDS credentials via Secrets Manager...'
    # This is the existing project script; it does not write the DB password to disk.
    & $DbSecretScript -AwsProfile $AwsProfile -AwsRegion $AwsRegion -ClusterName $ClusterName -Namespace $Namespace
    if (-not $?) { throw 'DB Secret script failed.' }
    Assert-SecretKeys 'my-app-secrets' @('DB_HOST', 'DB_PW')

    if ($null -eq (Get-SecretJson 'jwt-secrets')) {
        Write-Host '[SECRETS] Creating random JWT/refresh JWT keys (not printed)...'
        $jwt = New-RandomBase64 64
        $refresh = New-RandomBase64 64
        try {
            Apply-MemorySecret 'jwt-secrets' @{
                JWT_SECRET_KEY = $jwt
                JWT_REFRESH_SECRET_KEY = $refresh
            }
        }
        finally { Remove-Variable jwt,refresh -ErrorAction SilentlyContinue }
    }
    Assert-SecretKeys 'jwt-secrets' @('JWT_SECRET_KEY', 'JWT_REFRESH_SECRET_KEY')

    if ($null -eq (Get-SecretJson 'admin-bootstrap')) {
        Write-Host '[SECRETS] Set a NEW bootstrap admin password (input is hidden).'
        $secure = Read-Host 'ADMIN_BOOTSTRAP_PASSWORD' -AsSecureString
        if ($null -eq $secure -or $secure.Length -lt 12) {
            throw 'Admin bootstrap password must contain at least 12 characters.'
        }
        $ptr = [IntPtr]::Zero
        try {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
            Apply-MemorySecret 'admin-bootstrap' @{ ADMIN_BOOTSTRAP_PASSWORD = $plain }
        }
        finally {
            Remove-Variable plain,secure -ErrorAction SilentlyContinue
            if ($ptr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
            }
        }
    }
    Assert-SecretKeys 'admin-bootstrap' @('ADMIN_BOOTSTRAP_PASSWORD')
    Write-Host '[OK] All required MSA Secrets exist.'
}

# Build is triggered by push on yobi-v1; workflow_dispatch may not be available
# when the workflow file does not exist on GitHub's default branch.
function Get-PushBuildRun([string]$CommitSha) {
    $json = & gh api "repos/$GitHubRepo/actions/runs?branch=yobi-v1&event=push&per_page=50" --jq '.workflow_runs'
    Assert-ExitCode 'GitHub Actions push runs lookup'
    $runs = @(($json | Out-String | ConvertFrom-Json))
    return @($runs | Where-Object {
        $_.name -eq 'Yobi V1 - Build ECR and Update GitOps Manifests' -and
        $_.head_sha -eq $CommitSha
    } | Sort-Object created_at -Descending | Select-Object -First 1)
}

function Wait-PushBuild {
    $sha = (& git -C $Root rev-parse HEAD | Out-String).Trim()
    Assert-ExitCode 'Local Git HEAD'
    Write-Host "[ACTIONS] Waiting for successful yobi-v1 push build from commit $sha"
    Write-Host '[ACTIONS] After Terraform is ready, git push this commit to yobi-v1 from your safe push workflow.'
    $deadline = (Get-Date).AddSeconds($ActionsTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $matched = @(Get-PushBuildRun $sha)
        if ($matched.Count -gt 0) {
            $run = $matched[0]
            Write-Host "[ACTIONS] run=$($run.id), status=$($run.status), conclusion=$($run.conclusion)"
            if ($run.status -eq 'completed') {
                if ($run.conclusion -ne 'success') {
                    throw "GitHub Actions run $($run.id) failed: $($run.conclusion). Check: gh run view $($run.id) --repo $GitHubRepo --log-failed"
                }
                return
            }
        }
        Start-Sleep -Seconds 15
    }
    throw 'No successful GitHub Actions push build for current local commit. Push the reviewed yobi-v1 changes after Terraform and check workflow logs.'
}

function Ensure-GrafanaAdminSecret {
    & kubectl create namespace monitoring --dry-run=client -o yaml | & kubectl apply -f -
    Assert-ExitCode 'Ensure monitoring namespace'
    $found = (& kubectl get secret grafana-admin -n monitoring --ignore-not-found -o name | Out-String).Trim()
    Assert-ExitCode 'Grafana Secret lookup'
    if ($found) { return }
    Write-Host '[GRAFANA] Set a new monitoring admin password (12+ characters, hidden).'
    $secure = Read-Host 'GRAFANA_ADMIN_PASSWORD' -AsSecureString
    if ($null -eq $secure -or $secure.Length -lt 12) { throw 'Grafana password must have 12+ characters.' }
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $data = @{apiVersion='v1';kind='Secret';metadata=@{name='grafana-admin';namespace='monitoring'};type='Opaque';stringData=@{password=$plain}}
        ($data | ConvertTo-Json -Depth 6 -Compress) | & kubectl apply -f -
        Assert-ExitCode 'Grafana admin Secret'
    } finally {
        Remove-Variable plain,secure,data -ErrorAction SilentlyContinue
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
}

function Wait-Application([string]$Name, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $raw = & kubectl get application $Name -n argocd -o json --ignore-not-found
        Assert-ExitCode "ArgoCD Application $Name lookup"
        $json = ($raw | Out-String).Trim()
        if ($json) {
            $app = $json | ConvertFrom-Json
            # Newly created Applications may have no status/sync/health fields yet.
            # With StrictMode Latest, accessing those missing properties throws.
            $sync = 'Pending'
            $health = 'Pending'
            $statusNode = $app.PSObject.Properties['status']
            if ($null -ne $statusNode -and $null -ne $statusNode.Value) {
                $status = $statusNode.Value
                $syncNode = $status.PSObject.Properties['sync']
                if ($null -ne $syncNode -and $null -ne $syncNode.Value) {
                    $syncValue = $syncNode.Value.PSObject.Properties['status']
                    if ($null -ne $syncValue -and $syncValue.Value) { $sync = [string]$syncValue.Value }
                }
                $healthNode = $status.PSObject.Properties['health']
                if ($null -ne $healthNode -and $null -ne $healthNode.Value) {
                    $healthValue = $healthNode.Value.PSObject.Properties['status']
                    if ($null -ne $healthValue -and $healthValue.Value) { $health = [string]$healthValue.Value }
                }
            }
            Write-Host "[ARGOCD] $Name sync=$sync health=$health"
            if ($Name -eq 'msa-root' -and $sync -eq 'Synced') { return } # app-of-apps root has no guaranteed health status
            if ($Name -ne 'msa-root' -and $sync -eq 'Synced' -and $health -eq 'Healthy') { return }
        }
        Start-Sleep -Seconds 10
    }
    throw "ArgoCD $Name did not become Synced/Healthy. Check kubectl describe application $Name -n argocd."
}

# -------------------- PRE-FLIGHT (NO CLOUD CHANGES) --------------------
Write-Host '=== Yobi V1 automated bootstrap deployment ==='
Write-Host "Root: $Root"
Write-Host "AWS target: $ExpectedAccountId / $AwsRegion / $ClusterName"
Write-Host 'Image build trigger: push to yobi-v1, after Terraform infrastructure exists'
Write-Host 'Git push occurs from reviewed local code; this script waits for matching successful push run.'

foreach ($command in @('aws','terraform','kubectl','gh','git')) {
    Require-Command $command
}
if (-not (Test-Path -LiteralPath $TerraformDir -PathType Container)) { throw "Missing terraform/: $TerraformDir" }
if (-not (Test-Path -LiteralPath $MsaDir -PathType Container)) { throw "Missing msa/: $MsaDir" }
Require-File $DbSecretScript
Require-File (Join-Path (Join-Path (Join-Path $MsaDir 'product') 'k8s') 'product-sa.yml')
foreach ($service in $Services) {
    $folder = Join-Path $MsaDir $service
    Require-File (Join-Path $folder 'Dockerfile')
    Require-File (Join-Path (Join-Path $folder 'k8s') 'depl_svc.yml')
}
# Pre-flight all HPA manifests BEFORE Terraform or other cloud changes.
foreach ($service in $Services) {
    Require-File (Join-Path $HpaDir "${service}-hpa.yml")
}

$branch = (& git -C $Root branch --show-current | Out-String).Trim()
Assert-ExitCode 'Git branch lookup'
if ($branch -ne 'yobi-v1') { throw "Wrong branch '$branch'. Expected yobi-v1; main must remain untouched." }

$identity = (& aws sts get-caller-identity --profile $AwsProfile --region $AwsRegion --output json | Out-String | ConvertFrom-Json)
Assert-ExitCode 'AWS identity check'
if ($identity.Account -ne $ExpectedAccountId) {
    throw "AWS account mismatch. Expected $ExpectedAccountId, got $($identity.Account)."
}

& gh auth status --hostname github.com
Assert-ExitCode 'GitHub CLI authentication check'
& gh api repos/$GitHubRepo --jq .default_branch | Out-Null
Assert-ExitCode 'GitHub repository access check'

# -------------------- INFRASTRUCTURE --------------------
if ($SkipTerraform) {
    Write-Host '[TERRAFORM] Skipped because -SkipTerraform was specified.'
} else {
    Write-Host '[TERRAFORM] Initializing providers...'
    & terraform "-chdir=$TerraformDir" init -input=false
    Assert-ExitCode 'terraform init'
    # Keep human review, but use PowerShell Read-Host rather than Terraform's
    # stdin prompt (which can be lost in a GUI-launched child process).
    # Saved plan ensures the approved plan is exactly what gets applied.
    $planPath = Join-Path ([System.IO.Path]::GetTempPath()) ("yobi-v1-{0}.tfplan" -f ([Guid]::NewGuid().ToString('N')))
    try {
        Write-Host '[TERRAFORM] Building an execution plan (no cloud changes yet)...'
        & terraform "-chdir=$TerraformDir" plan -input=false "-out=$planPath"
        Assert-ExitCode 'terraform plan'

        Write-Host '[TERRAFORM] Review the plan ABOVE before approval.' -ForegroundColor Yellow
        $approval = Read-Host 'Type yes to apply this exact Terraform plan'
        if ($approval -cne 'yes') {
            throw 'Terraform apply cancelled: approval was not yes.'
        }

        Write-Host '[TERRAFORM] Applying the previously approved plan...'
        & terraform "-chdir=$TerraformDir" apply -input=false $planPath
        Assert-ExitCode 'terraform apply'
    }
    finally {
        # The saved plan may contain sensitive values; never retain it in the repo.
        if (Test-Path -LiteralPath $planPath -PathType Leaf) {
            Remove-Item -LiteralPath $planPath -Force
            Write-Host '[TERRAFORM] Temporary saved plan removed.'
        }
    }
}

# -------------------- AWS/EKS VALIDATION --------------------
$clusterArn = (& aws eks describe-cluster --name $ClusterName --region $AwsRegion --profile $AwsProfile --query 'cluster.arn' --output text | Out-String).Trim()
Assert-ExitCode 'EKS cluster lookup'
$clusterStatus = (& aws eks describe-cluster --name $ClusterName --region $AwsRegion --profile $AwsProfile --query 'cluster.status' --output text | Out-String).Trim()
Assert-ExitCode 'EKS status lookup'
if ($clusterStatus -ne 'ACTIVE') { throw "EKS is not ACTIVE (status: $clusterStatus)." }

& aws eks update-kubeconfig --name $ClusterName --region $AwsRegion --profile $AwsProfile
Assert-ExitCode 'aws eks update-kubeconfig'
$currentContext = (& kubectl config current-context | Out-String).Trim()
Assert-ExitCode 'kubectl current-context'
if ($currentContext -ne $clusterArn) { throw "Wrong kubectl context: $currentContext (expected $clusterArn)." }
& kubectl get namespace $Namespace -o name
Assert-ExitCode "Kubernetes namespace $Namespace"

foreach ($service in $Services) {
    $repository = "${RepositoryPrefix}-${service}"
    & aws ecr describe-repositories --repository-names $repository --region $AwsRegion --profile $AwsProfile --query 'repositories[0].repositoryName' --output text | Out-Null
    Assert-ExitCode "ECR repository $repository"
}

# -------------------- SECRETS & SERVICE ACCOUNT --------------------
Ensure-AppSecrets
$saPath = Join-Path (Join-Path (Join-Path $MsaDir 'product') 'k8s') 'product-sa.yml'
& kubectl apply -f $saPath
Assert-ExitCode 'Product IRSA ServiceAccount'

# -------------------- BUILD (GitHub PUSH -> ACTIONS -> ECR) --------------------
# Local commit must be pushed to yobi-v1 after Apply. Workflow push event builds
# all five on first workflow update, then only services changed in future.
if (-not $SkipActionsWait) { Wait-PushBuild }
# Verify the exact image tags that ArgoCD will read from Git, NOT just non-empty ECR repositories.
# GitHub Actions writes its unique tag to the manifest in yobi-v1 after image Push.
foreach ($service in $Services) {
    $repository = "${RepositoryPrefix}-${service}"
    $path = "msa/$service/k8s/depl_svc.yml"
    $gitopsRef = "repos/$GitHubRepo/contents/$path" + '?ref=yobi-v1'
    $contentBase64 = (& gh api $gitopsRef --jq '.content' | Out-String).Trim()
    Assert-ExitCode "GitOps manifest lookup $service"
    if (-not $contentBase64) { throw "Missing remote GitOps manifest: $path" }
    $content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($contentBase64))
    $expectedRepo = [regex]::Escape("${Registry}/${repository}")
    $tags = @([regex]::Matches($content, '(?m)^\s*image:\s*' + $expectedRepo + ':([^\s#]+)') | ForEach-Object { $_.Groups[1].Value })
    if ($tags.Count -ne 1) { throw "Exactly one ECR image tag expected in GitOps $path; got $($tags.Count)." }
    $tag = [string]$tags[0]
    $found = (& aws ecr describe-images --repository-name $repository --image-ids "imageTag=$tag" --profile $AwsProfile --region $AwsRegion --query 'imageDetails[0].imageDigest' --output text | Out-String).Trim()
    Assert-ExitCode "ECR tag verification $repository`:$tag"
    if (-not $found -or $found -eq 'None') { throw "ECR missing image for GitOps manifest: $repository`:$tag" }
    Write-Host "[ECR/GITOPS] $repository`:$tag digest=$found"
}

# -------------------- BOOTSTRAP ROOT ARGOCD + MONITORING --------------------
# Terraform owns Ingress/Service config/SSL for web, and ArgoCD Helm.
# Root ArgoCD Application owns only its TWO child Applications, not Terraform resources.
# yobi-v1-msa owns Deployments/Services/HPA; msa-monitoring owns Prometheus/Grafana.
Ensure-GrafanaAdminSecret
$legacy = @('msa-apigateway','msa-member','msa-product','msa-ordering','msa-frontend','msa-hpa','msa-services','msa-argocd')
foreach ($name in $legacy) {
    $exists = (& kubectl get application $name -n argocd --ignore-not-found -o name | Out-String).Trim()
    Assert-ExitCode "ArgoCD legacy ownership check $name"
    if ($exists) { throw "Conflicting legacy Application exists: $name. Do not delete blindly; inspect finalizers and resource ownership before migration." }
}
$rootApp = Join-Path $Root 'argocd/root-app.yml'
Require-File $rootApp
& kubectl apply -f $rootApp
Assert-ExitCode 'Bootstrap ArgoCD root Application'
foreach ($name in @('msa-root','yobi-v1-msa','msa-monitoring')) {
    Wait-Application $name $RolloutTimeoutSeconds
}

# -------------------- LIVE KUBERNETES VALIDATION --------------------
foreach ($service in $Services) {
    & kubectl rollout status "deployment/${service}-depl" -n $Namespace "--timeout=${RolloutTimeoutSeconds}s"
    Assert-ExitCode "Rollout $service"
}
foreach ($monitoring in @('prometheus','grafana')) {
    & kubectl rollout status "deployment/$monitoring" -n monitoring "--timeout=${RolloutTimeoutSeconds}s"
    Assert-ExitCode "Monitoring deployment $monitoring"
}
& kubectl rollout status daemonset/node-exporter -n monitoring "--timeout=${RolloutTimeoutSeconds}s"
Assert-ExitCode 'Node Exporter DaemonSet rollout'
& kubectl get pods,deployments,hpa -n $Namespace
Assert-ExitCode 'MSA state validation'
& kubectl get pods,services,ingress,certificate -n monitoring
Assert-ExitCode 'Monitoring state inspection'
& kubectl get applications -n argocd
Assert-ExitCode 'GitOps state inspection'
Write-Host '[SUCCESS] Actions ECR image tags, ArgoCD status, 5 MSA rollouts and monitoring rollouts checked.'
Write-Host '[NEXT] Confirm actual Prometheus targets, Grafana HTTPS, SNS email subscription and application behavior using OPERATIONS.md.'
Write-Host '[NOTE] These live checks have NOT been claimed complete by this script.'
