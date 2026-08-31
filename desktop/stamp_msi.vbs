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
' 2. UPGRADE IDENTITY. Every build ships the SAME ProductVersion (deno.json's, currently 0.1.0 - an
'    earlier local probe of a version-less package reported 1.0.0, which is where that number in the
'    history comes from), a ProductCode fixed by the app id, and
'    no Upgrade table, so Windows treats each new release as the version already installed and runs
'    maintenance mode instead of upgrading. Users could not receive the #55 fix by downloading the
'    fixed installer. Stamping the real version, a fresh ProductCode, and an Upgrade table wired to
'    FindRelatedProducts / RemoveExistingProducts makes it a proper major upgrade. UpgradeCode is
'    left alone: it is the stable identity tying releases together.
'
'   cscript //nologo stamp_msi.vbs dist\SpaceStation.msi 0.4.8 icons\spacestation.ico
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

' A read-only file opens happily in transact mode and then rejects every write, so clear the
' attribute before touching anything.
Dim fso, f
Set fso = CreateObject("Scripting.FileSystemObject")
Set f = fso.GetFile(msiPath)
If (f.Attributes And 1) = 1 Then
    WScript.Echo "note: clearing the read-only attribute on " & msiPath
    f.Attributes = f.Attributes - 1
End If

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
If Not TryRunSQL("CREATE TABLE `Upgrade` (`UpgradeCode` CHAR(38) NOT NULL, `VersionMin` CHAR(20), `VersionMax` CHAR(20), `Language` CHAR(255), `Attributes` LONG NOT NULL, `Remove` CHAR(255), `ActionProperty` CHAR(72) NOT NULL PRIMARY KEY `UpgradeCode`, `VersionMin`, `VersionMax`, `Language`, `Attributes`)") Then
    WScript.Echo "Upgrade table already present - reusing it"
End If

' Attributes 257 = msidbUpgradeAttributesMigrateFeatures (1) OR VersionMinInclusive (256).
'
' Deliberately NO VersionMax, leaving the range unbounded above. Released builds carry deno.json's
' version (0.1.0), so a bound at the version being installed would in fact cover them - but the bound
' only has to be wrong once to strand a user on a broken build with no way to upgrade, and there is no
' upside to it here. Unbounded means a genuine downgrade also replaces a newer install; that is a
' cheaper failure than an upgrade that silently does nothing, which is the bug being fixed.
TryRunSQL "DELETE FROM `Upgrade` WHERE `UpgradeCode`='" & upgradeCode & "'"
RunSQL "INSERT INTO `Upgrade` (`UpgradeCode`, `VersionMin`, `Attributes`, `ActionProperty`) VALUES ('" & upgradeCode & "', '0.0.0', 257, 'OLDERVERSIONBEINGUPGRADED')"

' An Upgrade row does nothing alone: FindRelatedProducts populates the action property, and
' RemoveExistingProducts uninstalls what it found. Sequenced early / after InstallValidate, which is
' the standard "remove the old product first" placement.
AddAction "InstallExecuteSequence", "FindRelatedProducts", 200
AddAction "InstallUISequence", "FindRelatedProducts", 200
AddAction "InstallExecuteSequence", "RemoveExistingProducts", 1401

' Retarget from per-machine Program Files to the per-user local app data folder. This is the actual
' fix for #55: the app cannot choose where WebView2 puts its folder, only where the binary lives.
' A LocalAppDataFolder row may already exist; only "already exists" is tolerable here, and it is
' reported either way. Silently swallowing this is how the retarget failed while claiming success.
If Not TryRunSQL("INSERT INTO `Directory` (`Directory`, `Directory_Parent`, `DefaultDir`) VALUES ('LocalAppDataFolder', 'TARGETDIR', '.')") Then
    WScript.Echo "LocalAppDataFolder row already present - reusing it"
