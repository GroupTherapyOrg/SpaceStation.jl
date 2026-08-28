' Give a deno-desktop-built .msi a real identity and a per-user install location.
'
' Two separate defects in what `deno desktop -o X.msi` produces, both fixed here because neither can
' be fixed from inside the app:
'
' 1. INSTALL LOCATION. The package installs per-machine into ProgramFiles64Folder with ALLUSERS=1.
'    WebView2 keeps its user-data folder next to the executable, laufey (deno's webview host) calls
'    CreateCoreWebView2EnvironmentWithOptions with a NULL userDataFolder, and WEBVIEW2_USER_DATA_FOLDER
'    is a convention the host app must implement rather than something the loader applies - CI proved
'    that directly, with the variable set from process start and the profile still landing beside the
'    binary. So a standard user cannot write where WebView2 must write: issue #55. Retargeting the
'    install to LocalAppDataFolder makes that directory writable by whoever runs the app, and drops
'    the elevation prompt as a bonus.
'
' 2. UPGRADE IDENTITY. Every build ships ProductVersion 1.0.0, a ProductCode fixed by the app id, and
'    no Upgrade table, so Windows treats each new release as the version already installed and runs
'    maintenance mode instead of upgrading. Users could not receive the #55 fix by downloading the
'    fixed installer. Stamping the real version, a fresh ProductCode, and an Upgrade table wired to
'    FindRelatedProducts / RemoveExistingProducts makes it a proper major upgrade. UpgradeCode is
'    left alone: it is the stable identity tying releases together.
'
'   cscript //nologo stamp_msi.vbs dist\SpaceStation.msi 0.4.8
'
' VBScript, not PowerShell, on purpose. This drives the WindowsInstaller COM automation layer, whose
' View.Execute takes an optional Record parameter that neither pwsh 7 nor Windows PowerShell 5.1 will
' bind - both fail with `Execute,Params` regardless of how the argument is shaped. VBScript is the
' host Microsoft's own MSI samples use (WiRunSQL.vbs) and omits the parameter natively.
' Deliberately ASCII-only: a .vbs is read as ANSI, and non-ASCII text turns into mojibake.

Option Explicit

Const msiOpenDatabaseModeTransact = 1

Dim installer, db, msiPath, versionArg, productVersion, productCode, upgradeCode

If WScript.Arguments.Count < 2 Then
    WScript.Echo "usage: cscript //nologo stamp_msi.vbs <path-to-msi> <version>"
    WScript.Quit 2
End If

msiPath = WScript.Arguments(0)
versionArg = WScript.Arguments(1)
productVersion = NormalizeVersion(versionArg)
WScript.Echo "stamping " & msiPath & " as ProductVersion " & productVersion

Set installer = CreateObject("WindowsInstaller.Installer")
Set db = installer.OpenDatabase(msiPath, msiOpenDatabaseModeTransact)

upgradeCode = GetProperty("UpgradeCode")
If upgradeCode = "" Then
    WScript.Echo "this .msi has no UpgradeCode - refusing to stamp an installer with no stable identity"
    WScript.Quit 1
End If
productCode = "{" & UCase(Mid(CreateObject("Scriptlet.TypeLib").Guid, 2, 36)) & "}"

RunSQL "UPDATE `Property` SET `Value`='" & productVersion & "' WHERE `Property`='ProductVersion'"
RunSQL "UPDATE `Property` SET `Value`='" & productCode & "' WHERE `Property`='ProductCode'"

' The Upgrade table does not exist in a deno-built package, so create it before inserting.
On Error Resume Next
RunSQL "CREATE TABLE `Upgrade` (`UpgradeCode` CHAR(38) NOT NULL, `VersionMin` CHAR(20), `VersionMax` CHAR(20), `Language` CHAR(255), `Attributes` LONG NOT NULL, `Remove` CHAR(255), `ActionProperty` CHAR(72) NOT NULL PRIMARY KEY `UpgradeCode`, `VersionMin`, `VersionMax`, `Language`, `Attributes`)"
If Err.Number <> 0 Then
    WScript.Echo "Upgrade table already present - reusing it"
    Err.Clear
End If
On Error GoTo 0

