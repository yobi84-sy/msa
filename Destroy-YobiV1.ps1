#Requires -Version 5.1
<#
Yobi V1 - Destroy V4.2 (Windows PowerShell 5.1+)

Default (no -Execute): read-only Terraform state check.
-Execute: confirmation + staged Route 53/NLB removal + Terraform destroy.
-Execute -AutoCleanupOrphans: additionally watch for strictly identified VPC CNI
  orphan ENIs and EKS-created cluster SG during Terraform destroy.

IMPORTANT: Data in RDS and S3 may be permanently deleted. Do NOT run against
shared infrastructure. This script does not change Terraform state or finalizers.
Test in a disposable environment first; no successful live test is implied.
#>
[CmdletBinding()]
param(
    [switch]$Execute,
    [switch]$AutoCleanupOrphans,
    [string]$AwsProfile = 'eks-user',
    [string]$AwsRegion = 'ap-northeast-2',
    [string]$ExpectedAccountId = '021158485482',
    [string]$ClusterName = 'sales-mall-dev-eks',
    [ValidateRange(1,120)][int]$CleanupTimeoutMinutes = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$TerraformDir = Join-Path $PSScriptRoot 'terraform'
$ServiceNamespace = 'nginx-ingress'
$ServiceName = 'nginx-ingress-controller'
$NlbNamePrefix = 'k8s-nginxing-'

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command missing: $Name"
    }
}
function Assert-ExitCode([string]$Action) {
    if ($LASTEXITCODE -ne 0) { throw "$Action failed (exit $LASTEXITCODE)." }
}
function Invoke-AwsJson([string[]]$AwsArguments) {
    $raw = & aws @AwsArguments --profile $AwsProfile --region $AwsRegion --output json
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
function Disable-ProjectDns([string[]]$StateAddresses) {
    # EXACTLY one allowed managed change: aws_route53_record.msa["server"] delete.
    # A partial Apply may have left this record out of state. In that case,
    # a full DNS-only plan would try to CREATE unrelated unfinished resources.
    if (-not (@($StateAddresses) -ccontains 'aws_route53_record.msa["server"]')) {
        Write-Host '[DNS][PARTIAL] Server record is absent from Terraform state; skipping DNS-only plan.'
        return
    }
    $planPath = Join-Path $TerraformDir '.yobi-dns-off.tfplan'
    try {
        & terraform "-chdir=$TerraformDir" plan -input=false -var=enable_nlb_dns=false "-out=$planPath"
        Assert-ExitCode 'Terraform DNS disable plan'
        $jsonLines = & terraform "-chdir=$TerraformDir" show -json $planPath
        Assert-ExitCode 'Terraform plan JSON'
        $plan = ($jsonLines | Out-String | ConvertFrom-Json)
        $changes = @($plan.resource_changes | Where-Object {
            $null -ne $_ -and $_.mode -eq 'managed' -and ((@($_.change.actions) -join ',') -ne 'no-op')
        })
        $unexpected = @($changes | Where-Object {
            $_.address -cnotin @(
                'aws_route53_record.msa["server"]',
                'aws_route53_record.msa["grafana"]',
                'aws_route53_record.msa["prometheus"]'
            ) -or
            ((@($_.change.actions) -join ',') -ne 'delete')
        })
        if ($unexpected.Count -gt 0) {
            $details = ($unexpected | ForEach-Object { "$($_.address): $($_.change.actions -join ',')" }) -join '; '
            throw "DNS-only plan contains other modifications: $details"
        }
        if ($changes.Count -eq 0) {
            Write-Host '[DNS] Already absent according to plan.'
        } else {
            & terraform "-chdir=$TerraformDir" apply -input=false $planPath
            Assert-ExitCode 'Terraform DNS-only apply'
        }
    } finally {
        if (Test-Path -LiteralPath $planPath) { Remove-Item -LiteralPath $planPath -Force }
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
    if ([int]$controller.status.readyReplicas -lt 1) {
        throw 'AWS Load Balancer Controller not ready. Refusing service deletion.'
    }
    Assert-NoUnexpectedLb $VpcId
    Disable-ProjectDns $StateAddresses
    $projectService = @($allServices.items | Where-Object {
        $_.metadata.namespace -eq $ServiceNamespace -and $_.metadata.name -eq $ServiceName
    })
    if ($projectService.Count -gt 0) {
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
            break
        }
        if ((Get-Date) -ge $deadline) {
            throw 'Timeout waiting for controller-owned NLB/TG/SG removal. Terraform destroy NOT started.'
        }
        Start-Sleep -Seconds 15
    } while ($true)
}

# Runs in a separate PowerShell job while Terraform destroys resources.
# NEVER touches Terraform state, Terraform-managed IDs, or Kubernetes finalizers.
$OrphanMonitor = {
    param($Profile,$Region,$AccountId,$Cluster,$VpcId,$KnownClusterSg,$ManagedEniInState)
    $ErrorActionPreference = 'Stop'
    function AwsJson([string[]]$A) {
        $raw = & aws @A --profile $Profile --region $Region --output json
        if ($LASTEXITCODE -ne 0) { throw "AWS read failed: $($A -join ' ')" }
        return ($raw | Out-String | ConvertFrom-Json)
    }
    function TagValue($Tags,[string]$Key) {
        $found = @($Tags | Where-Object { $_.Key -ceq $Key })
        if ($found.Count -ne 1) { return $null }
        return [string]$found[0].Value
    }
    function Emit([string]$Kind,[string]$Message) {
        [PSCustomObject]@{ Kind = $Kind; Message = $Message }
    }
    try {
        $identity = AwsJson @('sts','get-caller-identity')
        if ([string]$identity.Account -cne $AccountId) { throw 'Account changed inside watcher. Stopping.' }
        $clusterMissingSince = $null
        $sgNameRegex = '^eks-cluster-sg-' + [regex]::Escape($Cluster) + '-[0-9]+$'
        while ($true) {
            Start-Sleep -Seconds 15
            $vpc = AwsJson @('ec2','describe-vpcs','--filters',"Name=vpc-id,Values=$VpcId")
            if (@($vpc.Vpcs).Count -eq 0) { Emit 'Info' 'Project VPC no longer exists.'; break }
            $clusters = AwsJson @('eks','list-clusters')
            if (@($clusters.clusters) -contains $Cluster) {
                $clusterMissingSince = $null
                continue
            }
            if ($null -eq $clusterMissingSince) {
                $clusterMissingSince = Get-Date
                Emit 'Info' 'EKS cluster no longer listed; waiting for AWS cleanup grace period.'
            }
            if (((Get-Date) - $clusterMissingSince).TotalSeconds -lt 45) { continue }
            $enis = AwsJson @('ec2','describe-network-interfaces','--filters',"Name=vpc-id,Values=$VpcId")
            foreach ($eni in @($enis.NetworkInterfaces)) {
                $eniId = [string]$eni.NetworkInterfaceId
                if ($ManagedEniInState) { continue }
                if ($eni.Status -cne 'available' -or $null -ne $eni.Attachment -or $eni.RequesterManaged -ne $false) { continue }
                if ([string]$eni.Description -cnotmatch '^aws-K8S-i-[0-9a-f]+$') { continue }
                if ((TagValue $eni.TagSet 'cluster.k8s.amazonaws.com/name') -cne $Cluster) { continue }
                if ((TagValue $eni.TagSet 'eks:eni:owner') -cne 'amazon-vpc-cni') { continue }
                $nodeId = TagValue $eni.TagSet 'node.k8s.amazonaws.com/instance_id'
                if ($nodeId -cnotmatch '^i-[0-9a-f]+$') { continue }
                if ($eni.Description -cne "aws-K8S-$nodeId") { continue }
                # Require explicit 'terminated', not an ambiguous missing instance.
                $instance = AwsJson @('ec2','describe-instances','--instance-ids',$nodeId)
                $nodes = @($instance.Reservations | ForEach-Object { $_.Instances })
                if ($nodes.Count -ne 1 -or [string]$nodes[0].State.Name -cne 'terminated') { continue }
                # Re-read this exact interface immediately before deletion.
                $latest = AwsJson @('ec2','describe-network-interfaces','--network-interface-ids',$eniId)
                $current = @($latest.NetworkInterfaces)
                if ($current.Count -ne 1 -or $current[0].VpcId -cne $VpcId -or
                    $current[0].Status -cne 'available' -or $null -ne $current[0].Attachment -or
                    $current[0].RequesterManaged -ne $false -or
                    (TagValue $current[0].TagSet 'cluster.k8s.amazonaws.com/name') -cne $Cluster -or
                    (TagValue $current[0].TagSet 'eks:eni:owner') -cne 'amazon-vpc-cni' -or
                    (TagValue $current[0].TagSet 'node.k8s.amazonaws.com/instance_id') -cne $nodeId -or
                    [string]$current[0].Description -cne "aws-K8S-$nodeId") { continue }
                & aws ec2 delete-network-interface --network-interface-id $eniId --profile $Profile --region $Region | Out-Null
                if ($LASTEXITCODE -eq 0) { Emit 'DeletedENI' "Deleted orphan CNI ENI $eniId (terminated node $nodeId)." }
                else { Emit 'Warning' "AWS refused orphan ENI deletion $eniId; leaving it for inspection." }
            }
            if (((Get-Date) - $clusterMissingSince).TotalSeconds -lt 75) { continue }
            $sgResult = AwsJson @('ec2','describe-security-groups','--filters',"Name=vpc-id,Values=$VpcId")
            $clusterGroups = @($sgResult.SecurityGroups | Where-Object {
                $_.GroupName -match $sgNameRegex -and $_.GroupName -ne 'default'
            })
            if ($clusterGroups.Count -gt 1) {
                Emit 'Warning' 'Multiple cluster SG candidates. No SG deletion.'
                continue
            }
            if ($clusterGroups.Count -eq 0) { continue }
            $group = $clusterGroups[0]
            $sgId = [string]$group.GroupId
            if ($KnownClusterSg -and $sgId -cne $KnownClusterSg) { continue }
            # Do not remove SGs while any ENI is still present in this VPC.
            $enisNow = AwsJson @('ec2','describe-network-interfaces','--filters',"Name=vpc-id,Values=$VpcId")
            if (@($enisNow.NetworkInterfaces).Count -gt 0) { continue }
            # Reject incoming/outgoing cross-SG references (self-reference is okay).
            $allGroups = AwsJson @('ec2','describe-security-groups')
            $referencers = @($allGroups.SecurityGroups | Where-Object {
                $other = $_
                if ($other.GroupId -eq $sgId) { return $false }
                $rules = @($other.IpPermissions) + @($other.IpPermissionsEgress)
                foreach ($rule in $rules) {
                    if (@($rule.UserIdGroupPairs | Where-Object { $_.GroupId -ceq $sgId }).Count -gt 0) { return $true }
                }
                return $false
            })
            if ($referencers.Count -gt 0) {
                Emit 'Warning' "Cluster SG $sgId is referenced by another SG. Refusing deletion."
                continue
            }
            & aws ec2 delete-security-group --group-id $sgId --profile $Profile --region $Region | Out-Null
            if ($LASTEXITCODE -eq 0) { Emit 'DeletedSG' "Deleted leftover EKS-created cluster SG $sgId." }
            else { Emit 'Warning' "AWS refused cluster SG deletion $sgId; leaving it for inspection." }
        }
    } catch {
        Emit 'MonitorError' $_.Exception.Message
    }
}

# --------------------- MAIN ---------------------
if (-not (Test-Path -LiteralPath $TerraformDir -PathType Container)) {
    throw "Missing terraform directory: $TerraformDir"
}
Require-Command 'terraform'
$state = @(& terraform "-chdir=$TerraformDir" state list)
Assert-ExitCode 'terraform state list'
Write-Host "[STATE] $($state.Count) entries; EKS=$ClusterName region=$AwsRegion"
if ($state.Count -eq 0) {
    Write-Host '[STATE] Empty. No destroy performed. AWS resource inventory may still be necessary.'
    return
}
if (-not $Execute) {
    Write-Host '[READ-ONLY] State check only. No AWS/Kubernetes changes.'
    Write-Host 'Run -Execute for destroy, optionally adding -AutoCleanupOrphans for guarded recovery.'
    return
}
Require-Command 'aws'
$identity = Invoke-AwsJson @('sts','get-caller-identity')
if ([string]$identity.Account -cne $ExpectedAccountId) {
    throw "AWS account mismatch: expected $ExpectedAccountId, got $($identity.Account)"
}
$vpcId = Get-VpcIdFromState $state
if (-not $vpcId) { throw 'aws_vpc.main is not in state; refusing to infer which VPC to clean.' }
$vpcLookup = Invoke-AwsJson @('ec2','describe-vpcs','--filters',"Name=vpc-id,Values=$vpcId")
$liveVpc = @($vpcLookup.Vpcs).Count -eq 1
if ($AutoCleanupOrphans -and -not $liveVpc) {
    Write-Host '[NOTE] VPC absent already; orphan cleanup will be skipped.'
}
$clusters = Invoke-AwsJson @('eks','list-clusters')
$clusterExists = @($clusters.clusters) -contains $ClusterName
$clusterInfo = $null
$clusterSg = $null
if ($clusterExists) {
    $clusterInfo = Invoke-AwsJson @('eks','describe-cluster','--name',$ClusterName)
    if ([string]$clusterInfo.cluster.resourcesVpcConfig.vpcId -cne $vpcId) {
        throw 'EKS cluster VPC and Terraform state VPC mismatch.'
    }
    if ($clusterInfo.cluster.status -cne 'ACTIVE') {
        throw "EKS status $($clusterInfo.cluster.status): wait until ACTIVE or fully deleted before resuming."
    }
    $clusterSg = [string]$clusterInfo.cluster.resourcesVpcConfig.clusterSecurityGroupId
    if ($clusterSg -cnotmatch '^sg-[0-9a-f]+$') { throw 'Cannot establish EKS-created cluster SG ID.' }
} elseif ($liveVpc) {
    # Partial destroy resume: cluster is already deleted. Only trust an exact SG name + VPC.
    $groups = Invoke-AwsJson @('ec2','describe-security-groups','--filters',"Name=vpc-id,Values=$vpcId")
    $sgRegex = '^eks-cluster-sg-' + [regex]::Escape($ClusterName) + '-[0-9]+$'
    $candidates = @($groups.SecurityGroups | Where-Object { $_.GroupName -match $sgRegex })
    if ($candidates.Count -gt 1) { throw 'Ambiguous EKS cluster SG candidates in VPC.' }
    if ($candidates.Count -eq 1) { $clusterSg = [string]$candidates[0].GroupId }
}
Write-Host "[TARGET] account=$ExpectedAccountId VPC=$vpcId EKS=$ClusterName clusterSG=$clusterSg"
if ($AutoCleanupOrphans) {
    Write-Warning 'AutoCleanupOrphans deletes only validated VPC CNI orphan ENIs and EKS-created cluster SG after cluster removal.'
}
$answer = Read-Host 'PERMANENT DATA/INFRASTRUCTURE DELETION. Type DESTROY to continue'
if ($answer -cne 'DESTROY') { throw 'Cancelled; no resources changed by script.' }

if ($clusterExists) {
    Require-Command 'kubectl'
    Remove-NlbServiceSafely $vpcId ([string]$clusterInfo.cluster.arn) $state
} elseif ($liveVpc) {
    # Never force LB deletion after controller / EKS has disappeared.
    $lbs = Invoke-AwsJson @('elbv2','describe-load-balancers')
    if (@($lbs.LoadBalancers | Where-Object { $_.VpcId -eq $vpcId }).Count -gt 0) {
        throw 'EKS is gone but LB remains in VPC; requires manual inspection before retry.'
    }
    Write-Host '[RESUME] EKS cluster absent; skip kubectl and DNS-only plan. Terraform will refresh remaining state.'
}

$terraformOwnsEni = @($state | Where-Object { $_ -match '(^|\.)aws_network_interface\.' }).Count -gt 0
$maxAttempts = 1
if ($AutoCleanupOrphans -and $liveVpc) { $maxAttempts = 2 }
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $monitor = $null
    $deletedCount = 0
    $monitorError = $null
    if ($AutoCleanupOrphans -and $liveVpc) {
        $monitor = Start-Job -Name 'YobiV1OrphanWatch' -ScriptBlock $OrphanMonitor -ArgumentList `
            $AwsProfile,$AwsRegion,$ExpectedAccountId,$ClusterName,$vpcId,$clusterSg,$terraformOwnsEni
        Write-Host '[WATCH] Guarded orphan ENI / cluster SG watcher started (details printed after Terraform returns).'
    }
    try {
        Write-Host "[TERRAFORM] Destroy attempt $attempt/$maxAttempts ..."
        & terraform "-chdir=$TerraformDir" destroy -var=enable_nlb_dns=false -auto-approve -input=false
        $exit = $LASTEXITCODE
    } finally {
        if ($null -ne $monitor) {
            if ($monitor.State -eq 'Running') { Stop-Job -Job $monitor }
            $events = @(Receive-Job -Job $monitor -ErrorAction SilentlyContinue)
            foreach ($event in $events) {
                if ($null -ne $event -and $event.PSObject.Properties['Kind']) {
                    Write-Host "[WATCH][$($event.Kind)] $($event.Message)"
                    if ($event.Kind -in @('DeletedENI','DeletedSG')) { $deletedCount++ }
                    if ($event.Kind -eq 'MonitorError') { $monitorError = [string]$event.Message }
                }
            }
            Remove-Job -Job $monitor -Force
        }
    }
    if ($monitorError) {
        if ($exit -ne 0) { throw "Orphan watcher failed: $monitorError. Inspect dependencies before retry." }
        Write-Warning "Orphan watcher warning: $monitorError. Terraform succeeded; checking state/VPC next."
    }
    if ($exit -eq 0) { break }
    if ($attempt -eq $maxAttempts -or $deletedCount -eq 0) {
        throw "Terraform destroy failed (exit $exit). Orphan cleanup actions=$deletedCount. Inspect dependencies before retry."
    }
    Write-Warning "Terraform destroy failed, but watcher safely removed $deletedCount orphan resource(s). Retry ONCE."
}

$leftState = @(& terraform "-chdir=$TerraformDir" state list)
Assert-ExitCode 'terraform state list after destroy'
if ($leftState.Count -gt 0) { throw "Destroy returned success but $($leftState.Count) state entries remain." }
$vpcAfter = Invoke-AwsJson @('ec2','describe-vpcs','--filters',"Name=vpc-id,Values=$vpcId")
if (@($vpcAfter.Vpcs).Count -gt 0) {
    throw "State empty, but VPC $vpcId still exists in AWS. Inspect manually."
}
Write-Host '[SUCCESS] Terraform state empty AND project VPC absent.'
Write-Host '[NOTE] Verify separate AWS resources and costs (e.g. ECR images, CloudFront, budgets).'
