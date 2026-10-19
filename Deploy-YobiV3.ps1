#Requires -Version 5.1
<#
Yobi V3 standalone candidate. Run -CheckOnly (default) first.
Original V1 files are NOT imported or modified. No GUI integration assumed.
AWS execution is opt-in (-Execute) with explicit interactive approval.
Validated locally with mocked tests; real AWS end-to-end validation is pending.
#>
[CmdletBinding(DefaultParameterSetName='Check')]
param(
    [Parameter(ParameterSetName='Run',Mandatory=$true)][switch]$Execute,
    [Parameter(ParameterSetName='Check')][switch]$CheckOnly,
    [string]$ProjectRoot = $PSScriptRoot,
    [string]$AwsProfile = 'eks-user',
    [ValidateSet('ap-northeast-2')][string]$AwsRegion = 'ap-northeast-2',
    [switch]$PublishChanges,
    [switch]$SkipTerraform,
    [switch]$Resume,
    [ValidateRange(60,14400)][int]$ActionsTimeoutSeconds = 3600,
    [ValidateRange(60,3600)][int]$RolloutTimeoutSeconds = 900,
    [ValidateRange(30,1800)][int]$WebTimeoutSeconds = 600
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'YobiV3.Common.ps1')
. (Join-Path $PSScriptRoot 'YobiV3.Rollouts.ps1')
. (Join-Path $PSScriptRoot 'YobiV3.FirstInstall.ps1')
. (Join-Path $PSScriptRoot 'YobiV3.Catalog.ps1')
. (Join-Path $PSScriptRoot 'YobiV3.InstallNotifications.ps1')
$PSNativeCommandUseErrorActionPreference = $false
$OutputEncoding = New-Object Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$GitRoot = $Root
$TerraformDir = Join-Path $Root 'terraform'
$ExpectedAccountId = '021158485482'
$ClusterName = 'sales-mall-dev-eks'
$Namespace = 'soldesk'
$RepositoryPrefix = 'sales-mall-dev'
$GitHubRepo = 'yobi84-sy/msa'
$script:ProjectMutex = $null
$script:MutexHeld = $false
$hash = [Security.Cryptography.SHA256]::Create()
try { $key = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant())))).Replace('-','').Substring(0,16) } finally { $hash.Dispose() }
$localData = [Environment]::GetFolderPath('LocalApplicationData')
$SessionDir = Join-Path $localData ("YobiV3/" + $key)
[void][IO.Directory]::CreateDirectory($SessionDir)
$Services = @('apigateway','member','product','ordering','frontend')
$Registry = "${ExpectedAccountId}.dkr.ecr.${AwsRegion}.amazonaws.com"
$WorkflowName = 'deploy-yobi-gitops.yml'
$WorkflowPath = Join-Path $Root '.github/workflows/deploy-yobi-gitops.yml'
$DbSecretScript = Join-Path $Root 'create-yobi-v1-db-secret.ps1'
$CheckpointPath = Join-Path $SessionDir 'deploy.json'
if($Resume -and (Test-Path -LiteralPath $CheckpointPath)){
    $resumeSource=Get-Content -LiteralPath $CheckpointPath -Raw|ConvertFrom-Json
    if(-not $resumeSource.PSObject.Properties['gitRoot']){throw 'Legacy deployment checkpoint has no isolated baseline. Start a reviewed fresh installation.'}
    Assert-YobiFirstInstallCheckout $Root ([string]$resumeSource.gitRoot)
    $GitRoot=[string]$resumeSource.gitRoot
    $WorkflowPath=Join-Path $GitRoot '.github/workflows/deploy-yobi-gitops.yml'
}
# Build-time fragment only; the delivered scripts embed these functions.
function Get-Field($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}
function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    $null=Get-Command $Exe -ErrorAction Stop
    $previousPreference=$ErrorActionPreference
    $global:LASTEXITCODE=$null
    try {
        # PS 5.1 turns redirected native stderr into ErrorRecords. Keep consuming
        # both streams, then fail on the actual exit code after logging diagnostics.
        $ErrorActionPreference='Continue'
        if ($Exe -eq 'terraform' -and $Arguments -contains 'apply') {
            $liveArgs=New-Object 'System.Collections.Generic.List[string]'
            $liveArgs.AddRange([string[]]$Arguments);$liveArgs.Insert($liveArgs.IndexOf('apply')+1,'-json')
            & $Exe @($liveArgs.ToArray()) 2>&1 | ForEach-Object { Receive-YobiTerraformLine ([string]$_) }
        } else { & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host ([string]$_) } }
    } finally { $ErrorActionPreference=$previousPreference }
    if ($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE). See preceding error." }
}
function Read-Native([string]$Exe, [string[]]$Arguments) {
    $result = @(& $Exe @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE). See preceding error." }
    return ($result -join "`n")
}
function Read-Aws([string[]]$Arguments) {
    $s = Read-Native 'aws' ($Arguments + @('--profile',$AwsProfile,'--region',$AwsRegion,'--output','json','--no-cli-pager','--cli-connect-timeout','10','--cli-read-timeout','20'))
    return ($s | ConvertFrom-Json)
}
function Read-Git([string[]]$Arguments) {
    return (Read-Native 'git' (@('-C',$GitRoot,'-c','core.quotepath=false') + $Arguments)).Trim()
}
function Run-Git([string[]]$Arguments) {
    # Recheck at each call: a user could switch branches while Terraform is running.
    if ((Read-Git @('branch','--show-current')) -cne 'yobi-v1') { throw 'Branch changed during operation. Refusing Git command; main remains untouched.' }
    Invoke-Checked 'git' (@('-C',$GitRoot) + $Arguments)
}
function Assert-Tools([string[]]$Names) {
    foreach ($n in $Names) { if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { throw "Missing command: $n" } }
}
function Assert-Identity {
    $who = Read-Aws @('sts','get-caller-identity')
    if ($who.Account -cne $ExpectedAccountId) { throw "Wrong AWS account: $($who.Account)" }
    Send-YobiEvent 'verified' 'connection'
    Write-Host "[TARGET] account=$ExpectedAccountId profile=$AwsProfile region=$AwsRegion cluster=$ClusterName"
}
function Tf-Args([string[]]$Arguments) {
    # Explicit -var takes precedence over local tfvars and TF_VAR_* values.
    return @("-chdir=$TerraformDir") + $Arguments + @("-var=aws_profile=$AwsProfile","-var=aws_region=$AwsRegion")
}
function Get-StateResources {
    $raw = Read-Native 'terraform' @("-chdir=$TerraformDir",'show','-json')
    $doc = $raw | ConvertFrom-Json
    function Walk-State($Module) {
        foreach ($r in @(Get-Field $Module 'resources' @())) { if ($null -ne $r) { $r } }
        foreach ($m in @(Get-Field $Module 'child_modules' @())) { if ($null -ne $m) { Walk-State $m } }
    }
    $values = Get-Field $doc 'values'
    return @(Walk-State (Get-Field $values 'root_module'))
}
function Assert-StateAccount($Resources) {
    foreach ($r in @($Resources)) {
        foreach ($n in @('arn','cluster_arn','role_arn')) {
            $v = [string](Get-Field (Get-Field $r 'values') $n '')
            if ($v -match '^arn:aws[^:]*:[^:]*:[^:]*:(\d{12}):' -and $Matches[1] -cne $ExpectedAccountId) {
                throw "State contains another account at $($r.address)."
            }
        }
    }
}
function Enter-ProjectLock {
    $name = 'YobiV2-' + $ExpectedAccountId + '-' + $AwsRegion + '-' + $ClusterName
    $script:ProjectMutex = New-Object Threading.Mutex($false, $name)
    try { $held = $script:ProjectMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another V2/V3 deployment/destroy is running on this Windows session.' }
    $script:MutexHeld = $true
    # Also refuse concurrent V1/manual Terraform against the same checkout.
    $running = @(Get-CimInstance Win32_Process -Filter "Name='terraform.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($TerraformDir,[StringComparison]::OrdinalIgnoreCase) -ge 0 })
    if ($running.Count) { throw 'Terraform is already running against this project. Do not start a second operation.' }
}
function Exit-ProjectLock {
    if ($script:MutexHeld) { $script:ProjectMutex.ReleaseMutex(); $script:MutexHeld = $false }
    if ($null -ne $script:ProjectMutex) { $script:ProjectMutex.Dispose() }
}
function New-PrivatePlanPath {
    return (Join-Path ([IO.Path]::GetTempPath()) ('yobi-v2-' + [guid]::NewGuid().ToString('N') + '.tfplan'))
}
function Remove-OwnPlan([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) { Remove-Item -LiteralPath $Path -Force }
}
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
    Write-Host '[SECRETS] Synchronizing RDS credentials securely (managed or operator input)...'
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

function Assert-Repo {
    if ((Read-Git @('branch','--show-current')) -cne 'yobi-v1') { throw 'Only branch yobi-v1 is allowed. main is never modified.' }
    $origin = Read-Git @('remote','get-url','origin')
    if ($origin -notmatch '^(https://github\.com/yobi84-sy/msa(?:\.git)?|git@github\.com:yobi84-sy/msa(?:\.git)?)$') { throw 'Unexpected Git origin.' }
    if (Read-Git @('diff','--cached','--name-only')) { throw 'Existing staged changes: review/unstage them before V3 runs.' }
}
function Test-PublishPath([string]$Path) {
    if($Path -cmatch '^first-install-baseline/(source\.zip|manifest\.json)$'){return $true}
    if($Path -cmatch '^(Configure-YobiAlerts|YobiV3\.InstallNotifications|YobiV3\.Notifications)\.ps1$'){return $true}
    if($Path -cmatch '^operations/notifications/(README\.md|(?:external_probe|prepare_manifests|load_test)\.py|terraform/(?:main|external-probe)\.tf|terraform/\.terraform\.lock\.hcl)$'){return $true}
    if ($Path -match '[\x00-\x1f"\\]' -or $Path -match '^/' -or $Path -match '(^|/)\.\.(/|$)') { return $false }
    if ($Path -match '(?i)(^|/)(\.git|\.terraform|\.gradle|build|bin|node_modules|logs|sessions)/|\.tfstate|\.tfvars|\.tfplan|\.env($|\.)|\.bak($|\.)|\.before-|\.(zip|7z|pem|key|pfx|p12|log|db)$') { return $false }
    if($Path -ceq 'scripts/prepare-storefront-manifests.py' -or $Path -cmatch '^msa/frontend/src/assets/[A-Za-z0-9_.-]+\.(png|jpg|jpeg|webp)$'){return $true}
    if ($Path -match '^lib/(BCrypt.Net-Next.dll|manifest.json|BCrypt-LICENSE.txt)$') { return $true }
    if ($Path -match '^(Deploy-YobiV[123]\.ps1|Destroy-YobiV[123]\.ps1|create-yobi-v1-db-secret\.ps1|YobiV3\.Common\.ps1|YobiV3\.Backup\.ps1|YobiV3\.Credentials\.ps1|YobiV3\.Rollouts\.ps1|YobiV3\.FirstInstall\.ps1|YobiV3\.Catalog\.ps1|\.gitignore)$') { return $true }
    if ($Path -notmatch '^(msa/|argocd/|terraform/|\.github/workflows/)') { return $false }
    if ($Path -match '/gradle/wrapper/gradle-wrapper\.jar$') { return $true }
    return $Path -match '(?i)(Dockerfile|gradlew(\.bat)?|\.dockerignore|\.gitignore|\.terraform\.lock\.hcl)$|\.(java|gradle|properties|ya?ml|tf|hcl|json|js|html|css|conf|xml|md|txt|sh|ps1)$'
}
function Get-SourceChanges {
    $lines = @()
    foreach ($a in @(@('diff','--name-only','HEAD','--'),@('ls-files','--others','--exclude-standard'))) {
        $s = Read-Git $a
        if ($s) { $lines += $s -split "`n" }
    }
    $all = @($lines | Where-Object { $_ } | Sort-Object -Unique)
    $skipped=New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $all) {
        if (Test-PublishPath $p) { $p }
        else { $skipped.Add($p) }
    }
    if($skipped.Count){
        Write-Host "[NOT PUBLISHED] $($skipped.Count) local/GUI/archive files excluded (first 10 shown)."
        foreach($p in @($skipped|Select-Object -First 10)){Write-Host "[LOCAL ONLY] $p"}
    }
}
function Assert-PublishChanges($Paths) {
    foreach ($p in @($Paths)) {
        if (-not (Test-PublishPath $p)) { throw "Out-of-scope/unreviewed file: $p. Keep GUI and local artifacts outside this source change set." }
        $full = Join-Path $GitRoot $p
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $f = Get-Item -LiteralPath $full
            if ($f.Length -gt 2MB) { throw "Review large file separately: $p" }
            if ($p -notmatch '\.(jar|dll)$') {
                $s = [IO.File]::ReadAllText($full)
                if ($s -match '(AKIA|ASIA)[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{20,}') { throw "Possible credential in $p. Refusing publish." }
            }
        }
    }
}
function Assert-FullBuildContract {
    $s = [IO.File]::ReadAllText($WorkflowPath).Replace("`r`n","`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    if ($actual -cne '165649c601e8f4ae7e5290292120c9d3f7b76d21e09b20f5524a261e28edf845') { throw 'V3 requires the supplied workflow exactly (LF/CRLF accepted). Review changes and update the contract deliberately.' }
}
function Assert-DefaultBranch {
    $branch = (Read-Native 'gh' @('api',"repos/$GitHubRepo",'--jq','.default_branch')).Trim()
    if ($branch -cne 'yobi-v1') { throw "Default branch is $branch; change it to yobi-v1 in GitHub settings before V3. This script never changes repository settings." }
}
function Assert-NoActiveBuild {
    $raw = Read-Native 'gh' @('api',"repos/$GitHubRepo/actions/workflows/$WorkflowName/runs?branch=yobi-v1&per_page=100")
    $active = @(($raw | ConvertFrom-Json).workflow_runs | Where-Object { $_.status -cne 'completed' })
    if ($active.Count) { throw 'An existing workflow run is active/queued. Let it finish before starting a fresh V3 request. No run is cancelled automatically.' }
}
function Request-NewBuild($State) {
    Send-YobiEvent 'started' 'actions' 'actions/build' 'create'
    if ((Get-RemoteRevision) -cne $State.sourceSha) { throw 'Remote source changed before dispatch. Start a reviewed fresh request.' }
    # Save BEFORE dispatch. A network error may occur after GitHub accepted it.
    # Resume searches this request ID and NEVER silently dispatches a duplicate.
    Save-Checkpoint $State
    Invoke-Checked 'gh' @('workflow','run',$WorkflowName,'--repo',$GitHubRepo,'--ref','yobi-v1','-f','service=all','-f',"request_id=$($State.requestId)",'-f',"expected_sha=$($State.sourceSha)")
}
function Save-Checkpoint($Data) {
    $tmp = $CheckpointPath + '.tmp'
    $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $CheckpointPath -Force
}
function Find-ExactRun([string]$Sha,[string]$RequestId) {
    $s = Read-Native 'gh' @('api',"repos/$GitHubRepo/actions/workflows/$WorkflowName/runs?branch=yobi-v1&event=workflow_dispatch&head_sha=$Sha&per_page=100")
    $runs = @((($s | ConvertFrom-Json).workflow_runs) | Where-Object { $_.head_sha -ceq $Sha -and $_.event -ceq 'workflow_dispatch' -and (Get-Field $_ 'display_title' '') -ceq "Yobi V3 request $RequestId" -and $_.head_branch -ceq 'yobi-v1' })
    if ($runs.Count -gt 1) { throw 'Multiple runs for the bootstrap commit. Inspect rather than guessing.' }
    if ($runs.Count -eq 1) { return $runs[0] }
    return $null
}
function Wait-ExactRun($State) {
    $deadline = (Get-Date).AddSeconds($ActionsTimeoutSeconds)
    $r = $null
    while ((Get-Date) -lt $deadline) {
        if (-not $State.runId) {
            $r = Find-ExactRun $State.sourceSha $State.requestId
            if ($null -ne $r) { $State.runId = [string]$r.id; Save-Checkpoint $State }
        } else {
            $r = (Read-Native 'gh' @('api',"repos/$GitHubRepo/actions/runs/$($State.runId)")) | ConvertFrom-Json
        }
        if ($null -ne $r) {
            if ($r.head_sha -cne $State.sourceSha -or $r.head_branch -cne 'yobi-v1' -or $r.event -cne 'workflow_dispatch' -or (Get-Field $r 'display_title' '') -cne "Yobi V3 request $($State.requestId)") { throw 'Run does not match this bootstrap request.' }
            Write-Host "[ACTIONS] run=$($r.id) attempt=$($r.run_attempt) status=$($r.status) result=$($r.conclusion) $($r.html_url)"
            if ($r.status -ceq 'completed') {
                if ($r.conclusion -cne 'success') { throw "Build failed/cancelled: $($r.html_url). Fix then rerun this exact run, or start a fresh deployment." }
                $State.attempt = [int]$r.run_attempt
                $jobs = (Read-Native 'gh' @('api',"repos/$GitHubRepo/actions/runs/$($r.id)/attempts/$($r.run_attempt)/jobs?per_page=100")) | ConvertFrom-Json
                foreach ($name in @('detect','update-manifests') + @($Services | ForEach-Object { "build ($_)" })) {
                    $j = @($jobs.jobs | Where-Object { $_.name -ceq $name })
                    if ($j.Count -ne 1 -or $j[0].conclusion -cne 'success') { throw "Required job not successful: $name. Resume only after a complete successful run." }
                }
                Save-Checkpoint $State
                return
            }
        } else { Write-Host "[ACTIONS] Waiting for dispatch request $($State.requestId), source $($State.sourceSha)" }
        Start-Sleep -Seconds 10
    }
    throw 'Timed out waiting for this bootstrap run. Use -Resume after inspecting GitHub; no old success is accepted.'
}
function Get-RemoteRevision {
    return (Read-Native 'gh' @('api',"repos/$GitHubRepo/git/ref/heads/yobi-v1",'--jq','.object.sha')).Trim()
}
function Read-GitHubYaml([string]$Path,[string]$Revision) {
    if($Revision -cnotmatch '^[0-9a-f]{40}$'){throw 'GitHub YAML requires a full verified commit SHA.'}
    if($Path -cnotmatch '^(argocd/root-app\.yml|msa/(apigateway|member|product|ordering|frontend)/k8s/depl_svc\.yml)$'){
        throw 'GitHub YAML path is outside the reviewed deployment manifests.'
    }
    # Request readable YAML directly, rather than decoding a remote Base64 payload.
    $yaml=Read-Native 'gh' @('api',"repos/$GitHubRepo/contents/$Path`?ref=$Revision",'-H','Accept: application/vnd.github.raw+json')
    if([string]::IsNullOrWhiteSpace($yaml) -or $yaml -cnotmatch '(?m)^apiVersion:\s*\S+'){
        throw 'GitHub did not return a readable Kubernetes manifest.'
    }
    return $yaml
}
function Assert-ImagesForRevision([string]$Revision,[string]$ExpectedTag) {
    foreach ($service in $Services) {
        $repository = "${RepositoryPrefix}-${service}"
        $yaml = Read-GitHubYaml "msa/$service/k8s/depl_svc.yml" $Revision
        $pattern = '(?m)^\s*image:\s*' + [regex]::Escape("$Registry/$repository") + ':([^\s#]+)\s*$'
        $tags = @([regex]::Matches($yaml,$pattern))
        if ($tags.Count -ne 1 -or $tags[0].Groups[1].Value -cne $ExpectedTag) { throw "Git revision $Revision has unexpected tag for $service. Concurrent publish or manifest drift; stop." }
        $result = Read-Aws @('ecr','describe-images','--repository-name',$repository,'--image-ids',"imageTag=$ExpectedTag")
        $images = @($result.imageDetails)
        if ($images.Count -ne 1 -or -not $images[0].imageDigest) { throw "ECR image missing: $repository`:$ExpectedTag" }
        Write-Host "[ECR] $service $ExpectedTag $($images[0].imageDigest)"
    }
}
function Wait-Revision([string]$Name,[string]$Revision) {
    $deadline = (Get-Date).AddSeconds($RolloutTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-RemoteRevision) -cne $Revision) { throw 'yobi-v1 changed during deployment. Stop and revalidate rather than claim success.' }
        $raw = Read-Native 'kubectl' @('get','application',$Name,'-n','argocd','--ignore-not-found','-o','json','--request-timeout=20s')
        if ($raw) {
            $a = $raw | ConvertFrom-Json; $st = Get-Field $a 'status'
            $sync = Get-Field $st 'sync'; $health = Get-Field $st 'health'
            Write-Host "[ARGO] $Name sync=$(Get-Field $sync 'status' 'Pending') health=$(Get-Field $health 'status' 'Pending') revision=$(Get-Field $sync 'revision' '')"
            Update-YobiDeploymentState ($Name -eq 'msa-monitoring' -and (Get-Field $sync 'revision' '') -ceq $Revision -and (Get-Field $sync 'status' '') -ceq 'Synced')
            if ((Get-Field $sync 'revision' '') -ceq $Revision -and (Get-Field $sync 'status' '') -ceq 'Synced' -and ($Name -eq 'msa-root' -or (Get-Field $health 'status' '') -ceq 'Healthy')) { return }
        }
        Start-Sleep -Seconds 10
    }
    throw "ArgoCD $Name did not reach expected revision. Inspect Application conditions; no automatic rollback/destroy."
}
function Wait-Web {
    $deadline = (Get-Date).AddSeconds($WebTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $homeResponse = Invoke-WebRequest -Uri 'https://server.sy84.store/' -UseBasicParsing -TimeoutSec 15
            $api = Invoke-WebRequest -Uri 'https://server.sy84.store/product-service/product/list' -UseBasicParsing -TimeoutSec 15
            if ($homeResponse.StatusCode -ne 200 -or $api.StatusCode -ne 200) { throw 'HTTP status not 200.' }
            if ([string]$api.Headers['Content-Type'] -notmatch 'application/json' -or $api.Content.TrimStart() -notmatch '^\[') { throw 'Product API did not return a JSON array.' }
            $null = $api.Content | ConvertFrom-Json
            Write-Host '[WEB] HTTPS frontend + JSON product list verified (TLS validation enabled).'
            return
        } catch { Write-Host "[WEB] Not ready: $($_.Exception.Message)"; Start-Sleep -Seconds 10 }
    }
    throw 'Web/TLS/API checks timed out. Resources are retained for diagnosis.'
}

