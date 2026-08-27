# Give a deno-desktop-built .msi a real identity, so users can actually upgrade.
#
# `deno desktop -o X.msi` writes the same installer identity into every build it ever produces:
# ProductVersion 1.0.0, a ProductCode derived only from the app identifier, and no Upgrade table at
# all. Windows Installer therefore sees a newer release as the version it already has — running the
# new .msi drops into maintenance mode (Repair / Remove) instead of upgrading, and the old app stays
# on disk. That is why a Windows user could not get the fix for issue #55 by downloading the fixed
# installer.
#
# This stamps the three things a major upgrade needs:
#   * ProductVersion  — the real release version, so the new build outranks the installed one
#   * ProductCode     — a fresh GUID, which is what makes it a major upgrade rather than a reinstall
#   * Upgrade table   — plus FindRelatedProducts / RemoveExistingProducts in the sequences, which is
#                       what actually removes the old product before laying down the new one
# UpgradeCode is deliberately left alone: it is the stable identity that ties releases together, and
# changing it would break upgrades from every build that came before.
#
#   pwsh -File stamp_msi.ps1 -Msi dist/SpaceStation.msi -Version 0.4.8
#
# Windows-only (it drives the WindowsInstaller COM automation layer).

param(
    [Parameter(Mandatory = $true)][string] $Msi,
    [Parameter(Mandatory = $true)][string] $Version
)

$ErrorActionPreference = "Stop"

# MSI ProductVersion allows major.minor.build only, with major/minor <= 255 and build <= 65535, and
# it IGNORES anything beyond the third field when comparing. A tag like v0.4.8 is fine; strip any
# leading "v" and any prerelease suffix rather than letting msiexec reject the package.
$clean = ($Version -replace '^v', '') -replace '[-+].*$', ''
$parts = $clean.Split('.')
if ($parts.Count -lt 3) { $parts = @($parts + @('0', '0'))[0..2] }
$product_version = "$($parts[0]).$($parts[1]).$($parts[2])"
Write-Host "stamping $Msi as ProductVersion $product_version"

$installer = New-Object -ComObject WindowsInstaller.Installer
# 1 = transact mode: changes are written when we call Commit, and dropped otherwise.
$db = $installer.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $installer, @((Resolve-Path $Msi).Path, 1))

# NOTE: View.Execute takes one (optional) Record parameter, so the argument array must be @($null)
# — passing a bare $null means "no arguments at all" and COM rejects it with
# `Exception calling "InvokeMember" with "5" argument(s): "Execute,Params"`.
function Invoke-Msi([string] $sql) {
    $view = $db.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $db, @($sql))
    $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, @($null))
    $view.GetType().InvokeMember("Close", "InvokeMethod", $null, $view, $null)
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($view) | Out-Null
}

function Get-MsiProperty([string] $name) {
    $view = $db.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $db, @("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$name'"))
    $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, @($null))
    $rec = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)
    $value = if ($null -eq $rec) { $null } else { $rec.GetType().InvokeMember("StringData", "GetProperty", $null, $rec, @(1)) }
    $view.GetType().InvokeMember("Close", "InvokeMethod", $null, $view, $null)
    return $value
}

$upgrade_code = Get-MsiProperty "UpgradeCode"
if (-not $upgrade_code) { throw "this .msi has no UpgradeCode — refusing to stamp an installer with no stable identity" }
$product_code = "{$([guid]::NewGuid().ToString().ToUpper())}"

Invoke-Msi "UPDATE ``Property`` SET ``Value``='$product_version' WHERE ``Property``='ProductVersion'"
Invoke-Msi "UPDATE ``Property`` SET ``Value``='$product_code' WHERE ``Property``='ProductCode'"