End If
RunSQL "UPDATE `Directory` SET `Directory_Parent`='LocalAppDataFolder' WHERE `Directory`='INSTALLDIR'"
' Declare a per-user install the modern way: ALLUSERS=2 with MSIINSTALLPERUSER=1.
'
' Simply removing ALLUSERS is the legacy idiom and it is not enough. It left the package half in
' machine context: installing a newer build over an older one RECONFIGURED the old product instead of
' upgrading it, and failed 1603 while trying to write rollback scripts under
' HKLM\Software\Microsoft\Windows\CurrentVersion\Installer (error 1402, access denied). ALLUSERS=2
' means "per-user if MSIINSTALLPERUSER says so", and the pair together is what actually puts the whole
' install - directories, registration, rollback - in the user's context.
'
' (Property.Value is NOT NULL and MSI reads an empty string as NULL, so these go in as DELETE+INSERT
' rather than SET Value='' - that constraint violation is what silently discarded an entire earlier
' stamping run.)
TryRunSQL "DELETE FROM `Property` WHERE `Property`='ALLUSERS'"
RunSQL "INSERT INTO `Property` (`Property`, `Value`) VALUES ('ALLUSERS', '2')"
TryRunSQL "DELETE FROM `Property` WHERE `Property`='MSIINSTALLPERUSER'"
RunSQL "INSERT INTO `Property` (`Property`, `Value`) VALUES ('MSIINSTALLPERUSER', '1')"

' Word Count bit 3 (value 8) in the summary stream declares that elevated privileges are not
' required. Without it Windows Installer still treats the package as one that may need machine-wide
' access, which is the other half of the HKLM rollback failure above.
Dim sumInfo, wordCount
Set sumInfo = db.SummaryInformation(2)
wordCount = sumInfo.Property(15)
If (wordCount And 8) = 0 Then
    sumInfo.Property(15) = wordCount Or 8
    sumInfo.Persist
    WScript.Echo "summary: set 'elevated privileges not required' (word count " & wordCount & " -> " & (wordCount Or 8) & ")"
Else
    WScript.Echo "summary: 'elevated privileges not required' already set"
End If

' ---- Shortcut + Add/Remove Programs icon (issue #63) ----
' The packager embeds no icon in the exe, so the Start Menu shortcut and the Programs list show
' the generic executable icon. The runtime half (WM_SETICON in the shell) covers the live
' taskbar; this covers the installer surfaces: an Icon-table stream referenced by the Shortcut
' row and by ARPPRODUCTICON. The argument is optional so older invocations keep working.
If WScript.Arguments.Count >= 3 Then
    Dim icoPath, iview, irec
    icoPath = WScript.Arguments(2)
    If Not fso.FileExists(icoPath) Then
        WScript.Echo "FAILED: icon file not found: " & icoPath
        WScript.Quit 1
    End If
    TryRunSQL "CREATE TABLE `Icon` (`Name` CHAR(72) NOT NULL, `Data` OBJECT NOT NULL PRIMARY KEY `Name`)"
    On Error Resume Next
    Set iview = db.OpenView("SELECT `Name`, `Data` FROM `Icon`")
    iview.Execute
    Set irec = installer.CreateRecord(2)
    irec.StringData(1) = "spacestation.ico"
    irec.SetStream 2, icoPath
    ' 3 = msiViewModifyAssign: insert-or-replace, so re-stamping an already-stamped .msi is legal
    iview.Modify 3, irec
    iview.Close
    CheckError "Icon table stream insert (" & icoPath & ")"
    On Error GoTo 0
    RunSQL "UPDATE `Shortcut` SET `Icon_`='spacestation.ico'"
    TryRunSQL "DELETE FROM `Property` WHERE `Property`='ARPPRODUCTICON'"
    RunSQL "INSERT INTO `Property` (`Property`, `Value`) VALUES ('ARPPRODUCTICON', 'spacestation.ico')"
End If

db.Commit
Set db = Nothing
Set installer = Nothing

