# Local prepared catalog; no credentials are stored in it. Importing this module never calls AWS.
function Read-YobiCatalog([string]$Root){
    $folder=Join-Path $Root '.yobi-local/catalog';$path=Join-Path $folder 'catalog.json'
    if(-not(Test-Path -LiteralPath $path)){throw 'Prepared product catalog is missing. Run the local Excel preparation first.'}
    $catalog=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($catalog.schemaVersion -ne 1 -or @($catalog.products).Count -lt 1 -or @($catalog.products).Count -gt 1000){throw 'Invalid or empty catalog.'}
    $seen=@{}
    foreach($p in $catalog.products){
        if($p.sku -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$' -or $seen.ContainsKey($p.sku)){throw 'Invalid or duplicate catalog SKU.'};$seen[$p.sku]=$true
        if(-not $p.name -or $p.name.Length -gt 255 -or $p.description.Length -gt 1000){throw 'Invalid catalog text.'}
        if($p.gender -cnotin @('MEN','WOMEN','KIDS','UNISEX') -or $p.category -cnotin @('신발','의류','용품') -or $p.sportStyle -cnotin @('러닝','트레이닝','오리지널스','축구','스포츠웨어')){throw 'Invalid catalog taxonomy.'}
        foreach($number in @($p.price,$p.initialStock)){if($number -is [bool] -or [string]$number -notmatch '^\d+$' -or [long]$number -gt 2147483647){throw 'Invalid catalog price/stock.'}}
        if($p.image.path -cne ('images/'+$p.sku+'.png') -or $p.image.contentType -cne 'image/png' -or $p.image.sha256 -cnotmatch '^[A-F0-9]{64}$'){throw 'Invalid catalog image path/type/hash.'}
        $image=Join-Path $folder $p.image.path
        if(-not(Test-Path -LiteralPath $image) -or (Get-Item -LiteralPath $image).Length -ne $p.image.bytes -or $p.image.bytes -gt 20MB -or (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -cne $p.image.sha256){throw ('Catalog image missing or changed: '+$p.sku)}
    }
    return $catalog
}
function Get-YobiCatalogObjectKey($Product){return ('products/catalog/'+$Product.sku+'/'+$Product.image.sha256.ToLowerInvariant()+'.png')}
function ConvertTo-YobiSqlText([string]$Value){
    if($Value.Length -eq 0){return "''"}
    return ('CONVERT(0x'+([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-','')+' USING utf8mb4)')
}
function New-YobiCatalogSql($Catalog){
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("SET NAMES utf8mb4; SET SESSION sql_mode='STRICT_ALL_TABLES,NO_ENGINE_SUBSTITUTION';")
    $lines.Add('CREATE TEMPORARY TABLE yobi_seed_guard(v INT NOT NULL CHECK(v=1));')
    $lines.Add("INSERT INTO yobi_seed_guard VALUES(IF(GET_LOCK('yobi-product-catalog',30)=1,1,0));")
    $lines.Add("INSERT INTO yobi_seed_guard SELECT IF(COUNT(*)=10,1,0) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='product' AND column_name IN ('id','name','category','description','image_url','price','stock_quantity','member_id','created_time','updated_time');")
    $lines.Add("INSERT INTO yobi_seed_guard SELECT IF(COUNT(*)=1,1,0) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='product' AND engine='InnoDB';")
    $lines.Add("SELECT COUNT(*),MIN(id) INTO @owner_count,@owner_id FROM member WHERE login_id='admin' AND role='ADMIN'; INSERT INTO yobi_seed_guard VALUES(IF(@owner_count=1,1,0));")
    foreach($column in @(@('sku','VARCHAR(64)'),@('gender','VARCHAR(255)'),@('sport_style','VARCHAR(255)'))){
        $lines.Add(("SET @ddl=IF(EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='product' AND column_name='{0}'),'SELECT 1','ALTER TABLE product ADD COLUMN {0} {1} NULL'); PREPARE yobi_stmt FROM @ddl; EXECUTE yobi_stmt; DEALLOCATE PREPARE yobi_stmt;" -f $column[0],$column[1]))
    }
    $lines.Add("INSERT INTO yobi_seed_guard SELECT IF(COUNT(*)=0 OR (COUNT(*)=1 AND MIN(non_unique)=0 AND MIN(column_name)='sku'),1,0) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='product' AND index_name='uq_product_sku';")
    $lines.Add("SET @ddl=IF(EXISTS(SELECT 1 FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='product' AND index_name='uq_product_sku'),'SELECT 1','CREATE UNIQUE INDEX uq_product_sku ON product(sku)'); PREPARE yobi_stmt FROM @ddl; EXECUTE yobi_stmt; DEALLOCATE PREPARE yobi_stmt;")
    $lines.Add('START TRANSACTION;')
    $skus=New-Object 'System.Collections.Generic.List[string]'
    foreach($p in $Catalog.products){
        $image='https://sales-mall-dev-product-images-021158485482-ap-northeast-2.s3.ap-northeast-2.amazonaws.com/'+(Get-YobiCatalogObjectKey $p)
        $values=@($p.sku,$p.name,$p.category,$p.gender,$p.sportStyle,$p.description,$image)|ForEach-Object {ConvertTo-YobiSqlText ([string]$_)}
        $skus.Add($values[0])
        $lines.Add(('INSERT INTO product(sku,name,category,gender,sport_style,description,image_url,price,stock_quantity,member_id,created_time,updated_time) VALUES('+($values -join ',')+','+[string]$p.price+','+[string]$p.initialStock+',@owner_id,NOW(6),NOW(6)) ON DUPLICATE KEY UPDATE sku=product.sku;'))
    }
    $lines.Add(('INSERT INTO yobi_seed_guard SELECT IF(COUNT(*)='+$Catalog.products.Count+',1,0) FROM product WHERE sku IN ('+($skus -join ',')+');'))
    $lines.Add("COMMIT; SELECT CONCAT('YOBI_CATALOG_VERIFIED=',COUNT(*)) FROM product WHERE sku IN ("+($skus -join ',')+"); SELECT RELEASE_LOCK('yobi-product-catalog');")
    $lines.Add("SELECT CONCAT('YOBI_CATALOG_ID=',id) FROM product WHERE sku IN ("+($skus -join ',')+");")
    return ($lines -join "`n")
}
function Read-YobiCatalogNative([string]$Exe,[string[]]$Arguments,[switch]$AllowMissing){
    $prior=$ErrorActionPreference
    try{$ErrorActionPreference='Continue';$output=@(& $Exe @Arguments 2>&1);$code=$LASTEXITCODE}finally{$ErrorActionPreference=$prior}
    $text=$output -join "`n"
    if($code -ne 0){if($AllowMissing -and $text -match '\(404\)|\(NoSuchKey\)|\(NotFound\)'){return $null};throw ("Catalog command failed: $Exe $($Arguments[0]); $text")}
    return $text
}
function Assert-YobiCatalogS3Object($Object,$Product){
    $bytes=for($i=0;$i -lt 64;$i+=2){[Convert]::ToByte($Product.image.sha256.Substring($i,2),16)}
    if($Object.ContentLength -ne $Product.image.bytes -or $Object.Metadata.'yobi-sha256' -cne $Product.image.sha256 -or $Object.ChecksumSHA256 -cne [Convert]::ToBase64String([byte[]]$bytes)){throw ('Uploaded image verification failed: '+$Product.sku)}
}
function New-YobiCatalogJob([string]$Name){
    $labels=@{'app.kubernetes.io/managed-by'='yobi-catalog';'yobi-catalog-run'=$Name}
    return @{apiVersion='batch/v1';kind='Job';metadata=@{name=$Name;namespace='soldesk';labels=$labels};spec=@{backoffLimit=0;activeDeadlineSeconds=300;ttlSecondsAfterFinished=86400;template=@{metadata=@{labels=$labels};spec=@{restartPolicy='Never';automountServiceAccountToken=$false;containers=@(@{name='mysql';image='mysql@sha256:7dcddc01f13bab2f15cde676d44d01f61fc9f99fe7785e86196dfc07d358ae2b';command=@('bash','-ec','mysql --default-character-set=utf8mb4 --batch --skip-column-names --host="$DB_HOST" --user=admin --database=ordermsa < /catalog/seed.sql');env=@(@{name='DB_HOST';valueFrom=@{secretKeyRef=@{name='my-app-secrets';key='DB_HOST'}}},@{name='MYSQL_PWD';valueFrom=@{secretKeyRef=@{name='my-app-secrets';key='DB_PW'}}});resources=@{requests=@{cpu='50m';memory='64Mi'};limits=@{cpu='500m';memory='256Mi'}};securityContext=@{allowPrivilegeEscalation=$false;capabilities=@{drop=@('ALL')}};volumeMounts=@(@{name='catalog';mountPath='/catalog';readOnly=$true})});volumes=@(@{name='catalog';configMap=@{name=$Name}})}}}}
}
function Write-YobiCatalogResource($Resource,[string[]]$Kube){
    ($Resource|ConvertTo-Json -Depth 20 -Compress)|& kubectl @Kube create -f -|Out-Host
    if($LASTEXITCODE -ne 0){throw ('Catalog resource creation failed: '+$Resource.kind)}
}
function Invoke-YobiCatalogSeed([string]$Root){
    $catalog=Read-YobiCatalog $Root
    $sql=New-YobiCatalogSql $catalog
    if([Text.Encoding]::UTF8.GetByteCount($sql) -gt 900000){throw 'Catalog SQL is too large for the reviewed ConfigMap transport.'}
    $state=Read-YobiCatalogNative 'terraform' @("-chdir=$Root/terraform",'show','-json')|ConvertFrom-Json
    $resources=@($state.values.root_module.resources)
    $bucket=@($resources|Where-Object address -ceq 'aws_s3_bucket.product_images');$db=@($resources|Where-Object address -ceq 'aws_db_instance.main')
    $targetBucket='sales-mall-dev-product-images-021158485482-ap-northeast-2'
    if($bucket.Count -ne 1 -or $bucket[0].values.bucket -cne $targetBucket -or $db.Count -ne 1 -or $db[0].values.arn -notlike 'arn:aws:rds:ap-northeast-2:021158485482:db:*'){throw 'Catalog target is not the reviewed Terraform RDS/S3 stack.'}
    $cdn=@($resources|Where-Object address -ceq 'aws_cloudfront_distribution.product_images')
    if($cdn.Count -ne 1 -or $cdn[0].values.domain_name -cnotmatch '^[a-z0-9]+\.cloudfront\.net$'){throw 'Catalog CloudFront target missing or invalid.'}
    $context='arn:aws:eks:ap-northeast-2:021158485482:cluster/sales-mall-dev-eks'
    $kube=@('--context',$context,'-n','soldesk')
    $encoded=Read-YobiCatalogNative 'kubectl' ($kube+@('get','secret','my-app-secrets','-o','jsonpath={.data.DB_HOST}'))
    if([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) -cne $db[0].values.address){throw 'Catalog DB Secret host differs from exact Terraform RDS.'}
    Send-YobiEvent 'started' 'app' 'catalog/seed' 'check'
    $aws=@('--profile','eks-user','--region','ap-northeast-2','--expected-bucket-owner','021158485482','--output','json','--no-cli-pager')
    foreach($p in $catalog.products){
        $key=Get-YobiCatalogObjectKey $p
        $head=Read-YobiCatalogNative 'aws' (@('s3api','head-object','--bucket',$targetBucket,'--key',$key,'--checksum-mode','ENABLED')+$aws) -AllowMissing
        if(-not $head){
            [void](Read-YobiCatalogNative 'aws' (@('s3api','put-object','--bucket',$targetBucket,'--key',$key,'--body',(Join-Path $Root ('.yobi-local/catalog/'+$p.image.path)),'--content-type','image/png','--checksum-algorithm','SHA256','--metadata',('yobi-sha256='+$p.image.sha256))+$aws))
            $head=Read-YobiCatalogNative 'aws' (@('s3api','head-object','--bucket',$targetBucket,'--key',$key,'--checksum-mode','ENABLED')+$aws)
        }
        Assert-YobiCatalogS3Object ($head|ConvertFrom-Json) $p
        $response=Invoke-WebRequest -Uri ('https://'+$cdn[0].values.domain_name+'/'+$key) -Method Head -UseBasicParsing -TimeoutSec 30
        if($response.StatusCode -ne 200 -or [string]$response.Headers['Content-Type'] -notmatch '^image/png' -or [long]$response.Headers['Content-Length'] -ne $p.image.bytes){throw ('CloudFront image is not ready: '+$p.sku)}
        Write-Host ('[CATALOG] Image verified: '+$p.sku)
    }
    $name='yobi-products-'+[guid]::NewGuid().ToString('N').Substring(0,12)
    $dir=Join-Path $Root '.yobi-local/catalog-runs';[void][IO.Directory]::CreateDirectory($dir)
    $cm=@{apiVersion='v1';kind='ConfigMap';metadata=@{name=$name;namespace='soldesk';labels=@{'yobi-catalog-run'=$name}};data=@{'seed.sql'=$sql}}
    # Kubernetes input contains product data only. The DB password remains in the existing Secret.
    Write-YobiCatalogResource $cm $kube
    Write-YobiCatalogResource (New-YobiCatalogJob $name) $kube
    $receipt=@{job=$name;catalogSha256=(Get-FileHash -LiteralPath (Join-Path $Root '.yobi-local/catalog/catalog.json') -Algorithm SHA256).Hash;count=$catalog.products.Count;status='running';context=$context}
    $record=Join-Path $dir ($name+'.json');$receipt|ConvertTo-Json|Set-Content -LiteralPath $record -Encoding UTF8
    $deadline=[DateTime]::UtcNow.AddMinutes(6)
    do{
        $job=Read-YobiCatalogNative 'kubectl' ($kube+@('get','job',$name,'-o','json'))|ConvertFrom-Json
        if(-not $job.PSObject.Properties['status'] -or $null -eq $job.status){$job|Add-Member -NotePropertyName status -NotePropertyValue ([pscustomobject]@{}) -Force}
        if($job.status.PSObject.Properties['failed'] -and $job.status.failed -gt 0){throw ('Catalog Job failed; inspect job '+$name+'. Products are not claimed complete.')}
        if($job.status.PSObject.Properties['succeeded'] -and $job.status.succeeded -eq 1){break}
        if([DateTime]::UtcNow -ge $deadline){throw ('Catalog Job timed out; inspect '+$name+'. No automatic data reset.')}
        Write-Host '[CATALOG] Waiting for transactional SKU registration...';Start-Sleep -Seconds 5
    }while($true)
    $log=Read-YobiCatalogNative 'kubectl' ($kube+@('logs',('job/'+$name)))
    if($log -notmatch ('(?m)^YOBI_CATALOG_VERIFIED='+$catalog.products.Count+'\r?$')){throw 'Catalog verification count is missing.'}
    $ids=@([regex]::Matches($log,'(?m)^YOBI_CATALOG_ID=(\d+)\r?$')|ForEach-Object {$_.Groups[1].Value}|Sort-Object -Unique)
    if($ids.Count -ne $catalog.products.Count){throw 'Catalog product IDs are not fully verified.'}
    $response=Invoke-WebRequest -Uri 'https://server.sy84.store/product-service/product/list' -UseBasicParsing -TimeoutSec 30
    if($response.StatusCode -ne 200){throw 'Catalog public API failed.'}
    if($response.Content.TrimStart() -notmatch '^\['){throw 'Catalog public API is not a product array.'}
    $visible=$response.Content|ConvertFrom-Json
    foreach($id in $ids){if(-not @($visible|Where-Object {[string]$_.id -ceq $id}).Count){throw ('Seeded product is not visible through the public API: '+$id)}}
    $receipt.status='verified';$receipt|ConvertTo-Json|Set-Content -LiteralPath $record -Encoding UTF8
    foreach($kind in @('job','configmap')){
        $owned=Read-YobiCatalogNative 'kubectl' ($kube+@('get',$kind,$name,'-o','json'))|ConvertFrom-Json
        if($owned.metadata.labels.'yobi-catalog-run' -cne $name){throw 'Refusing unowned catalog job/configmap cleanup.'}
        [void](Read-YobiCatalogNative 'kubectl' ($kube+@('delete',$kind,$name,'--wait=false')))
    }
    Send-YobiEvent 'completed' 'app' 'catalog/seed' 'check'
    Write-Host ('[CATALOG] Verified '+$catalog.products.Count+' unique product SKUs and public API visibility; existing price/stock unchanged. No sample products invented.')
}
