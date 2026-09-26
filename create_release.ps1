param(
    [string]$Src = $PSScriptRoot,
    [string]$Dst = (Join-Path $PSScriptRoot 'dist\FS25_VehicleSync.zip')
)

# Only what the game needs goes into the archive (ModHub 7.5: only necessary files).
# tests/, tools/, _art/, dist/ and the markdown files stay out.
$include = @('modDesc.xml', 'icon_VehicleSync.dds', 'src', 'translations')
$allowedExtensions = @('.lua', '.xml', '.dds')
$srcLen = (Resolve-Path $Src).Path.TrimEnd('\').Length

$dstDir = Split-Path $Dst -Parent
if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force $dstDir | Out-Null }
if (Test-Path $Dst) { Remove-Item $Dst -Force }

Add-Type -Assembly 'System.IO.Compression.FileSystem'
$zip = [System.IO.Compression.ZipFile]::Open($Dst, 'Create')

foreach ($name in $include) {
    $item = Join-Path $Src $name
    if (-not (Test-Path $item)) { throw "Missing release item: $name" }

    $files = if (Test-Path $item -PathType Leaf) { @(Get-Item $item) } else { Get-ChildItem $item -Recurse -File }
    foreach ($file in $files) {
        if ($allowedExtensions -notcontains $file.Extension.ToLower()) { throw "Not allowed in release: $($file.FullName)" }
        $rel = $file.FullName.Substring($srcLen + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $rel) | Out-Null
    }
}

$zip.Dispose()
Write-Host "Done: $Dst"