' Commit reporting success is not evidence the writes landed - a run that claimed to stamp 0.4.7
' shipped an .msi still declaring 0.1.0 and still installing into Program Files. So reopen the file
' read-only and read the values back. If they did not persist, fail here, where the reason is
' visible, rather than three steps later in an install test.
Dim verifier, vdb, gotVersion, gotAllUsers, gotParent
Set verifier = CreateObject("WindowsInstaller.Installer")
Set vdb = verifier.OpenDatabase(msiPath, 0)  ' 0 = read-only
gotVersion = ReadOne(vdb, "SELECT `Value` FROM `Property` WHERE `Property`='ProductVersion'")
gotAllUsers = ReadOne(vdb, "SELECT `Value` FROM `Property` WHERE `Property`='ALLUSERS'")
gotParent = ReadOne(vdb, "SELECT `Directory_Parent` FROM `Directory` WHERE `Directory`='INSTALLDIR'")
Set vdb = Nothing
Set verifier = Nothing

Dim gotIcon
gotIcon = ReadOne(vdb, "SELECT `Icon_` FROM `Shortcut`")
WScript.Echo "verify: ProductVersion=" & gotVersion & " ALLUSERS=[" & gotAllUsers & "] (2 = per-user) INSTALLDIR parent=" & gotParent & " shortcut icon=[" & gotIcon & "]"
If gotVersion <> productVersion Then
    WScript.Echo "FAILED: ProductVersion did not persist (wanted " & productVersion & ", file says " & gotVersion & ")"
    WScript.Quit 1
End If
If WScript.Arguments.Count >= 3 And gotIcon <> "spacestation.ico" Then
    WScript.Echo "FAILED: the shortcut is not wired to the icon (Icon_=[" & gotIcon & "])"
    WScript.Quit 1
End If
If gotParent <> "LocalAppDataFolder" Then
    WScript.Echo "FAILED: INSTALLDIR still parented to " & gotParent & " - the per-user retarget did not persist"
    WScript.Quit 1
End If
WScript.Echo "stamped: ProductVersion=" & productVersion & " ProductCode=" & productCode & " UpgradeCode=" & upgradeCode
WScript.Echo "retargeted: per-user install under LocalAppDataFolder (was per-machine Program Files)"

Function ReadOne(database, sql)
    Dim view, rec
    ReadOne = ""
    Set view = database.OpenView(sql)
    view.Execute
    Set rec = view.Fetch
    If Not rec Is Nothing Then ReadOne = rec.StringData(1)
    view.Close
End Function

' For statements whose failure is expected and harmless: CREATE TABLE when the table is already
' there, INSERT of a row that already exists. Returns True on success. This exists because CheckError
' quits the script outright, which silently defeats any On Error Resume Next the caller wrapped
' around RunSQL - re-stamping an already-stamped .msi died on "table already exists" for exactly that
' reason.
Function TryRunSQL(sql)
    Dim view
    TryRunSQL = False
    On Error Resume Next
    Set view = db.OpenView(sql)
    If Err = 0 Then view.Execute
    If Err = 0 Then
        view.Close
        TryRunSQL = True
    Else
        Err.Clear
    End If
    On Error GoTo 0
End Function

Sub RunSQL(sql)
    Dim view
    On Error Resume Next
    Set view = db.OpenView(sql)
    CheckError "OpenView: " & sql
    view.Execute
    CheckError "Execute: " & sql
    view.Close
    CheckError "Close: " & sql
    On Error GoTo 0
End Sub

' "Msi API Error: Execute,Params" is MSI's generic "the Execute(Params) call failed" - it names the
' function and its argument, never the reason. The reason is in LastErrorRecord, so print that or the
' next failure is as opaque as the last one. Pattern taken from Microsoft's WiRunSQL.vbs sample.
Sub CheckError(context)
    Dim message, errRec
    If Err = 0 Then Exit Sub
    message = "FAILED " & context & vbLf & "  " & Err.Source & " " & Hex(Err) & ": " & Err.Description
    If Not installer Is Nothing Then
        Set errRec = installer.LastErrorRecord
        If Not errRec Is Nothing Then message = message & vbLf & "  MSI says: " & errRec.FormatText
    End If
    WScript.Echo message
    WScript.Quit 1
End Sub

Sub AddAction(table, action, seq)
    ' The row may not exist yet on a first stamp, and will on a re-stamp; either is fine.
    TryRunSQL "DELETE FROM `" & table & "` WHERE `Action`='" & action & "'"
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
