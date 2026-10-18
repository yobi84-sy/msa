# [Yobi V1 DB Secret] RDS 접속에 사용할 my-app-secrets 구성
# 비밀번호를 소스/YAML/Git에 하드코딩하지 않도록 실행 시 입력 또는 기존 AWS 값 활용
# Secret 생성 후 키(DB_HOST, DB_PW)가 존재하는지 Deploy에서 확인
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AwsProfile = 'eks-user',
    [string]$AwsRegion = 'ap-northeast-2',
    [string]$ClusterName = 'sales-mall-dev-eks',
    [string]$Namespace = 'soldesk'
)
$ErrorActionPreference = 'Stop'
function Invoke-AwsJson([string[]]$Arguments) {
    $json = & aws @Arguments --profile $AwsProfile --region $AwsRegion --output json
    if ($LASTEXITCODE -ne 0) { throw "AWS command failed: $($Arguments[0])" }
    return ($json | Out-String | ConvertFrom-Json)
}
$db = Invoke-AwsJson @('rds','describe-db-instances','--db-instance-identifier','sales-mall-dev-mysql')
$instance = $db.DBInstances[0]
$credential=$null
if ($instance.PSObject.Properties['MasterUserSecret'] -and $instance.MasterUserSecret.SecretArn) {
    $secret=Invoke-AwsJson @('secretsmanager','get-secret-value','--secret-id',$instance.MasterUserSecret.SecretArn)
    $credential=$secret.SecretString|ConvertFrom-Json
} elseif ($env:TF_VAR_db_password_wo) {
    $credential=[pscustomobject]@{password=$env:TF_VAR_db_password_wo}
} else {
    # Resume without password rotation: retain an already synchronized Secret.
    $current=& kubectl get secret my-app-secrets -n $Namespace --ignore-not-found -o json
    if ($LASTEXITCODE -ne 0) { throw 'DB Secret lookup failed.' }
    if ($current) {
        $existing=$current|Out-String|ConvertFrom-Json
        if ($existing.data.DB_HOST -and $existing.data.DB_PW -and [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($existing.data.DB_HOST)) -ceq $instance.Endpoint.Address) {
            Write-Host '[OK] Existing DB Secret retained; database password not rotated.'; return
        }
    }
    $secure=Read-Host 'DB_PASSWORD' -AsSecureString
    . (Join-Path $PSScriptRoot 'YobiV3.Common.ps1')
    try { $credential=[pscustomobject]@{password=(Convert-YobiSecureToPlain $secure)} } finally { $secure.Dispose() }
}
if (-not $credential.password -or -not $instance.Endpoint.Address) { throw 'RDS password or endpoint unavailable.' }
$secretObject = @{
  apiVersion = 'v1'; kind = 'Secret'; type = 'Opaque'
  metadata = @{ name='my-app-secrets'; namespace=$Namespace }
  stringData = @{ DB_HOST=[string]$instance.Endpoint.Address; DB_PW=[string]$credential.password }
}
try {
  $manifest = $secretObject | ConvertTo-Json -Compress -Depth 6
  $manifest | & kubectl apply --server-side --field-manager=yobi-v1-bootstrap -f - | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'kubectl apply my-app-secrets failed.' }
  Write-Host '[OK] RDS DB Secret synchronized (password not printed).'
} finally {
  Remove-Variable manifest,credential,secretObject,secret -ErrorAction SilentlyContinue
}
