#Requires -Version 5.1
# Shared, non-secret execution events. No cloud operations at import time.
function Send-YobiEvent([string]$Kind,[string]$Group,[string]$Address='',[string]$Action='',[string]$Detail='') {
    $event = [ordered]@{schema=1;time=[DateTime]::UtcNow.ToString('o');kind=$Kind;group=$Group;address=$Address;action=$Action;detail=$Detail}
    if ($env:YOBI_EVENT_FILE) {
        [IO.File]::AppendAllText($env:YOBI_EVENT_FILE,(($event|ConvertTo-Json -Compress)+"`n"),(New-Object Text.UTF8Encoding($false)))
    }
}
function Get-YobiGroup([string]$Address) {
    switch -Regex ($Address) {
        '^aws_iam_|^aws_eks_access_' { return 'iam' }
        '^aws_nat_gateway\.|^aws_eip\.' { return 'nat' }
        '^aws_vpc\.|^aws_subnet\.|^aws_route|^aws_internet_gateway\.|^aws_security_group' {
            if ($Address -match '^aws_route53_') { return 'dns' }; return 'vpc'
        }
        '^aws_eks_|^helm_release\.cluster_autoscaler' { return 'eks' }
        '^aws_db_' { return 'rds' }
        '^aws_s3_' { return 's3' }
        '^aws_cloudfront_' { return 'cloudfront' }
        '^aws_ecr_' { return 'ecr' }
        '^aws_acm_|^helm_release\.(cert_manager|msa_tls)|^kubernetes_.*cert' { return 'tls' }
        '^helm_release\.argocd' { return 'argo' }
        '^helm_release\.(nginx|aws_load)|^kubernetes_ingress' { return 'ingress' }
        '^helm_release\.metrics|^kubernetes_namespace' { return 'eks' }
        '^aws_sns_|^aws_cloudwatch_' { return 'alerts' }
        default { return 'other' }
    }
}
function Send-YobiPlan($Document) {
    foreach ($r in @($Document.resource_changes)) {
        if ($r.mode -ne 'managed') { continue }
        $group=Get-YobiGroup $r.address
        foreach ($action in @($r.change.actions)) {
            if ($action -eq 'no-op') { Send-YobiEvent 'present' $group $r.address; continue }
            if ($action -in @('create','update','delete')) { Send-YobiEvent 'planned' $group $r.address $action }
        }
    }
}
function Receive-YobiTerraformLine([string]$Line) {
    if (-not $Line.TrimStart().StartsWith('{')) { Write-Host $Line; return }
    try { $e=$Line|ConvertFrom-Json -ErrorAction Stop } catch { Write-Host $Line; return }
    # Deliberately do not persist the complete JSON event or values: diagnostics can contain inputs.
    $type=[string]$e.type
    if ($type -in @('apply_start','apply_complete','apply_errored','apply_progress')) {
        $addr=[string]$e.hook.resource.addr; $action=[string]$e.hook.action
        $kind=switch($type){'apply_start'{'started'} 'apply_complete'{'completed'} 'apply_errored'{'failed'} default{'heartbeat'}}
        Send-YobiEvent $kind (Get-YobiGroup $addr) $addr $action
        Write-Host "[TF] $addr $action $kind"
    } elseif ($type -eq 'diagnostic') {
        # Terraform marks sensitive values, but never write a diagnostic detail verbatim to event storage.
        Write-Host ("[TF {0}] {1}" -f $e.diagnostic.severity,$e.diagnostic.summary)
    } elseif ($e.PSObject.Properties['@message']) { Write-Host $e.'@message' }
}
function Convert-YobiSecureToPlain([Security.SecureString]$Secure) {
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
