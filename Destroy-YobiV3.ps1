#Requires -Version 5.1
<#
Yobi V3 standalone candidate. Run -CheckOnly (default) first.
Original V1/V2 files are NOT imported or modified. Destroy is independent of default-branch selection. No GUI integration assumed.
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
    [switch]$DisableOrphanCleanup,
    [ValidateRange(1,120)][int]$CleanupTimeoutMinutes = 15,
    [ValidateRange(30,600)][int]$OrphanGraceSeconds = 90
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'YobiV3.Common.ps1')
. (Join-Path $PSScriptRoot 'YobiV3.Backup.ps1')
$PSNativeCommandUseErrorActionPreference = $false
$OutputEncoding = New-Object Text.UTF8Encoding($false)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
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
$ServiceNamespace = 'nginx-ingress'
$ServiceName = 'nginx-ingress-controller'
$NlbNamePrefix = 'k8s-nginxing-'
$SnapshotPath = Join-Path $SessionDir 'destroy-ownership.json'
$script:CleanupMessages = @{}
$script:ClusterAbsentSince = $null
$script:DeletedOrphans = 0
# Build-time fragment only; the delivered scripts embed these functions.
function Get-Field($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}
function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    if ($Exe -eq 'terraform' -and $Arguments -contains 'apply') {
        $liveArgs=New-Object 'System.Collections.Generic.List[string]'
        $liveArgs.AddRange([string[]]$Arguments);$liveArgs.Insert($liveArgs.IndexOf('apply')+1,'-json')
        & $Exe @($liveArgs.ToArray()) | ForEach-Object { Receive-YobiTerraformLine ([string]$_) }
    } else { & $Exe @Arguments | ForEach-Object { Write-Host $_ } }
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed (exit $LASTEXITCODE). See preceding error." }
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
    return (Read-Native 'git' (@('-C',$Root,'-c','core.quotepath=false') + $Arguments)).Trim()
}
function Run-Git([string[]]$Arguments) {
    # Recheck at each call: a user could switch branches while Terraform is running.
    if ((Read-Git @('branch','--show-current')) -cne 'yobi-v1') { throw 'Branch changed during operation. Refusing Git command; main remains untouched.' }
    Invoke-Checked 'git' (@('-C',$Root) + $Arguments)
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
function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command missing: $Name"
    }
}
function Assert-ExitCode([string]$Action) {
    if ($LASTEXITCODE -ne 0) { throw "$Action failed (exit $LASTEXITCODE)." }
}
function Invoke-AwsJson([string[]]$AwsArguments) {
    $raw = & aws @AwsArguments --profile $AwsProfile --region $AwsRegion --output json --no-cli-pager --cli-connect-timeout 10 --cli-read-timeout 20
    Assert-ExitCode ('AWS CLI ' + ($AwsArguments -join ' '))
    $value = ($raw | Out-String).Trim()
    if (-not $value) { return $null }
    return ($value | ConvertFrom-Json)
}
function Get-VpcIdFromState([string[]]$Addresses) {
    if (-not (@($Addresses) -contains 'aws_vpc.main')) { return $null }
    $lines = & terraform "-chdir=$TerraformDir" state show 'aws_vpc.main'
    Assert-ExitCode 'terraform state show aws_vpc.main'
    $line = @($lines | Where-Object { $_ -match '^\s*id\s*=\s*"?(vpc-[0-9a-f]+)"?\s*$' } | Select-Object -First 1)
    if ($line.Count -ne 1 -or $line[0] -notmatch '(vpc-[0-9a-f]+)') {
        throw 'Could not determine VPC ID from Terraform state safely.'
    }
    return [regex]::Match($line[0], 'vpc-[0-9a-f]+').Value
}
function Get-LbLeftovers([string]$VpcId) {
    $lbs = Invoke-AwsJson @('elbv2','describe-load-balancers')
    $tgs = Invoke-AwsJson @('elbv2','describe-target-groups')
    $groups = Invoke-AwsJson @('ec2','describe-security-groups','--filters',"Name=vpc-id,Values=$VpcId")
    return [PSCustomObject]@{
        Nlbs = @($lbs.LoadBalancers | Where-Object {
            $_.VpcId -eq $VpcId -and $_.Type -eq 'network' -and $_.LoadBalancerName -like "$NlbNamePrefix*"
        })
        TargetGroups = @($tgs.TargetGroups | Where-Object {
            $_.VpcId -eq $VpcId -and $_.TargetGroupName -like 'k8s-*'
        })
        K8sSecurityGroups = @($groups.SecurityGroups | Where-Object { $_.GroupName -like 'k8s-*' })
    }
}
function Assert-NoUnexpectedLb([string]$VpcId) {
    $all = Invoke-AwsJson @('elbv2','describe-load-balancers')
    $unknown = @($all.LoadBalancers | Where-Object {
        $_.VpcId -eq $VpcId -and $_.LoadBalancerName -notlike "$NlbNamePrefix*"
    })
    if ($unknown.Count -gt 0) {
        throw "Unexpected LB(s) in project VPC: $(($unknown | ForEach-Object LoadBalancerName) -join ', '). Stop."
    }
}
function Remove-NlbServiceSafely([string]$VpcId, [string]$ClusterArn, [string[]]$StateAddresses) {
    $context = (& kubectl config current-context | Out-String).Trim()
    Assert-ExitCode 'kubectl context'
    if ($context -cne $ClusterArn) {
        throw "kubectl context mismatch. Current=$context Expected=$ClusterArn"
    }
    $allServicesRaw = & kubectl get services --all-namespaces -o json
    Assert-ExitCode 'kubectl services'
    $allServices = ($allServicesRaw | Out-String | ConvertFrom-Json)
    $unexpected = @($allServices.items | Where-Object {
        $_.spec.type -eq 'LoadBalancer' -and -not (
            $_.metadata.namespace -eq $ServiceNamespace -and $_.metadata.name -eq $ServiceName
        )
    })
    if ($unexpected.Count -gt 0) {
        throw "Other LoadBalancer Services exist: $(($unexpected | ForEach-Object { "$($_.metadata.namespace)/$($_.metadata.name)" }) -join ', ')"
    }
    $ingressRaw = & kubectl get ingress --all-namespaces -o json
    Assert-ExitCode 'kubectl ingress'
    $ingresses = ($ingressRaw | Out-String | ConvertFrom-Json)
    foreach ($ingress in @($ingresses.items)) {
        $class = $null
        $classProp = $ingress.spec.PSObject.Properties['ingressClassName']
        if ($null -ne $classProp) { $class = [string]$classProp.Value }
        $annotationsProperty = $ingress.metadata.PSObject.Properties['annotations']
        $legacy = $null
        if ($null -ne $annotationsProperty -and $null -ne $annotationsProperty.Value) {
            $legacyProp = $annotationsProperty.Value.PSObject.Properties['kubernetes.io/ingress.class']
            if ($null -ne $legacyProp) { $legacy = [string]$legacyProp.Value }
        }
        if ($class -eq 'alb' -or $legacy -eq 'alb') {
            throw 'ALB-backed Ingress exists. Review before removing cluster.'
        }
    }
    # --ignore-not-found distinguishes a genuinely absent controller (exit 0,
    # empty response) from Kubernetes API failures (nonzero exit; hard stop).
    $controllerRaw = & kubectl get deployment aws-load-balancer-controller -n kube-system --ignore-not-found=true -o json
    Assert-ExitCode 'kubectl aws-load-balancer-controller'
    $controllerText = ($controllerRaw | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($controllerText)) {
        # If Helm failed before controller installation, destruction is safe
        # to continue ONLY when no controller-owned LB resources exist.
        Assert-NoUnexpectedLb $VpcId
        $projectServices = @($allServices.items | Where-Object {
            $_.metadata.namespace -eq $ServiceNamespace -and $_.metadata.name -eq $ServiceName
        })
        $left = Get-LbLeftovers $VpcId
        Write-Host ("[PARTIAL] ALB controller missing; Service={0} NLB={1} TG={2} k8s-SG={3}" -f `
            $projectServices.Count, $left.Nlbs.Count, $left.TargetGroups.Count, $left.K8sSecurityGroups.Count)
        if ($projectServices.Count -gt 0 -or $left.Nlbs.Count -gt 0 -or
            $left.TargetGroups.Count -gt 0 -or $left.K8sSecurityGroups.Count -gt 0) {
            throw 'Controller absent but project Service/NLB/TG/k8s-SG remains. Refusing automatic bypass; inspect manually.'
        }
        Disable-ProjectDns $StateAddresses
        Write-Host '[PARTIAL] No project Load Balancer resources found. Continue with guarded Terraform destroy.'
        return
    }
    $controller = $controllerText | ConvertFrom-Json
    if ([int](Get-Field (Get-Field $controller 'status') 'readyReplicas' 0) -lt 1) {
        throw 'AWS Load Balancer Controller not ready. Refusing service deletion.'
    }
    Assert-NoUnexpectedLb $VpcId
    Disable-ProjectDns $StateAddresses
    $projectService = @($allServices.items | Where-Object {
        $_.metadata.namespace -eq $ServiceNamespace -and $_.metadata.name -eq $ServiceName
    })
    if ($projectService.Count -gt 0) {
        Send-YobiEvent 'started' 'ingress' 'service/nginx-nlb-cleanup' 'delete'
        & kubectl delete service $ServiceName -n $ServiceNamespace --ignore-not-found=true --wait=false
        Assert-ExitCode 'kubectl delete nginx ingress Service'
    } else {
        Write-Host '[NLB] nginx ingress Service absent; skip kubectl delete.'
    }
    $deadline = (Get-Date).AddMinutes($CleanupTimeoutMinutes)
    do {
        # A partial Helm install might never have created nginx-ingress namespace.
        # Cluster-wide listing remains valid even if that namespace is missing.
        $svcRaw = & kubectl get services --all-namespaces -o json
        Assert-ExitCode 'kubectl services during NLB cleanup'
        $svcJson = ($svcRaw | Out-String | ConvertFrom-Json)
        $unexpectedServices = @($svcJson.items | Where-Object {
            $_.spec.type -eq 'LoadBalancer' -and -not (
                $_.metadata.namespace -eq $ServiceNamespace -and $_.metadata.name -eq $ServiceName
            )
        })
        if ($unexpectedServices.Count -gt 0) {
            throw 'Other LoadBalancer Service appeared during cleanup. Terraform destroy NOT started.'
        }
        $serviceLeft = @($svcJson.items | Where-Object {
            $_.metadata.namespace -eq $ServiceNamespace -and $_.metadata.name -eq $ServiceName
        })
        $left = Get-LbLeftovers $VpcId
        Write-Host ("[NLB] service={0} NLB={1} TG={2} k8s-SG={3}" -f `
            $serviceLeft.Count, $left.Nlbs.Count, $left.TargetGroups.Count, $left.K8sSecurityGroups.Count)
        if ($serviceLeft.Count -eq 0 -and $left.Nlbs.Count -eq 0 -and
            $left.TargetGroups.Count -eq 0 -and $left.K8sSecurityGroups.Count -eq 0) {
            if($projectService.Count -gt 0){Send-YobiEvent 'completed' 'ingress' 'service/nginx-nlb-cleanup' 'delete'}
            break
        }
        if ((Get-Date) -ge $deadline) {
            throw 'Timeout waiting for controller-owned NLB/TG/SG removal. Terraform destroy NOT started.'
        }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Disable-ProjectDns([string[]]$StateAddresses) {
    $owned = @($StateAddresses | Where-Object { $_ -cmatch '^aws_route53_record\.msa\["(server|grafana|prometheus|argocd)"\]$' })
    if (-not $owned.Count) { Write-Host '[DNS] No project alias records in state.'; return }
    $planPath = New-PrivatePlanPath
    try {
        # A narrowly targeted recovery plan avoids unrelated pending creates.
        # The JSON allowlist below rejects ANY unexpected managed change.
        $argsList = @('plan','-input=false','-no-color','-var=enable_nlb_dns=false',"-out=$planPath",'-target=aws_route53_record.msa')
        Invoke-Checked 'terraform' (Tf-Args $argsList)
        $plan = (Read-Native 'terraform' @("-chdir=$TerraformDir",'show','-json',$planPath)) | ConvertFrom-Json
        Send-YobiPlan $plan
        $changes = @(Get-Field $plan 'resource_changes' @() | Where-Object { $_.mode -eq 'managed' -and ($_.change.actions -join ',') -ne 'no-op' })
        foreach ($c in $changes) {
            if ($c.address -cnotin $owned -or ($c.change.actions -join ',') -cne 'delete') { throw "DNS cleanup plan contains unexpected change: $($c.address). Nothing applied." }
        }
        if ($changes.Count) { Invoke-Checked 'terraform' @("-chdir=$TerraformDir",'apply','-input=false','-no-color',$planPath) }
    } finally { Remove-OwnPlan $planPath }
}
function Read-Application([string]$Name) {
    $s = Read-Native 'kubectl' @('get','application',$Name,'-n','argocd','--ignore-not-found','-o','json','--request-timeout=20s')
    if ($s) { return ($s | ConvertFrom-Json) }
    return $null
}
function Patch-Application([string]$Name,$Patch) {
    # --patch-file avoids PowerShell 5.1 native argument JSON quote corruption.
    $p = Join-Path ([IO.Path]::GetTempPath()) ('yobi-v2-patch-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $Patch | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $p -Encoding UTF8
        Invoke-Checked 'kubectl' @('patch','application',$Name,'-n','argocd','--type=merge','--patch-file',$p,'--request-timeout=20s')
    } finally { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
}
function Stop-GitOps {
    $script:KubeOwned=@()
    foreach($scope in @(@('soldesk','app'),@('monitoring','monitoring'))){
        $deploys=(Read-Native 'kubectl' @('get','deployment','-n',$scope[0],'-o','json','--request-timeout=20s'))|ConvertFrom-Json
        foreach($d in @($deploys.items)){
            $group=if($scope[0] -eq 'soldesk'){'app'}elseif($d.metadata.name -in @('grafana','prometheus')){[string]$d.metadata.name}else{continue}
            $addr="deployment/$($d.metadata.name)"
            $script:KubeOwned+=@{group=$group;address=$addr;ns=$scope[0];name=$d.metadata.name}
            Send-YobiEvent 'present' $group $addr
            Send-YobiEvent 'planned' $group $addr 'delete'
        }
    }
    $crd = Read-Native 'kubectl' @('get','crd','applications.argoproj.io','--ignore-not-found','-o','name','--request-timeout=20s')
    if (-not $crd) { Write-Host '[ARGO] Application CRD absent (partial install).'; return }
    $expected = @{
        'msa-root' = @('argocd/apps','argocd')
        'yobi-v1-msa' = @('msa','soldesk')
        'msa-monitoring' = @('msa/k8s/k8s-monitoring','monitoring')
    }
    # Inspect EVERY app first, before any mutation. Unknown owners stop teardown.
    $all = (Read-Native 'kubectl' @('get','applications','-A','-o','json','--request-timeout=20s')) | ConvertFrom-Json
    foreach ($a in @($all.items)) {
        $name = [string]$a.metadata.name
        if ($a.metadata.namespace -cne 'argocd' -or -not $expected.ContainsKey($name)) { throw "Unexpected Argo Application $name. Inspect ownership before deleting cluster." }
        $source = Get-Field $a.spec 'source'; $dest = Get-Field $a.spec 'destination'
        if ((Get-Field $source 'repoURL') -cne 'https://github.com/yobi84-sy/msa.git' -or
            (Get-Field $source 'targetRevision') -cne 'yobi-v1' -or
            (Get-Field $source 'path') -cne $expected[$name][0] -or
            (Get-Field $dest 'server') -cne 'https://kubernetes.default.svc' -or
            (Get-Field $dest 'namespace') -cne $expected[$name][1]) { throw "Argo ownership/destination changed: $name" }
        $finalizers = @(Get-Field $a.metadata 'finalizers' @())
        if (@($finalizers | Where-Object { $_ -ne 'resources-finalizer.argocd.argoproj.io' }).Count) { throw "Unexpected finalizers on $name; no automatic removal." }
    }
    # Root first, then children: root can otherwise restore child automated sync.
    foreach ($name in @('msa-root','yobi-v1-msa','msa-monitoring')) {
        if ($null -ne (Read-Application $name)) {
            Patch-Application $name @{spec=@{syncPolicy=@{automated=$null}}}
            $deadline = (Get-Date).AddSeconds(120)
            do {
                $a = Read-Application $name
                if ($null -eq $a) { break }
                $auto = Get-Field (Get-Field $a.spec 'syncPolicy') 'automated'
                $phase = Get-Field (Get-Field (Get-Field $a 'status') 'operationState') 'phase' ''
                $op = Get-Field $a 'operation'
                if ($null -eq $auto -and $null -eq $op -and $phase -notin @('Running','Terminating')) { break }
                if ((Get-Date) -ge $deadline) { throw "Active Argo operation on $name; retry after it finishes. No finalizer bypass." }
                Write-Host "[ARGO] Waiting for $name to stop syncing ($phase)"; Start-Sleep -Seconds 5
            } while ($true)
        }
    }
    # Cascade ONLY the two verified child apps; Argo cleans its owned resources while controllers live.
    foreach ($name in @('yobi-v1-msa','msa-monitoring')) {
        if ($null -ne (Read-Application $name)) {
            Patch-Application $name @{metadata=@{finalizers=@('resources-finalizer.argocd.argoproj.io')}}
        }
    }
    foreach ($name in @('msa-root','yobi-v1-msa','msa-monitoring')) {
        foreach($d in $script:KubeOwned){
            if(($name -eq 'yobi-v1-msa' -and $d.ns -eq 'soldesk') -or ($name -eq 'msa-monitoring' -and $d.ns -eq 'monitoring')){Send-YobiEvent 'started' $d.group $d.address 'delete'}
        }
        Invoke-Checked 'kubectl' @('delete','application',$name,'-n','argocd','--ignore-not-found','--wait=true','--timeout=300s')
    }
    foreach($d in $script:KubeOwned){
        $left=Read-Native 'kubectl' @('get','deployment',$d.name,'-n',$d.ns,'--ignore-not-found','-o','name','--request-timeout=20s')
        if($left){throw 'App remains after Argo cascade; no data backup/deletion can continue.'}
        Send-YobiEvent 'completed' $d.group $d.address 'delete'
    }
    Write-Host '[ARGO] Verified project Applications removed. No Git changes; next Deploy can bootstrap them again.'
}
function Tag-Value($Tags,[string]$Key) {
    $found = @($Tags | Where-Object { $_.Key -ceq $Key })
    if ($found.Count -eq 1) { return [string]$found[0].Value }
    return ''
}
function Test-OrphanEni($Eni,[string]$Vpc,[string[]]$ManagedIds) {
    $id = [string](Get-Field $Eni 'NetworkInterfaceId' '')
    if ($id -in $ManagedIds) { return 'Terraform-managed ENI; leave to Terraform' }
    if ((Get-Field $Eni 'VpcId') -cne $Vpc) { return 'VPC mismatch' }
    if ((Get-Field $Eni 'OwnerId') -cne $ExpectedAccountId) { return 'Owner account missing/mismatch' }
    if ((Get-Field $Eni 'Status') -cne 'available') { return 'Still attached/in use' }
    if ($null -ne (Get-Field $Eni 'Attachment')) { return 'Attachment remains' }
    if ((Get-Field $Eni 'RequesterManaged') -ne $false) { return 'Requester-managed/unknown ownership' }
    $tags = @(Get-Field $Eni 'TagSet' @())
    if ((Tag-Value $tags 'cluster.k8s.amazonaws.com/name') -cne $ClusterName) { return 'CNI cluster ownership tag missing/mismatch' }
    if ((Tag-Value $tags 'eks:eni:owner') -cne 'amazon-vpc-cni') { return 'CNI owner tag missing/mismatch' }
    $node = Tag-Value $tags 'node.k8s.amazonaws.com/instance_id'
    if ($node -cnotmatch '^i-[0-9a-f]+$' -or (Get-Field $Eni 'Description') -cne "aws-K8S-$node") { return 'CNI node identity mismatch' }
    return ''
}
function Write-CleanupStatus([string]$Key,[string]$Message) {
    if (-not $script:CleanupMessages.ContainsKey($Key) -or $script:CleanupMessages[$Key] -cne $Message) {
        Write-Host "[ORPHAN] $Message"; $script:CleanupMessages[$Key] = $Message
    }
}
function Invoke-OrphanPass {
    if ($DisableOrphanCleanup) { return }
    # Never infer deletion from an AccessDenied/network failure: Read-Aws throws.
    $vpcs = Read-Aws @('ec2','describe-vpcs','--filters',"Name=vpc-id,Values=$vpcId")
    if (@($vpcs.Vpcs).Count -eq 0) { return }
    $clusters = Read-Aws @('eks','list-clusters')
    if (@($clusters.clusters) -contains $ClusterName) {
        $script:ClusterAbsentSince = $null
        Write-CleanupStatus 'cluster' 'Cluster still exists; wait for Terraform. No orphan deletion.'
        return
    }
    if ($null -eq $script:ClusterAbsentSince) { $script:ClusterAbsentSince = Get-Date }
    if (((Get-Date)-$script:ClusterAbsentSince).TotalSeconds -lt $OrphanGraceSeconds) {
        Write-CleanupStatus 'cluster' "Cluster absent; allowing AWS cleanup grace period ($OrphanGraceSeconds seconds)."; return
    }
    $inst = Read-Aws @('ec2','describe-instances','--filters',"Name=vpc-id,Values=$vpcId",'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down')
    if (@($inst.Reservations | ForEach-Object { $_.Instances }).Count) {
        Write-CleanupStatus 'nodes' 'Instances still present in project VPC. No orphan deletion.'; return
    }
    $enis = Read-Aws @('ec2','describe-network-interfaces','--filters',"Name=vpc-id,Values=$vpcId")
    foreach ($eni in @($enis.NetworkInterfaces)) {
        $id = [string]$eni.NetworkInterfaceId
        $reason = Test-OrphanEni $eni $vpcId $managedEniIds
        if ($reason) { Write-CleanupStatus $id "SKIP $id : $reason"; continue }
        $nodeId = Tag-Value $eni.TagSet 'node.k8s.amazonaws.com/instance_id'
        $nodeResult = Read-Aws @('ec2','describe-instances','--filters',"Name=instance-id,Values=$nodeId", "Name=vpc-id,Values=$vpcId")
        $nodes = @($nodeResult.Reservations | ForEach-Object { $_.Instances })
        $ended = $nodes.Count -eq 1 -and $nodes[0].State.Name -ceq 'terminated'
        # Missing historical node is only accepted if its exact ownership was captured earlier.
        if (-not $ended -and -not ($nodes.Count -eq 0 -and $nodeId -cin @($snapshot.nodeIds))) {
            Write-CleanupStatus $id "SKIP $id : original node termination not proven"; continue
        }
        $again = Read-Aws @('ec2','describe-network-interfaces','--filters',"Name=network-interface-id,Values=$id", "Name=vpc-id,Values=$vpcId")
        if (@($again.NetworkInterfaces).Count -ne 1) { continue }
        $now = $again.NetworkInterfaces[0]
        if ((Test-OrphanEni $now $vpcId $managedEniIds) -or (Tag-Value $now.TagSet 'node.k8s.amazonaws.com/instance_id') -cne $nodeId) { continue }
        Write-Host "[ORPHAN] Deleting verified detached CNI ENI $id (node $nodeId)."
        $null = Read-Aws @('ec2','delete-network-interface','--network-interface-id',$id)
        $script:DeletedOrphans++
    }
    if (-not $clusterSg -or $clusterSg -cin $managedSgIds) { return }
    $remaining = Read-Aws @('ec2','describe-network-interfaces','--filters',"Name=vpc-id,Values=$vpcId")
    if (@($remaining.NetworkInterfaces).Count) { Write-CleanupStatus 'sg' 'ENIs remain; cluster SG deletion deferred.'; return }
    $all = Read-Aws @('ec2','describe-security-groups')
    $candidate = @($all.SecurityGroups | Where-Object { $_.GroupId -ceq $clusterSg -and $_.VpcId -ceq $vpcId })
    if (-not $candidate.Count) { return }
    if ($candidate.Count -ne 1 -or $candidate[0].GroupName -cnotmatch ('^eks-cluster-sg-' + [regex]::Escape($ClusterName) + '-[0-9]+$')) { throw 'Captured cluster SG identity mismatch.' }
    foreach ($g in @($all.SecurityGroups)) {
        if ($g.GroupId -ceq $clusterSg) { continue }
        foreach ($rule in @($g.IpPermissions) + @($g.IpPermissionsEgress)) {
            if (@($rule.UserIdGroupPairs | Where-Object { $_.GroupId -ceq $clusterSg }).Count) {
                Write-CleanupStatus 'sg' "SG $clusterSg referenced by $($g.GroupId); do not revoke rules automatically."; return
            }
        }
    }
    Write-Host "[ORPHAN] Deleting exact EKS-created SG $clusterSg (no ENIs/external SG references)."
    $null = Read-Aws @('ec2','delete-security-group','--group-id',$clusterSg)
    $script:DeletedOrphans++
}
function Quote-NativeArgument([string]$Value) {
    # Windows CRT quoting. No shell interpolation; executable receives an argv array.
    $escaped = [regex]::Replace($Value,'(\\*)"','${1}${1}\"')
    $escaped = [regex]::Replace($escaped,'(\\+)$','${1}${1}')
    return '"' + $escaped + '"'
}
function Invoke-TerraformWithCleanup([string]$PlanPath) {
    $tf = (Get-Command terraform).Source
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $tf
    $start.Arguments = (@("-chdir=$TerraformDir",'apply','-json','-input=false','-no-color',$PlanPath) | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $start
    if (-not $proc.Start()) { throw 'Unable to start Terraform.' }
    Write-Host "[DESTROY] Terraform PID=$($proc.Id); stdout/stderr streamed directly."
    $outTask = $proc.StandardOutput.ReadLineAsync()
    $errTask = $proc.StandardError.ReadLineAsync()
    $outDone = $false; $errDone = $false
    $nextCleanup = Get-Date; $heartbeat = Get-Date; $cleanupFailed = $false
    try {
        do {
            # Drain both pipes concurrently so stderr cannot deadlock a long stdout read.
            if (-not $outDone -and $outTask.IsCompleted) {
                $line = $outTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $outDone = $true }
                else { Receive-YobiTerraformLine $line; $outTask = $proc.StandardOutput.ReadLineAsync() }
            }
            if (-not $errDone -and $errTask.IsCompleted) {
                $line = $errTask.GetAwaiter().GetResult()
                if ($null -eq $line) { $errDone = $true }
                else { Write-Host "[TF STDERR] $line"; $errTask = $proc.StandardError.ReadLineAsync() }
            }
            if ((Get-Date) -ge $nextCleanup -and -not $cleanupFailed) {
                try { Invoke-OrphanPass }
                catch { $cleanupFailed = $true; Write-Warning "Orphan cleanup stopped: $($_.Exception.Message). Terraform remains running; no unsafe fallback." }
                $nextCleanup = (Get-Date).AddSeconds(20)
            }
            if ((Get-Date) -ge $heartbeat) {
                Write-Host "[DESTROY] Terraform PID=$($proc.Id) exited=$($proc.HasExited); orphan removals=$script:DeletedOrphans; cleanupDisabled=$DisableOrphanCleanup"
                $heartbeat = (Get-Date).AddSeconds(30)
            }
            if ($proc.HasExited -and $outDone -and $errDone) { break }
            if (($outDone -or -not $outTask.IsCompleted) -and ($errDone -or -not $errTask.IsCompleted)) { Start-Sleep -Milliseconds 100 }
        } while ($true)
        $proc.WaitForExit()
        return $proc.ExitCode
    } finally {
        if (-not $proc.HasExited) {
            Write-Warning "Terraform PID=$($proc.Id) still running. Do NOT start another destroy or force-unlock. Inspect this process before retry."
        } else { $proc.Dispose() }
    }
}

# ---------------- MAIN ----------------
Send-YobiEvent 'phase' 'connection' '' '' '삭제 대상과 소유관계 확인'
Assert-Tools @('terraform','aws','kubectl')
if (-not (Test-Path -LiteralPath $TerraformDir -PathType Container)) { throw "Missing terraform directory: $TerraformDir" }
Assert-Identity
$resources = @(Get-StateResources)
Assert-StateAccount $resources
$state = @($resources | Where-Object mode -eq 'managed' | ForEach-Object address)
Write-Host "[V3 DESTROY] script=$PSCommandPath root=$Root managed=$($state.Count) orphanCleanup=$(-not $DisableOrphanCleanup)"
if (-not $state.Count) { Write-Host '[STATE] Empty. No deletion. This alone is not an AWS inventory check.'; return }
$vpcResource = @($resources | Where-Object address -ceq 'aws_vpc.main')
if ($vpcResource.Count -ne 1) { throw 'Exact aws_vpc.main state ownership required. No VPC inferred by name.' }
$vpcId = [string]$vpcResource[0].values.id
if ($vpcId -cnotmatch '^vpc-[0-9a-f]+$') { throw 'Invalid VPC ID in state.' }
$vpcs = Read-Aws @('ec2','describe-vpcs','--filters',"Name=vpc-id,Values=$vpcId")
$liveVpc = @($vpcs.Vpcs).Count -eq 1
$clusters = Read-Aws @('eks','list-clusters')
$clusterExists = @($clusters.clusters) -contains $ClusterName
$clusterSg = ''; $clusterInfo = $null
$snapshot = [pscustomobject]@{vpcId=$vpcId; account=$ExpectedAccountId; cluster=$ClusterName; clusterSg=''; nodeIds=@()}
if (Test-Path -LiteralPath $SnapshotPath) {
    $saved = Get-Content -LiteralPath $SnapshotPath -Raw | ConvertFrom-Json
    if ($saved.vpcId -ceq $vpcId -and $saved.account -ceq $ExpectedAccountId -and $saved.cluster -ceq $ClusterName) { $snapshot = $saved; $clusterSg = [string]$saved.clusterSg }
}
if ($clusterExists) {
    $clusterInfo = (Read-Aws @('eks','describe-cluster','--name',$ClusterName)).cluster
    if ($clusterInfo.resourcesVpcConfig.vpcId -cne $vpcId) { throw 'Cluster VPC differs from state.' }
    if ($clusterInfo.status -cne 'ACTIVE') { throw "Cluster is $($clusterInfo.status). Wait for ACTIVE or deletion; do not overlap operations." }
    $clusterSg = [string]$clusterInfo.resourcesVpcConfig.clusterSecurityGroupId
} elseif (-not $clusterSg) {
    # Recover exact ID from Terraform's cluster state, not a name-only SG search.
    $c = @($resources | Where-Object address -ceq 'aws_eks_cluster.main')
    if ($c.Count -eq 1) {
        $cfg = @(Get-Field $c[0].values 'vpc_config' @())
        if ($cfg.Count -eq 1 -and (Get-Field $cfg[0] 'vpc_id') -ceq $vpcId) { $clusterSg = [string](Get-Field $cfg[0] 'cluster_security_group_id' '') }
    }
}
if ($liveVpc) {
    $instances = Read-Aws @('ec2','describe-instances','--filters',"Name=vpc-id,Values=$vpcId")
    $knownNodes = @($instances.Reservations | ForEach-Object { $_.Instances } | Where-Object {
        (Tag-Value $_.Tags 'eks:cluster-name') -ceq $ClusterName -or (Tag-Value $_.Tags ("kubernetes.io/cluster/$ClusterName")) -ceq 'owned'
    } | ForEach-Object InstanceId)
    $snapshot.nodeIds = @(@($snapshot.nodeIds) + $knownNodes | Sort-Object -Unique)
}
$snapshot.clusterSg = $clusterSg
$managedEniIds = @($resources | Where-Object { $_.mode -eq 'managed' -and $_.type -eq 'aws_network_interface' } | ForEach-Object { $_.values.id })
$managedSgIds = @($resources | Where-Object { $_.mode -eq 'managed' -and $_.type -in @('aws_security_group','aws_default_security_group') } | ForEach-Object { $_.values.id })
Write-Host "[TARGET] VPC=$vpcId EKS=$ClusterName capturedClusterSG=$clusterSg"
Send-YobiInventory $resources
Write-Host '[IMPACT] Deletes project applications, RDS/S3 data according to the operator BACKUP/RESET choices, ECR images, DNS aliases and infrastructure. Strictly verified unmanaged CNI ENIs/cluster SG may also be removed.'
if (-not $Execute) { Write-Host '[CHECK ONLY] No resources changed. -Execute still requires explicit DESTROY confirmation.'; return }
if ((Read-Host "Type DESTROY $vpcId to approve permanent deletion including guarded orphan cleanup") -cne "DESTROY $vpcId") { throw 'Cancelled; no resources changed.' }
Enter-ProjectLock
try {
    . (Join-Path $PSScriptRoot 'YobiV3.Backup.ps1')
    $rdsMode=Read-Host 'RDS_DATA_MODE [BACKUP/RESET] (default BACKUP)'
    $s3Mode=Read-Host 'S3_DATA_MODE [BACKUP/RESET] (default BACKUP)'
    if (-not $rdsMode) { $rdsMode='BACKUP' }; if (-not $s3Mode) { $s3Mode='BACKUP' }
    if ($rdsMode -cnotin @('BACKUP','RESET') -or $s3Mode -cnotin @('BACKUP','RESET')) { throw 'Invalid data mode. No deletion started.' }
    foreach($r in @($resources | Where-Object mode -eq 'managed')){Send-YobiEvent 'planned' (Get-YobiGroup $r.address) $r.address 'delete'}
    $backupResources=$resources
    Send-YobiInventory $resources
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $SnapshotPath -Encoding UTF8
    if ($clusterExists) {
        Invoke-Checked 'aws' @('eks','update-kubeconfig','--name',$ClusterName,'--profile',$AwsProfile,'--region',$AwsRegion)
        Send-YobiEvent 'phase' 'app' '' '' 'Argo CD 동기화 중지 및 앱 쓰기 작업 종료'
        Stop-GitOps
        Invoke-YobiDataBackup $backupResources $rdsMode $s3Mode
        Remove-NlbServiceSafely $vpcId ([string]$clusterInfo.arn) $state
    } elseif ($liveVpc) {
        Invoke-YobiDataBackup $backupResources $rdsMode $s3Mode
        $lbs = Read-Aws @('elbv2','describe-load-balancers')
        if (@($lbs.LoadBalancers | Where-Object VpcId -ceq $vpcId).Count) { throw 'Cluster absent but Load Balancer remains. No automatic force deletion.' }
        Write-Host '[RESUME] Cluster absent; no Kubernetes calls. Guarded orphan cleanup before infrastructure plan.'
        # A prior failure may already be waiting on an orphan. Give normal AWS cleanup time, then inspect.
        $script:ClusterAbsentSince = Get-Date
        $deadline = (Get-Date).AddSeconds($OrphanGraceSeconds + 25)
        do { Invoke-OrphanPass; if ((Get-Date) -ge $deadline) { break }; Start-Sleep -Seconds 10 } while ($true)
    }
    if (-not $clusterExists -and -not $liveVpc) { Invoke-YobiDataBackup $backupResources $rdsMode $s3Mode }
    for ($attempt=1; $attempt -le 2; $attempt++) {
        $deletedBefore = $script:DeletedOrphans
        $plan = New-PrivatePlanPath
        try {
            Invoke-Checked 'terraform' (Tf-Args @('plan','-destroy','-input=false','-no-color','-var=enable_nlb_dns=false',"-out=$plan"))
            $doc = (Read-Native 'terraform' @("-chdir=$TerraformDir",'show','-json',$plan)) | ConvertFrom-Json
            Send-YobiPlan $doc
            foreach ($r in @(Get-Field $doc 'resource_changes' @())) {
                if ($r.mode -eq 'managed' -and ($r.change.actions -join ',') -notin @('delete','no-op')) { throw "Unexpected non-delete in destroy plan: $($r.address)" }
            }
            Write-Host "[DESTROY] Attempt $attempt/2; live output + guarded orphan cleanup."
            $code = Invoke-TerraformWithCleanup $plan
        } finally { Remove-OwnPlan $plan }
        if ($code -eq 0) { break }
        if ($attempt -eq 2 -or $script:DeletedOrphans -le $deletedBefore) { throw "Terraform failed (exit $code). No blind retries; inspect output and skipped ENI reasons." }
        Write-Host '[RETRY] A verified orphan was removed. Replan remaining deletions ONCE.'
    }
    $left = @(Get-StateResources | Where-Object mode -eq 'managed')
    $vpcAfter = Read-Aws @('ec2','describe-vpcs','--filters',"Name=vpc-id,Values=$vpcId")
    if ($left.Count -or @($vpcAfter.Vpcs).Count) { throw 'Destroy not complete: managed state or project VPC remains.' }
    Send-YobiEvent 'verified' 'web' '' 'delete' 'managed-state-empty-and-vpc-absent'
    Write-Host '[SUCCESS] Managed Terraform resources removed and exact VPC absent. Git/main/yobi-v1 were not changed by Destroy.'
} finally { Exit-ProjectLock }
