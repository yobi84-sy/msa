#Requires -Version 5.1
[CmdletBinding()]param([string]$ProjectRoot='',[switch]$Execute,[switch]$InstallContinuation)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($ProjectRoot)){$ProjectRoot=$PSScriptRoot}
. (Join-Path $PSScriptRoot 'YobiV3.Common.ps1')
function Run-AlertCommand([string]$Exe,[string[]]$Arguments){
 $old=$ErrorActionPreference;$global:LASTEXITCODE=$null
 try{
  $ErrorActionPreference='Continue'
  if($Exe -eq 'terraform' -and $Arguments -contains 'apply'){
   $live=New-Object 'System.Collections.Generic.List[string]';$live.AddRange([string[]]$Arguments);$live.Insert($live.IndexOf('apply')+1,'-json')
   & $Exe @($live.ToArray()) 2>&1|ForEach-Object {Receive-YobiTerraformLine ([string]$_)}
  }else{& $Exe @Arguments 2>&1|ForEach-Object {Write-Host ([string]$_)}}
 }finally{$ErrorActionPreference=$old}
 if($LASTEXITCODE -ne 0){throw "$Exe failed; inspect preceding notification setup log."}
}
$root=[IO.Path]::GetFullPath($ProjectRoot);$pack=Join-Path $root 'operations/notifications'
if(-not $Execute){Write-Output 'CHECK ONLY: prepares two SNS topics, scoped IRSA publishers, two RDS alarms and GitOps monitoring collectors. No resources or messages changed.';return}
if(-not $InstallContinuation -and (Read-Host 'Type ALERTS to approve notification infrastructure and monitoring configuration') -cne 'ALERTS'){throw 'Cancelled.'}
$aws=@('--profile','eks-user','--region','ap-northeast-2','--output','json','--no-cli-pager')
$identity=(& aws sts get-caller-identity @aws)|ConvertFrom-Json
if($LASTEXITCODE -ne 0 -or $identity.Account -cne '021158485482'){throw 'Wrong AWS account.'}
$context='arn:aws:eks:ap-northeast-2:021158485482:cluster/sales-mall-dev-eks'
if((& kubectl config current-context).Trim() -cne $context){throw 'Wrong Kubernetes context.'}
$settings=Get-Content -LiteralPath (Join-Path $root '.yobi-local/operator-settings.json') -Raw|ConvertFrom-Json
if([string]$settings.alertEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$'){throw 'Configure a local alert email first.'}
$phones=(& aws sns list-sms-sandbox-phone-numbers @aws)|ConvertFrom-Json
if($LASTEXITCODE -ne 0){throw 'Cannot verify the approved SMS sandbox destination.'}
$verified=@($phones.PhoneNumbers|Where-Object Status -eq 'Verified')
if($verified.Count -gt 1){throw 'Multiple verified SMS destinations; review local recipients before setup.'}
$smsPhone=if($verified.Count -eq 1){[string]$verified[0].PhoneNumber}else{''}
if(-not $smsPhone){Write-Host '[SMS] No verified destination; email monitoring proceeds with SMS disabled.'}
$nodegroup=(& aws eks describe-nodegroup --cluster-name sales-mall-dev-eks --nodegroup-name sales-mall-dev-nodegroup @aws)|ConvertFrom-Json
if($LASTEXITCODE -ne 0){throw 'Cannot verify node scaling maximum.'}
$oldEmail=$env:TF_VAR_email;$oldPhone=$env:TF_VAR_sms_phone
$private=Join-Path $root '.yobi-local/notification-setup';[void][IO.Directory]::CreateDirectory($private)
$plan=Join-Path $private ([guid]::NewGuid().ToString('N')+'.tfplan')
$tf=Join-Path $pack 'terraform'
try{
 $env:TF_VAR_email=[string]$settings.alertEmail;$env:TF_VAR_sms_phone=$smsPhone
 $renderArgs=@((Join-Path $pack 'prepare_manifests.py'),'--max-nodes',[string]$nodegroup.nodegroup.scalingConfig.maxSize);if($smsPhone){$renderArgs+=,'--sms-enabled'}
 Run-AlertCommand 'python' $renderArgs
 Run-AlertCommand 'terraform' @("-chdir=$tf",'init','-input=false','-no-color')
 Run-AlertCommand 'terraform' @("-chdir=$tf",'plan','-input=false','-no-color',"-out=$plan")
 $planJson=(& terraform "-chdir=$tf" show -json $plan)|ConvertFrom-Json
 if($LASTEXITCODE -ne 0){throw 'Cannot read exact notification plan.'}
 Send-YobiPlan $planJson
 if((Read-Host 'Type yes to apply this exact saved plan') -cne 'yes'){throw 'Plan not approved.'}
 Run-AlertCommand 'terraform' @("-chdir=$tf",'apply','-input=false','-no-color',$plan)
 Run-AlertCommand 'aws' (@('cloudwatch','put-metric-alarm','--alarm-name','sales-mall-dev-rds-cpu-high','--namespace','AWS/RDS','--metric-name','CPUUtilization','--dimensions','Name=DBInstanceIdentifier,Value=sales-mall-dev-mysql','--statistic','Average','--period','300','--evaluation-periods','3','--threshold','80','--comparison-operator','GreaterThanThreshold','--treat-missing-data','missing','--alarm-actions','arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts','--ok-actions','arn:aws:sns:ap-northeast-2:021158485482:sales-mall-dev-alerts')+$aws)
 $renderArgs=@((Join-Path $pack 'prepare_manifests.py'),'--max-nodes',[string]$nodegroup.nodegroup.scalingConfig.maxSize);if($smsPhone){$renderArgs+=,'--sms-enabled'}
 Run-AlertCommand 'python' $renderArgs
 if(-not $InstallContinuation -and (Read-Host 'Type PUSH to publish reviewed monitoring configuration without rebuilding application images') -cne 'PUSH'){throw 'Monitoring source publish cancelled; created notification infrastructure retained.'}
 $cache=Join-Path $env:LOCALAPPDATA ('YobiV3/NotificationSources/'+[guid]::NewGuid().ToString('N').Substring(0,10))
 [void][IO.Directory]::CreateDirectory((Split-Path -Parent $cache))
 Run-AlertCommand 'git' @('clone','--single-branch','--branch','yobi-v1','--no-tags','https://github.com/yobi84-sy/msa.git',$cache)
 $overlay=Join-Path $pack 'gitops-overlay';$paths=@()
 foreach($file in Get-ChildItem -LiteralPath $overlay -File -Recurse){
  $relative=$file.FullName.Substring($overlay.Length+1).Replace('\','/')
  if($relative -notmatch '^msa/k8s/k8s-monitoring/(alerts-resources\.yml|prometheus-config\.yml|prometheus-depl_svc\.yml|kustomization\.yaml)$'){throw 'Unexpected monitoring overlay path.'}
  $dest=Join-Path $cache $relative;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest));[IO.File]::WriteAllBytes($dest,[IO.File]::ReadAllBytes($file.FullName));$paths+=,$relative
 }
 Run-AlertCommand 'kubectl' @('kustomize',(Join-Path $cache 'msa/k8s/k8s-monitoring'))
 $user=(& gh api user)|ConvertFrom-Json
 if($LASTEXITCODE -ne 0){throw 'Cannot verify GitHub publisher.'}
 Run-AlertCommand 'git' @('-C',$cache,'config','user.name',[string]$user.login)
 Run-AlertCommand 'git' @('-C',$cache,'config','user.email',($user.id.ToString()+'+'+$user.login+'@users.noreply.github.com'))
 Run-AlertCommand 'git' (@('-C',$cache,'add','--')+$paths)
 $dirty=@(& git -C $cache diff --cached --name-only)
 if($dirty.Count){
  Run-AlertCommand 'git' @('-C',$cache,'commit','-m','feat: add reviewed email alerts and order notification infrastructure [skip ci]')
  Run-AlertCommand 'git' @('-C',$cache,'push','origin','HEAD:yobi-v1')
 }
 $publishedRevision=(& git -C $cache rev-parse HEAD).Trim()
 if($LASTEXITCODE -ne 0 -or $publishedRevision -notmatch '^[0-9a-f]{40}$'){throw 'Cannot verify published monitoring revision.'}
 Run-AlertCommand 'kubectl' @('--context',$context,'annotate','application','msa-monitoring','-n','argocd','argocd.argoproj.io/refresh=hard','--overwrite')
 Send-YobiEvent 'started' 'alerts' 'notifications/configuration' 'create'
 $deadline=[DateTime]::UtcNow.AddMinutes(5);$ready=$false
 while([DateTime]::UtcNow -lt $deadline){
  $app=(& kubectl --context $context get application msa-monitoring -n argocd -o json --request-timeout=15s)|ConvertFrom-Json
  if($LASTEXITCODE -eq 0 -and $app.status.sync.status -eq 'Synced' -and $app.status.sync.revision -eq $publishedRevision -and $app.status.health.status -eq 'Healthy'){$ready=$true;break}
  Write-Host '[ALERTS] Waiting for monitoring GitOps reconciliation...';Start-Sleep -Seconds 5
 }
 if(-not $ready){throw 'Monitoring reconciliation timed out; keep created infrastructure and inspect Argo conditions.'}
 foreach($deployment in @('yobi-alertmanager','yobi-kube-state','yobi-blackbox','prometheus')){Run-AlertCommand 'kubectl' @('--context',$context,'rollout','status',"deployment/$deployment",'-n','monitoring','--timeout=180s')}
 Write-Host '[ALERTS] Monitoring configuration published. Confirm the NEW order-email subscription. SMS limit is ten publish attempts per UTC day; no test notifications sent.'
 Send-YobiEvent 'completed' 'alerts' 'notifications/configuration' 'create'
 foreach($topicName in @('sales-mall-dev-alerts','sales-mall-dev-orders-email')){
  $topicArn='arn:aws:sns:ap-northeast-2:021158485482:'+$topicName
  $subscription=(& aws sns list-subscriptions-by-topic --topic-arn $topicArn @aws)|ConvertFrom-Json
  if($LASTEXITCODE -ne 0){throw 'Cannot verify email subscription status.'}
  if(-not @($subscription.Subscriptions|Where-Object {$_.Protocol -eq 'email' -and $_.Endpoint -eq $settings.alertEmail -and $_.SubscriptionArn -like 'arn:*'}).Count){Send-YobiEvent 'subscription_pending' 'alerts' '' '' $topicName;Write-Host ('[EMAIL CONFIRMATION PENDING] '+$topicName)}
 }
}finally{
 $env:TF_VAR_email=$oldEmail;$env:TF_VAR_sms_phone=$oldPhone
 if(Test-Path -LiteralPath $plan){Remove-Item -LiteralPath $plan -Force}
}