# ---------------- MAIN: only -Execute may publish or mutate infrastructure ----------------
 $preparedCatalog=Read-YobiCatalog $Root
 Write-Host ('[CATALOG CHECK] '+$preparedCatalog.products.Count+' products and original image hashes verified locally.')
Send-YobiEvent 'phase' 'connection' '' '' '설치 사전 검사 · Git/AWS 인증 확인'
Assert-Tools @('git','gh','aws','terraform','kubectl')
Assert-Repo
Assert-FullBuildContract
Assert-DefaultBranch
Assert-Identity
Invoke-Checked 'gh' @('auth','status','--hostname','github.com')
foreach ($p in @('terraform','argocd/root-app.yml','create-yobi-v1-db-secret.ps1','YobiV3.Common.ps1','YobiV3.Backup.ps1','YobiV3.Credentials.ps1','YobiV3.Rollouts.ps1','lib/BCrypt.Net-Next.dll','lib/manifest.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $p))) { throw "Missing $p" }
}
$sourceChanges = @(Get-SourceChanges)
if ($sourceChanges.Count -and -not $PublishChanges) { throw 'Uncommitted/untracked changes exist. Review them, then use -PublishChanges or commit them first. No cloud changes made.' }
Assert-PublishChanges $sourceChanges
if ($Resume -and $sourceChanges.Count) { throw '-Resume requires unchanged source. Do not mix new changes with an old build.' }
Write-Host "[V3] project=$Root workflow=$WorkflowName branch=yobi-v1; main is never modified."
Write-Host '[V3] Default branch yobi-v1; correlated workflow_dispatch full build. No marker edits. V2 is not imported.'
foreach ($p in $sourceChanges) { Write-Host "[PUBLISH] $p" }
if (-not $Execute) { Write-Host '[CHECK ONLY] No init/apply/commit/push/Secrets/deployment performed. Add -Execute for reviewed execution.'; return }
if ($Resume -and -not (Test-Path -LiteralPath $CheckpointPath)) { throw 'No checkpoint for this project. Use a fresh deployment.' }
if ((Read-Host 'Type DEPLOY to approve infrastructure costs, reviewed source publish and full GitHub build') -cne 'DEPLOY') { throw 'Cancelled.' }
# Validate/load the reviewed dependency before any infrastructure changes.
. (Join-Path $PSScriptRoot 'YobiV3.Credentials.ps1')
Initialize-YobiBcrypt
Enter-ProjectLock
try {
    $priorDbInput=$env:TF_VAR_db_password_wo
    $priorEmailInput=$env:TF_VAR_yobi_alert_email
    foreach($service in $Services){Send-YobiEvent 'planned' 'app' "deployment/$service-depl" 'create'}
    foreach($group in @('actions','argo','prometheus','grafana','tls')){
        $address=switch($group){'actions'{'actions/build'} 'argo'{'argocd/sync'} 'tls'{'certificate/readiness'} default{"deployment/$group"}}
        Send-YobiEvent 'planned' $group $address $(if($group -eq 'argo'){'update'}elseif($group -eq 'tls'){'check'}else{'create'})
    }
    Send-YobiEvent 'phase' 'connection' '' '' '작업 브랜치 동기화 확인'
    Send-YobiEvent 'planned' 'app' 'verification/web' 'check'
    Send-YobiEvent 'planned' 'app' 'catalog/seed' 'check'
    Send-YobiEvent 'planned' 'grafana' 'verification/https' 'check'
    Send-YobiEvent 'planned' 'argo' 'verification/https' 'check'
    if(-not $Resume){
        Assert-NoActiveBuild
        $GitRoot=New-YobiFirstInstallCheckout $Root ([string[]]$sourceChanges)
        $WorkflowPath=Join-Path $GitRoot '.github/workflows/deploy-yobi-gitops.yml'
        Assert-Repo
    }
    Assert-FullBuildContract
    if (-not $Resume) { Assert-NoActiveBuild }
    if (-not $SkipTerraform -and -not $Resume) {
        Send-YobiEvent 'phase' 'connection' '' '' 'Terraform 공급자 초기화'
        Invoke-Checked 'terraform' @("-chdir=$TerraformDir",'init','-input=false','-no-color')
        Assert-StateAccount (Get-StateResources)
        . (Join-Path $PSScriptRoot 'YobiV3.Credentials.ps1')
        $dbState=@(Get-StateResources | Where-Object address -ceq 'aws_db_instance.main')
        if ($dbState.Count) {
            throw 'An existing DB requires a reviewed update/resume procedure. This installer initializes fresh stacks only; it will not silently change password management on a live DB.'
        }
        if (-not $dbState.Count) { Set-YobiDbInput }
        $settingsPath=Join-Path $Root '.yobi-local/operator-settings.json'
        if (Test-Path -LiteralPath $settingsPath) {
            $settings=Get-Content -LiteralPath $settingsPath -Raw|ConvertFrom-Json
            if ($settings.PSObject.Properties['alertEmail']) {
                $email=[string]$settings.alertEmail
                if ($email -and $email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'Invalid local alert email.' }
                $env:TF_VAR_yobi_alert_email=$email
                Write-Host '[ALERTS] Local email subscription configured; confirm the AWS SNS subscription email after installation.'
            }
        }
        $plan = New-PrivatePlanPath
        try {
            Send-YobiEvent 'phase' 'connection' '' '' 'Terraform 실행 계획 생성 중'
            Invoke-Checked 'terraform' (Tf-Args @('plan','-input=false','-no-color',"-out=$plan"))
            $planDoc=(Read-Native 'terraform' @("-chdir=$TerraformDir",'show','-json',$plan))|ConvertFrom-Json
            Send-YobiPlan $planDoc
            if ((Read-Host 'Type yes to apply this exact saved plan') -cne 'yes') { throw 'Plan not approved.' }
            Invoke-Checked 'terraform' @("-chdir=$TerraformDir",'apply','-input=false','-no-color',$plan)
        } finally { Remove-OwnPlan $plan }
    }
    $cluster = (Read-Aws @('eks','describe-cluster','--name',$ClusterName)).cluster
    if ($cluster.status -cne 'ACTIVE') { throw 'EKS must be ACTIVE.' }
    Invoke-Checked 'aws' @('eks','update-kubeconfig','--name',$ClusterName,'--region',$AwsRegion,'--profile',$AwsProfile)
    if ((Read-Native 'kubectl' @('config','current-context')).Trim() -cne $cluster.arn) { throw 'Wrong Kubernetes context.' }
    foreach ($s in $Services) { $null = Read-Aws @('ecr','describe-repositories','--repository-names',"$RepositoryPrefix-$s") }
    Send-YobiEvent 'phase' 'app' '' '' '쇼핑몰 비밀번호와 Secret 준비'
    Ensure-AppSecrets
    Invoke-Checked 'kubectl' @('apply','-f',(Join-Path $Root 'msa/product/k8s/product-sa.yml'))
    Ensure-GrafanaAdminSecret
    . (Join-Path $PSScriptRoot 'YobiV3.Credentials.ps1')
    Ensure-YobiArgoPassword
    if ($Resume) {
        $cp = Get-Content -LiteralPath $CheckpointPath -Raw | ConvertFrom-Json
        if ($cp.sourceSha -cnotmatch '^[0-9a-f]{40}$' -or $cp.requestId -cnotmatch '^[0-9a-f]{32}$' -or ($cp.runId -and $cp.runId -cnotmatch '^\d+$')) { throw 'Invalid V3 checkpoint identifiers.' }
        if ($cp.root -cne $Root -or $cp.clusterArn -cne $cluster.arn -or $cp.account -cne $ExpectedAccountId -or $cp.clusterCreatedAt -cne ([string]$cluster.createdAt)) { throw 'Checkpoint belongs to another project/cluster generation. Start fresh.' }
        if ((Read-Git @('rev-parse','HEAD')) -cne $cp.sourceSha) { throw 'Local HEAD differs from saved request. Review before resume.' }
        Write-Host "[RESUME] Searching saved request $($cp.requestId). No new dispatch will be sent."
    } else {
        Assert-NoActiveBuild
        # Sources are committed once with [skip ci], then built by dispatch.
        # For pre-existing local commits, an empty skip-ci tip suppresses the push build.
        Send-YobiEvent 'phase' 'actions' '' '' '게시할 변경 파일 검토'
        $sourceChanges = @(Get-SourceChanges)
        Assert-PublishChanges $sourceChanges
        if ($sourceChanges.Count -and -not $PublishChanges) { throw 'Source changed during provisioning. Review before publishing.' }
        Assert-Repo
        Assert-FullBuildContract
        $before = Read-Git @('rev-parse','HEAD')
        if ($sourceChanges.Count -or (Get-RemoteRevision) -cne $before) {
            if ($sourceChanges.Count) { Run-Git (@('add','--') + $sourceChanges) }
            $staged = @((Read-Git @('diff','--cached','--name-only')) -split "`n" | Where-Object { $_ })
            Assert-PublishChanges $staged
            Run-Git @('diff','--cached','--check')
            Run-Git @('diff','--cached','--stat')
            if ((Read-Host 'Type PUSH to publish reviewed sources; push CI is skipped and dispatch will build all five services') -cne 'PUSH') { throw 'Publish cancelled. Staged files remain for review.' }
            Run-Git @('-c','user.name=Yobi Installer','-c','user.email=yobi-installer@local.invalid','commit','--allow-empty','-m','ci: prepare V3 full deployment [skip ci]')
            Run-Git @('push','origin','HEAD:refs/heads/yobi-v1')
        }
        Assert-DefaultBranch
        Assert-NoActiveBuild
        $cp = [pscustomobject]@{ root=$Root; gitRoot=$GitRoot; account=$ExpectedAccountId; clusterArn=[string]$cluster.arn; clusterCreatedAt=[string]$cluster.createdAt; sourceSha=(Read-Git @('rev-parse','HEAD')); runId=''; attempt=0; gitopsRevision=''; requestId=([guid]::NewGuid().ToString('N')) }
        Request-NewBuild $cp
    }
    Wait-ExactRun $cp
    Send-YobiEvent 'completed' 'actions' 'actions/build' 'create'
    $tag = "$($cp.sourceSha)-$($cp.runId)-$($cp.attempt)"
    $revision = Get-RemoteRevision
    Assert-ImagesForRevision $revision $tag
    $script:ExpectedRolloutTag=$tag
    $cp.gitopsRevision = $revision; Save-Checkpoint $cp
    foreach ($n in @('msa-apigateway','msa-member','msa-product','msa-ordering','msa-frontend','msa-hpa','msa-services','msa-argocd')) {
        if (Read-Native 'kubectl' @('get','application',$n,'-n','argocd','--ignore-not-found','-o','name')) { throw "Legacy Application ownership conflict: $n" }
    }
    # Apply root from the SAME verified Git revision, not a possibly stale local manifest.
    $rootYaml = Read-GitHubYaml 'argocd/root-app.yml' $revision
    $rootYaml | & kubectl apply -f -
    Assert-ExitCode 'ArgoCD root bootstrap'
    Send-YobiEvent 'started' 'argo' 'argocd/sync' 'update'
    foreach ($n in @('msa-root','yobi-v1-msa','msa-monitoring')) { Wait-Revision $n $revision }
    Send-YobiEvent 'completed' 'argo' 'argocd/sync' 'update'
    foreach ($s in $Services) { Send-YobiEvent 'planned' 'app' "deployment/$s-depl" 'create' }
    foreach ($s in $Services) {
        if(-not $script:YobiObservedDeployments.ContainsKey("deployment/$s-depl")){Publish-YobiDeploymentState 'app' "deployment/$s-depl" 'started'}
        Invoke-Checked 'kubectl' @('rollout','status',"deployment/$s-depl",'-n',$Namespace,"--timeout=${RolloutTimeoutSeconds}s")
        Publish-YobiDeploymentState 'app' "deployment/$s-depl" 'completed'
    }
    foreach ($s in @('prometheus','grafana')) { if(-not $script:YobiObservedDeployments.ContainsKey("deployment/$s")){Publish-YobiDeploymentState $s "deployment/$s" 'started'}; Invoke-Checked 'kubectl' @('rollout','status',"deployment/$s",'-n','monitoring',"--timeout=${RolloutTimeoutSeconds}s"); Publish-YobiDeploymentState $s "deployment/$s" 'completed' }
    Update-YobiDeploymentState $true
    foreach($name in @($Services|ForEach-Object {"deployment/$_-depl"})+@('deployment/prometheus','deployment/grafana')){if(-not $script:YobiCurrentReady[$name]){throw "Current expected deployment is not Ready: $name"}}
    Invoke-Checked 'kubectl' @('rollout','status','daemonset/node-exporter','-n','monitoring',"--timeout=${RolloutTimeoutSeconds}s")
    Send-YobiEvent 'started' 'tls' 'certificate/readiness' 'check'
    Invoke-Checked 'kubectl' @('wait','--for=condition=Ready','certificate/server-sy84-store-tls','-n',$Namespace,"--timeout=${WebTimeoutSeconds}s")
    Invoke-Checked 'kubectl' @('wait','--for=condition=Ready','certificate/argocd-sy84-store-tls','-n','argocd',"--timeout=${WebTimeoutSeconds}s")
    Send-YobiEvent 'completed' 'tls' 'certificate/readiness' 'check'
    Send-YobiEvent 'started' 'app' 'verification/web' 'check'
    Wait-Web
    Send-YobiEvent 'phase' 'app' '' '' '초기 상품·이미지 등록 및 중복·재고 보존 확인'
    Invoke-YobiCatalogSeed $Root
    Send-YobiEvent 'completed' 'app' 'verification/web' 'check'
    foreach ($url in @('https://grafana.sy84.store/api/health','https://argocd.sy84.store/')) {
        $webGroup=if($url -like '*grafana*'){'grafana'}else{'argo'}
        Send-YobiEvent 'started' $webGroup 'verification/https' 'check'
        $webResponse=Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
        if ($webResponse.StatusCode -ne 200) { throw "HTTPS verification failed: $url" }
        Send-YobiEvent 'completed' $webGroup 'verification/https' 'check'
    }
    Send-YobiEvent 'verified' 'web' '' '' 'HTTPS frontend/API, Grafana and Argo CD checked'
    if ((Get-RemoteRevision) -cne $revision) { throw 'Branch changed during final checks. Revalidate before reporting success.' }
    Write-Host "[SUCCESS] GitOps=$revision Actions=$($cp.runId)/$($cp.attempt); HTTPS/API verified. ArgoCD continues watching yobi-v1."
    Write-Host '[NOTE] Login/order/upload, HPA metrics and Prometheus target health still require their own operational checks.'
    Invoke-YobiInstallNotifications $Root
    Write-Host '[INSTALL COMPLETE] Services and monitoring installed. Confirm pending SNS emails before order-alert patches.'
} finally {
    [Environment]::SetEnvironmentVariable('TF_VAR_db_password_wo',$priorDbInput,'Process')
    [Environment]::SetEnvironmentVariable('TF_VAR_yobi_alert_email',$priorEmailInput,'Process')
    Remove-Variable priorDbInput,priorEmailInput -ErrorAction SilentlyContinue
    Exit-ProjectLock
}
