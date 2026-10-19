#Requires -Version 5.1
# Imported by Deploy only after execution approval. Never writes plaintext credentials to disk.
function Set-YobiDbInput {
    $secure=Read-Host 'DB_PASSWORD' -AsSecureString
    try {
        $plain=Convert-YobiSecureToPlain $secure
        # RDS MySQL master credentials: printable ASCII excluding space / " @; use 12..41 for this project.
        if ($plain.Length -lt 12 -or $plain.Length -gt 41 -or $plain -match '[^\x21-\x7e]|[/"@]') {
            throw 'DB password: 12-41 printable ASCII characters; exclude spaces, /, double quote and @.'
        }
        $env:TF_VAR_db_password_wo=$plain
    } finally { $secure.Dispose(); Remove-Variable plain -ErrorAction SilentlyContinue }
}
function Initialize-YobiBcrypt {
    $dll=Join-Path $PSScriptRoot 'lib/BCrypt.Net-Next.dll'
    $manifest=Join-Path $PSScriptRoot 'lib/manifest.json'
    if(-not [IO.File]::Exists($dll) -or -not [IO.File]::Exists($manifest)){throw 'Missing reviewed BCrypt dependency.'}
    # Pinned to the reviewed official NuGet 4.0.3 net462 DLL; never trust a changed manifest alone.
    $reviewed='5A796A01A1BDC540BC8BA3B0DD7CDF0F029C265DC0B2FE59604350BEA0E69C4F'
    $meta=Get-Content -LiteralPath $manifest -Raw -Encoding UTF8|ConvertFrom-Json
    $stream=[IO.File]::OpenRead($dll);$sha=[Security.Cryptography.SHA256]::Create()
    try {$actual=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')}finally{$sha.Dispose();$stream.Dispose()}
    if($meta.sha256 -cne $reviewed -or $actual -cne $reviewed){throw 'BCrypt dependency checksum mismatch; file remains blocked.'}
    # Internet ZIP extraction can mark this exact known dependency as remote.
    # Only its download-zone marker is removed, after verification. No recursive unblocking or AV exclusions.
    $zone=Get-Item -LiteralPath $dll -Stream Zone.Identifier -ErrorAction SilentlyContinue
    if($null -ne $zone){
        Microsoft.PowerShell.Utility\Unblock-File -LiteralPath $dll -ErrorAction Stop
        Write-Host '[DEPENDENCY] Reviewed BCrypt DLL download marker cleared after SHA256 verification.'
    }
    if(-not ('BCrypt.Net.BCrypt' -as [type])){Add-Type -Path $dll -ErrorAction Stop}
}
function Ensure-YobiArgoPassword {
    $existing=(Read-Native 'kubectl' @('get','secret','argocd-secret','-n','argocd','-o','json'))|ConvertFrom-Json
    if ($existing.metadata.PSObject.Properties['annotations'] -and $existing.metadata.annotations.PSObject.Properties['yobi.dev/operator-password']) {
        Write-Host '[ARGO] Operator password already configured; preserved.'; return
    }
    Initialize-YobiBcrypt
    $secure=Read-Host 'ARGOCD_ADMIN_PASSWORD' -AsSecureString
    try {
        $plain=Convert-YobiSecureToPlain $secure
        if ($plain.Length -lt 12 -or [Text.Encoding]::UTF8.GetByteCount($plain) -gt 72) { throw 'Argo CD password requires 12+ characters and at most 72 UTF-8 bytes.' }
        $hash=[BCrypt.Net.BCrypt]::HashPassword($plain,12)
        if (-not $existing.PSObject.Properties['data']) { $existing | Add-Member -NotePropertyName data -NotePropertyValue ([pscustomobject]@{}) }
        $existing.data | Add-Member -Force -NotePropertyName 'admin.password' -NotePropertyValue ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($hash)))
        $existing.data | Add-Member -Force -NotePropertyName 'admin.passwordMtime' -NotePropertyValue ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))))
        if (-not $existing.metadata.PSObject.Properties['annotations']) { $existing.metadata|Add-Member -NotePropertyName annotations -NotePropertyValue ([pscustomobject]@{}) }
        $existing.metadata.annotations | Add-Member -Force -NotePropertyName 'yobi.dev/operator-password' -NotePropertyValue 'configured'
        # Keep resourceVersion for optimistic concurrency; replace object through stdin.
        ($existing|ConvertTo-Json -Depth 20 -Compress) | & kubectl replace -f - | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Argo CD password update failed (possible concurrent Secret change). No force retry.' }
        Invoke-Checked 'kubectl' @('delete','secret','argocd-initial-admin-secret','-n','argocd','--ignore-not-found')
        Send-YobiEvent 'completed' 'argo' 'argocd/password' 'update'
        Write-Host '[ARGO] Operator admin password configured; generated initial password removed.'
    } finally { $secure.Dispose(); Remove-Variable plain,hash,patch,patchJson -ErrorAction SilentlyContinue }
}
