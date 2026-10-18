#Requires -Version 5.1
# No AWS calls on import. Invoked only after identity/ownership/DESTROY approval and app quiescence.
function Send-YobiInventory($Resources) {
    foreach ($r in @($Resources|Where-Object mode -eq 'managed')) {
        Send-YobiEvent 'present' (Get-YobiGroup $r.address) $r.address
    }
}
function Get-YobiObjectList([string]$Bucket) {
    $doc=Read-Aws @('s3api','list-objects-v2','--bucket',$Bucket)
    return @(Get-Field $doc 'Contents' @() | Sort-Object Key)
}
function Get-YobiObjectFingerprint($Objects) {
    return (@($Objects|ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Key,$_.Size,$_.ETag,$_.LastModified }) -join "`n")
}
function Invoke-YobiDataBackup($Resources,[string]$RdsMode,[string]$S3Mode) {
    $db=@($Resources|Where-Object { $_.mode -eq 'managed' -and $_.address -ceq 'aws_db_instance.main' })
    $buckets=@($Resources|Where-Object { $_.mode -eq 'managed' -and $_.type -eq 'aws_s3_bucket' })
    if ($RdsMode -cnotin @('BACKUP','RESET') -or $S3Mode -cnotin @('BACKUP','RESET')) { throw 'Invalid backup mode.' }
    $run=[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
    $dir=Join-Path $env:LOCALAPPDATA "YobiV3/Backups/$run"
    [void][IO.Directory]::CreateDirectory($dir)
    $record=[ordered]@{schema=1;run=$run;account=$ExpectedAccountId;region=$AwsRegion;rdsMode=$RdsMode;s3Mode=$S3Mode;snapshots=@();buckets=@();verified=$false}
    $recordPath=Join-Path $dir 'backup-manifest.json'
    try {
        Write-Host "[BACKUP] RDS=$RdsMode S3=$S3Mode. Retained snapshots/buckets incur storage charges and are outside Terraform destroy."
        if ($RdsMode -eq 'BACKUP') {
            foreach ($r in $db) {
                $id=[string]$r.values.identifier
                $live=(Read-Aws @('rds','describe-db-instances','--db-instance-identifier',$id)).DBInstances[0]
                if ($live.DBInstanceArn -cne $r.values.arn -or $live.DBSubnetGroup.VpcId -cne $vpcId) { throw 'RDS backup ownership mismatch.' }
                if ($live.DBInstanceStatus -cne 'available') { throw 'RDS must be available before snapshot. No deletion.' }
                $snapshotId="yobi-final-$run"
                Send-YobiEvent 'started' 'rds' 'backup/rds' 'backup'
                $null=Read-Aws @('rds','create-db-snapshot','--db-instance-identifier',$id,'--db-snapshot-identifier',$snapshotId,'--tags','Key=YobiBackup,Value=true',"Key=SourceVpc,Value=$vpcId")
                $snapshotRecord=@{source=$id;id=$snapshotId;arn='';encrypted=$true;verified=$false}
                $record.snapshots+=,$snapshotRecord
                $record|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $recordPath -Encoding UTF8
                $deadline=[DateTime]::UtcNow.AddMinutes(60)
                do {
                    $snap=(Read-Aws @('rds','describe-db-snapshots','--db-snapshot-identifier',$snapshotId)).DBSnapshots[0]
                    if ($snap.Status -eq 'available') { break }
                    if ($snap.Status -in @('failed','deleted') -or [DateTime]::UtcNow -ge $deadline) { throw 'RDS snapshot failed/timed out. No data deletion.' }
                    Write-Host "[BACKUP] RDS snapshot $snapshotId status=$($snap.Status)"
                    Start-Sleep -Seconds 15
                } while ($true)
                if ($snap.DBInstanceIdentifier -cne $id -or -not $snap.Encrypted) { throw 'Snapshot identity/encryption verification failed.' }
                $snapshotRecord.arn=$snap.DBSnapshotArn;$snapshotRecord.encrypted=$snap.Encrypted;$snapshotRecord.verified=$true
                Send-YobiEvent 'completed' 'rds' 'backup/rds' 'backup'
                $record|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $recordPath -Encoding UTF8
            }
        }
        if ($S3Mode -eq 'BACKUP') {
            foreach ($r in $buckets) {
                $source=[string]$r.values.id
                # Exact state-owned bucket only. Cross-account access is rejected by expected owner on every copy/get.
                Invoke-Checked 'aws' @('s3api','head-bucket','--bucket',$source,'--expected-bucket-owner',$ExpectedAccountId,'--profile',$AwsProfile,'--region',$AwsRegion)
                $versioning=Read-Aws @('s3api','get-bucket-versioning','--bucket',$source,'--expected-bucket-owner',$ExpectedAccountId)
                if ((Get-Field $versioning 'Status' '') -in @('Enabled','Suspended')) { throw 'Versioned S3 requires a version-aware backup. Refusing destructive cleanup; this mode covers the current unversioned project bucket only.' }
                $destination="yobi-backup-$ExpectedAccountId-$run"
                $entry=@{source=$source;backup=$destination;objects=@();created=$false;verified=$false}
                $record.buckets+=,$entry
                $record|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $recordPath -Encoding UTF8
                Send-YobiEvent 'started' 's3' "backup/$source" 'backup'
                $null=Read-Aws @('s3api','create-bucket','--bucket',$destination,'--create-bucket-configuration',"LocationConstraint=$AwsRegion")
                $entry.created=$true
                $record|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $recordPath -Encoding UTF8
                $null=Read-Aws @('s3api','put-public-access-block','--bucket',$destination,'--public-access-block-configuration','BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true')
                $encryptionFile=Join-Path $dir 's3-encryption.json'
                [IO.File]::WriteAllText($encryptionFile,'{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}',(New-Object Text.UTF8Encoding($false)))
                $null=Read-Aws @('s3api','put-bucket-encryption','--bucket',$destination,'--server-side-encryption-configuration',("file://"+$encryptionFile))
                $null=Read-Aws @('s3api','put-bucket-tagging','--bucket',$destination,'--tagging',"TagSet=[{Key=YobiBackup,Value=true},{Key=SourceVpc,Value=$vpcId}]")
                $initial=@(Get-YobiObjectList $source)
                $record|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $recordPath -Encoding UTF8
                $download=Join-Path $dir 'source-object.bin';$check=Join-Path $dir 'backup-object.bin'
                foreach ($o in $initial) {
                    # Stream through local temporary files: full SHA256 checks content, including multipart objects.
                    Invoke-Checked 'aws' @('s3api','get-object','--bucket',$source,'--key',[string]$o.Key,'--expected-bucket-owner',$ExpectedAccountId,$download,'--profile',$AwsProfile,'--region',$AwsRegion)
                    $digest=(Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash
                    Invoke-Checked 'aws' @('s3','cp',$download,"s3://$destination/$($o.Key)",'--only-show-errors','--sse','AES256','--profile',$AwsProfile,'--region',$AwsRegion)
                    Invoke-Checked 'aws' @('s3api','get-object','--bucket',$destination,'--key',[string]$o.Key,'--expected-bucket-owner',$ExpectedAccountId,$check,'--profile',$AwsProfile,'--region',$AwsRegion)
                    if ((Get-FileHash -LiteralPath $check -Algorithm SHA256).Hash -cne $digest -or (Get-Item -LiteralPath $check).Length -ne [long]$o.Size) { throw "S3 backup checksum mismatch: $($o.Key)" }
                    $entry.objects+=@{key=$o.Key;size=[long]$o.Size;sha256=$digest}
                    Remove-Item -LiteralPath $download,$check -Force
                    Write-Host "[BACKUP] Verified S3 object $($entry.objects.Count)/$($initial.Count)"
                }
                $current=@(Get-YobiObjectList $source);$copied=@(Get-YobiObjectList $destination)
                if ((Get-YobiObjectFingerprint $initial) -cne (Get-YobiObjectFingerprint $current) -or $copied.Count -ne $initial.Count) { throw 'S3 source changed during backup or destination count differs. No deletion.' }
                $entry.verified=$true
                Send-YobiEvent 'completed' 's3' "backup/$source" 'backup'
            }
        }
        $record.verified=$true
        Write-Host "[BACKUP] Requested backups verified. Manifest: $recordPath"
    } finally {
        $record|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $recordPath -Encoding UTF8
        foreach ($f in @('source-object.bin','backup-object.bin')) { $p=Join-Path $dir $f; if(Test-Path -LiteralPath $p){Remove-Item -LiteralPath $p -Force} }
    }
}