' Attributes 257 = msidbUpgradeAttributesMigrateFeatures (1) OR VersionMinInclusive (256).
'
' Deliberately NO VersionMax, leaving the range unbounded above. The textbook choice - an upper bound
' of the version being installed - would silently fail the one upgrade that matters most: every build
' released before this script stamps itself ProductVersion 1.0.0, which is HIGHER than the real
' versions (0.4.x) stamped now, so those installs would fall outside a bounded range and never be
' superseded. Unbounded means a genuine downgrade also replaces a newer install; that is the accepted
' trade for being able to retire the 1.0.0 legacy.
RunSQL "DELETE FROM `Upgrade` WHERE `UpgradeCode`='" & upgradeCode & "'"
RunSQL "INSERT INTO `Upgrade` (`UpgradeCode`, `VersionMin`, `Attributes`, `ActionProperty`) VALUES ('" & upgradeCode & "', '0.0.0', 257, 'OLDERVERSIONBEINGUPGRADED')"

' An Upgrade row does nothing alone: FindRelatedProducts populates the action property, and
' RemoveExistingProducts uninstalls what it found. Sequenced early / after InstallValidate, which is
' the standard "remove the old product first" placement.
AddAction "InstallExecuteSequence", "FindRelatedProducts", 200
AddAction "InstallUISequence", "FindRelatedProducts", 200
AddAction "InstallExecuteSequence", "RemoveExistingProducts", 1401

' Retarget from per-machine Program Files to the per-user local app data folder. This is the actual
' fix for #55: the app cannot choose where WebView2 puts its folder, only where the binary lives.
On Error Resume Next
RunSQL "INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES ('LocalAppDataFolder', 'TARGETDIR', '.')"
Err.Clear
On Error GoTo 0
RunSQL "UPDATE `Directory` SET `Directory_Parent`='LocalAppDataFolder' WHERE `Directory`='INSTALLDIR'"
' ALLUSERS empty = per-user. Left at "1" the package still demands elevation and still resolves
' INSTALLDIR against the machine context.
RunSQL "UPDATE `Property` SET `Value`='' WHERE `Property`='ALLUSERS'"

db.Commit
WScript.Echo "stamped: ProductVersion=" & productVersion & " ProductCode=" & productCode & " UpgradeCode=" & upgradeCode
WScript.Echo "retargeted: per-user install under LocalAppDataFolder (was per-machine Program Files)"

Sub RunSQL(sql)
    Dim view
    Set view = db.OpenView(sql)
    view.Execute
    view.Close
End Sub

Sub AddAction(table, action, seq)
    On Error Resume Next
    RunSQL "DELETE FROM `" & table & "` WHERE `Action`='" & action & "'"
    Err.Clear
    On Error GoTo 0
    RunSQL "INSERT INTO `" & table & "` (`Action`, `Sequence`) VALUES ('" & action & "', " & seq & ")"
End Sub

Function GetProperty(name)
    Dim view, rec
    GetProperty = ""
    Set view = db.OpenView("SELECT `Value` FROM `Property` WHERE `Property`='" & name & "'")
    view.Execute
    Set rec = view.Fetch
    If Not rec Is Nothing Then GetProperty = rec.StringData(1)
    view.Close
End Function

' MSI ProductVersion allows major.minor.build only, with major/minor <= 255 and build <= 65535, and
' ignores anything past the third field when comparing. A tag like v0.4.8 is fine; strip a leading
' "v" and any prerelease suffix rather than letting msiexec reject the package.
Function NormalizeVersion(raw)
    Dim v, parts, i, out
    v = raw
    If Left(LCase(v), 1) = "v" Then v = Mid(v, 2)
    If InStr(v, "-") > 0 Then v = Left(v, InStr(v, "-") - 1)
    If InStr(v, "+") > 0 Then v = Left(v, InStr(v, "+") - 1)
    parts = Split(v, ".")
    out = ""
    For i = 0 To 2
        If i > 0 Then out = out & "."
        If i <= UBound(parts) Then
            out = out & CStr(CLng("0" & parts(i)))
        Else
            out = out & "0"
        End If
    Next
    NormalizeVersion = out
End Function