# The Upgrade table does not exist in a deno-built package, so create it before inserting.
try {
    Invoke-Msi "CREATE TABLE ``Upgrade`` (``UpgradeCode`` CHAR(38) NOT NULL, ``VersionMin`` CHAR(20), ``VersionMax`` CHAR(20), ``Language`` CHAR(255), ``Attributes`` LONG NOT NULL, ``Remove`` CHAR(255), ``ActionProperty`` CHAR(72) NOT NULL PRIMARY KEY ``UpgradeCode``, ``VersionMin``, ``VersionMax``, ``Language``, ``Attributes``)"
} catch {
    Write-Host "Upgrade table already present — reusing it"
}
# Attributes 257 = msidbUpgradeAttributesMigrateFeatures (1) | msidbUpgradeAttributesVersionMinInclusive (256).
#
# Deliberately NO VersionMax, which leaves the range unbounded above. The obvious choice — an upper
# bound of the version being installed — would silently fail to do the one upgrade that matters
# most: every build released before this script existed stamps itself ProductVersion 1.0.0, and 1.0.0
# is HIGHER than the real versions (0.4.x) we stamp now. Those installs would fall outside a bounded
# range and never be detected, so the broken builds would stay on disk forever. Unbounded means a
# genuine downgrade also replaces a newer install; that is the accepted trade for being able to
# supersede the 1.0.0 legacy.
Invoke-Msi "DELETE FROM ``Upgrade`` WHERE ``UpgradeCode``='$upgrade_code'"
Invoke-Msi "INSERT INTO ``Upgrade`` (``UpgradeCode``, ``VersionMin``, ``Attributes``, ``ActionProperty``) VALUES ('$upgrade_code', '0.0.0', 257, 'OLDERVERSIONBEINGUPGRADED')"

# An Upgrade row does nothing on its own: FindRelatedProducts has to run to populate the action
# property, and RemoveExistingProducts has to run to uninstall what it found. Sequence numbers put
# FindRelatedProducts early (right after CostFinalize's neighbourhood) and RemoveExistingProducts
# after InstallValidate, which is the standard "remove the old product first" placement.
foreach ($table in @("InstallExecuteSequence", "InstallUISequence")) {
    try {
        Invoke-Msi "DELETE FROM ``$table`` WHERE ``Action``='FindRelatedProducts'"
        Invoke-Msi "INSERT INTO ``$table`` (``Action``, ``Sequence``) VALUES ('FindRelatedProducts', 200)"
    } catch {
        Write-Host "could not add FindRelatedProducts to $table : $_"
    }
}
Invoke-Msi "DELETE FROM ``InstallExecuteSequence`` WHERE ``Action``='RemoveExistingProducts'"
Invoke-Msi "INSERT INTO ``InstallExecuteSequence`` (``Action``, ``Sequence``) VALUES ('RemoveExistingProducts', 1401)"

# Retarget the install from per-machine Program Files to the per-user local app data folder.
#
# This is the actual fix for issue #55, and it is here rather than in the app because the app cannot
# fix it. WebView2 puts its user-data folder next to the executable, laufey (the webview host deno
# desktop ships) calls CreateCoreWebView2EnvironmentWithOptions with a NULL userDataFolder, and
# WEBVIEW2_USER_DATA_FOLDER is an application-level convention the host must implement — not
# something the loader applies on its own. CI proved that directly: with the variable set from
# process start, WebView2 still wrote its profile beside the binary and left our folder empty.
#
# So the only lever left is WHERE the binary lives. Installed under %LOCALAPPDATA%\Programs, the
# folder beside it is writable by the user who runs it, and the whole failure mode disappears —
# no elevation, no UAC prompt, no write access to Program Files.
Invoke-Msi "INSERT INTO ``Directory`` (``Directory``, ``Directory_Parent``, ``DefaultDir``) VALUES ('LocalAppDataFolder', 'TARGETDIR', '.')"
Invoke-Msi "UPDATE ``Directory`` SET ``Directory_Parent``='LocalAppDataFolder' WHERE ``Directory``='INSTALLDIR'"
# ALLUSERS empty = per-user install. Left at "1" the package still demands elevation and still
# resolves INSTALLDIR against the machine context.
Invoke-Msi "UPDATE ``Property`` SET ``Value``='' WHERE ``Property``='ALLUSERS'"

$db.GetType().InvokeMember("Commit", "InvokeMethod", $null, $db, $null)
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($db) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($installer) | Out-Null

Write-Host "stamped: ProductVersion=$product_version ProductCode=$product_code UpgradeCode=$upgrade_code"
Write-Host "retargeted: per-user install under %LOCALAPPDATA%\\Programs (was per-machine Program Files)"
