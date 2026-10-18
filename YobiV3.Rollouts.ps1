# Observe deployments while Argo is still syncing, rather than animating only after all apps are healthy.
# Called only after account/context/revision checks in real Deploy.
$script:YobiObservedDeployments=@{}
function Publish-YobiDeploymentState([string]$Group,[string]$Address,[string]$State) {
    if ($script:YobiObservedDeployments[$Address] -ceq $State) { return }
    if ($State -eq 'completed' -and -not $script:YobiObservedDeployments.ContainsKey($Address)) { Send-YobiEvent 'started' $Group $Address 'create' }
    Send-YobiEvent $State $Group $Address 'create'
    $script:YobiObservedDeployments[$Address]=$State
}
function Update-YobiDeploymentState([bool]$MonitoringSynced=$false) {
    $script:YobiCurrentReady=@{}
    foreach($ns in @('soldesk','monitoring')){
        $json=Read-Native 'kubectl' @('get','deployments','-n',$ns,'-o','json','--request-timeout=20s')
        $doc=$json|ConvertFrom-Json
        foreach($d in @($doc.items)){
            $name=[string]$d.metadata.name
            if($ns -eq 'soldesk'){
                if($name -notin @($Services|ForEach-Object {"$_-depl"})){continue}
                $service=$name -replace '-depl$',''
                $expected="$Registry/${RepositoryPrefix}-${service}:$($script:ExpectedRolloutTag)"
                if(@($d.spec.template.spec.containers|Where-Object image -ceq $expected).Count -ne 1){continue}
                $group='app';$canComplete=$true
            }else{
                if($name -notin @('prometheus','grafana')){continue}
                $group=$name;$canComplete=$MonitoringSynced
            }
            $address="deployment/$name"
            $replicas=[int](Get-Field $d.spec 'replicas' 1)
            $st=Get-Field $d 'status'
            $ready=$canComplete -and $replicas -gt 0 -and [long](Get-Field $st 'observedGeneration' 0) -ge [long]$d.metadata.generation -and [int](Get-Field $st 'updatedReplicas' 0) -eq $replicas -and [int](Get-Field $st 'readyReplicas' 0) -eq $replicas -and [int](Get-Field $st 'availableReplicas' 0) -eq $replicas
            $script:YobiCurrentReady[$address]=[bool]$ready
            Publish-YobiDeploymentState $group $address $(if($ready){'completed'}else{'started'})
        }
    }
}
