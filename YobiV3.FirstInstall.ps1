# The first-install baseline is restored only in a new managed clone, never in the user's checkout.
function Get-YobiFirstInstallCache([string]$Root){
    $hash=[Security.Cryptography.SHA256]::Create();try{$key=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).ToLowerInvariant())))).Replace('-','').Substring(0,12)}finally{$hash.Dispose()}
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('YobiV3/Sources/'+$key))
}
function Assert-YobiFirstInstallCheckout([string]$Root,[string]$Checkout){
    $prefix=[IO.Path]::GetFullPath((Get-YobiFirstInstallCache $Root)).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath($Checkout)
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not(Test-Path -LiteralPath (Join-Path $full '.git/yobi-first-install'))){throw 'Not an owned isolated first-install checkout.'}
}
function Restore-YobiFirstInstallBaseline([string]$Root,[string]$Checkout){
    Assert-YobiFirstInstallCheckout $Root $Checkout
    $folder=Join-Path $PSScriptRoot 'first-install-baseline'
    $manifest=Get-Content -LiteralPath (Join-Path $folder 'manifest.json') -Raw|ConvertFrom-Json
    $zip=Join-Path $folder 'source.zip'
    if($manifest.schemaVersion -ne 1 -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -cne $manifest.bundleSha256){throw 'First-install baseline checksum mismatch.'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive=[IO.Compression.ZipFile]::OpenRead($zip);$files=@{}
    try{
        if($archive.Entries.Count -ne $manifest.files.Count){throw 'Invalid baseline entry count.'}
        foreach($entry in $archive.Entries){
            $name=$entry.FullName
            if($name -cnotmatch '^msa/(apigateway|member|product|ordering|frontend)/' -or $name -match '\\|(^|/)\.\.?(/|$)' -or $files.ContainsKey($name)){throw 'Unsafe first-install baseline path.'}
            $meta=@($manifest.files|Where-Object path -ceq $name);if($meta.Count -ne 1){throw 'Undeclared baseline file.'}
            $stream=$entry.Open();$memory=[IO.MemoryStream]::new();try{$stream.CopyTo($memory);$data=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
            $hash=[Security.Cryptography.SHA256]::Create();try{$digest=([BitConverter]::ToString($hash.ComputeHash($data))).Replace('-','')}finally{$hash.Dispose()}
            if($digest -cne $meta[0].sha256){throw 'First-install source hash mismatch.'}
            $files[$name]=$data
        }
    }finally{$archive.Dispose()}
    # Remove later-release application files only inside this owned clone. Never remove infrastructure or user data.
    foreach($service in @('apigateway','member','product','ordering','frontend')){
        $scope=Join-Path $Checkout "msa/$service/src"
        if(Test-Path -LiteralPath $scope){foreach($file in @(Get-ChildItem -LiteralPath $scope -File -Recurse)){
            $name=$file.FullName.Substring($Checkout.TrimEnd('\').Length+1).Replace('\','/')
            if(-not $files.ContainsKey($name)){Remove-Item -LiteralPath $file.FullName -Force}
        }}
    }
    foreach($name in $files.Keys){$dest=Join-Path $Checkout $name;[void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest));[IO.File]::WriteAllBytes($dest,$files[$name])}
    foreach($name in @('.github/workflows/deploy-yobi-patch.yml','scripts/prepare-storefront-manifests.py')){
        $later=Join-Path $Checkout $name
        if(Test-Path -LiteralPath $later -PathType Leaf){Remove-Item -LiteralPath $later -Force}
    }
    Write-Host ('[BASELINE] First-install application restored in isolated clone; '+$files.Count+' verified files. Original checkout and main untouched.')
}
function New-YobiFirstInstallCheckout([string]$Root,[string[]]$Changes){
    $origin=(Read-Native 'git' @('-C',$Root,'remote','get-url','origin')).Trim()
    if($origin -cnotin @('https://github.com/yobi84-sy/msa.git','git@github.com:yobi84-sy/msa.git')){throw 'Unexpected first-install origin.'}
    $parent=Get-YobiFirstInstallCache $Root;[void][IO.Directory]::CreateDirectory($parent)
    $checkout=Join-Path $parent ([guid]::NewGuid().ToString('N').Substring(0,12))
    Invoke-Checked 'git' @('clone','--single-branch','--branch','yobi-v1','--no-tags',$origin,$checkout)
    [IO.File]::WriteAllText((Join-Path $checkout '.git/yobi-first-install'),'owned')
    Assert-YobiFirstInstallCheckout $Root $checkout
    foreach($name in $Changes){
        if(-not(Test-PublishPath $name)){throw 'Unsupported install overlay path.'}
        $from=Join-Path $Root $name;$dest=Join-Path $checkout $name
        if(Test-Path -LiteralPath $from -PathType Leaf){[void][IO.Directory]::CreateDirectory((Split-Path -Parent $dest));[IO.File]::WriteAllBytes($dest,[IO.File]::ReadAllBytes($from))}
        elseif(Test-Path -LiteralPath $dest -PathType Leaf){Remove-Item -LiteralPath $dest -Force}
    }
    Restore-YobiFirstInstallBaseline $Root $checkout
    return $checkout
}
