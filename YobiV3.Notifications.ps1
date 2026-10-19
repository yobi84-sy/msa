# Optional notification stack uses a separate state. Teardown before RDS/EKS.
function Remove-YobiNotificationInfrastructure([string]$Root) {
 $directory=Join-Path $Root 'operations/notifications/terraform'
 if(-not(Test-Path -LiteralPath (Join-Path $directory 'terraform.tfstate'))){return}
 $state=(Read-Native 'terraform' @("-chdir=$directory",'show','-json'))|ConvertFrom-Json
 if(-not $state.PSObject.Properties['values']){return}
 $managed=@($state.values.root_module.resources|Where-Object mode -eq 'managed')
 if(-not $managed.Count){return}
 foreach($resource in $managed){
  if([string]$resource.address -notmatch '^aws_(sns_topic\.(orders_email|orders_sms)|sns_topic_subscription\.(orders_email|orders_sms)\[0\]|iam_role\.(probe|publisher\["(ordering|alertmanager)"\])|iam_role_policy\.(probe|publish\["(ordering|alertmanager)"\])|cloudwatch_metric_alarm\.(rds_storage|rds_memory|availability)|cloudwatch_log_group\.probe|lambda_function\.probe|lambda_function_event_invoke_config\.probe|cloudwatch_event_rule\.probe|cloudwatch_event_target\.probe|lambda_permission\.probe)$'){throw 'Unexpected resource in notification state; teardown refused.'}
  if($resource.values.PSObject.Properties['arn']){
   $arn=[string]$resource.values.arn
   if($arn -match '^arn:aws[^:]*:[^:]*:[^:]*:(\d{12}):' -and $Matches[1] -cne '021158485482'){throw 'Notification state contains another account.'}
   if($arn -notmatch 'sales-mall-dev-'){throw 'Notification resource is outside the project name scope.'}
  }
 }
 $plan=New-PrivatePlanPath
 try{
  Invoke-Checked 'terraform' @("-chdir=$directory",'plan','-destroy','-input=false','-no-color',"-out=$plan")
  $doc=(Read-Native 'terraform' @("-chdir=$directory",'show','-json',$plan))|ConvertFrom-Json
  foreach($change in @($doc.resource_changes|Where-Object mode -eq 'managed')){
   if(@($change.change.actions|Where-Object {$_ -notin @('delete','no-op')}).Count){throw 'Notification teardown contains a non-delete action.'}
  }
  Write-Host '[ALERTS] Additional notification infrastructure deletion plan; main EKS/RDS still exist.'
  if((Read-Host 'Type yes to apply this exact saved plan') -cne 'yes'){throw 'Notification teardown cancelled.'}
  Invoke-Checked 'terraform' @("-chdir=$directory",'apply','-input=false','-no-color',$plan)
 }finally{Remove-OwnPlan $plan}
}
