; DMGAssistUpdater: a tray icon that keeps DMGAssist and DMGAssist_Watchdog on the latest nightly build, in every
; supported World of Warcraft install on this PC (retail and WoW Forever). AutoHotkey v2; the nightly build also
; ships it compiled as DMGAssistUpdater.exe, which needs nothing installed.
;
; Run it once (double-click), from wherever it was downloaded:
;   - it installs itself to %LOCALAPPDATA%\DMGAssistUpdater, replacing and closing any older copy (the old AutoHotkey
;     script version included),
;   - starts with Windows (a scheduled task with admin rights, so there is no prompt at every start: AddOns folders
;     under Program Files need admin rights to write),
;   - finds the WoW folders by itself (Blizzard's registry entry and the usual install locations): _retail_ and any
;     game folder whose name contains "forever",
;   - and checks the nightly release every 10 minutes, installing it into every folder that is not up to date.
; Hover the icon: the version in each folder and the time of the last check.
;
; Right-click: Check and update now (double-click does the same), Automatic updates, Start with Windows,
; Folders..., Open AddOns folders, Uninstall the updater, Exit.

#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
;@Ahk2Exe-SetName DMGAssist Updater
;@Ahk2Exe-SetDescription Keeps DMGAssist up to date
;@Ahk2Exe-SetCompanyName zonearc

if !A_IsAdmin {
    try {
        if A_IsCompiled
            Run('*RunAs "' A_ScriptFullPath '" /restart')
        else
            Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
    }
    ExitApp
}

AppName := "DMGAssist updater"
InstallDir := EnvGet("LOCALAPPDATA") "\DMGAssistUpdater"
ConfigDir := A_AppData "\DMGAssistUpdater"
DirCreate(ConfigDir)
IniFile := ConfigDir "\settings.ini"
TokenFile := ConfigDir "\token.txt"
TaskName := "DMGAssistUpdater"
OldStartupLink := A_Startup "\DMGAssistUpdater.lnk"
CheckEveryMs := 10 * 60 * 1000
LastCheck := "not yet"
LastError := ""
Busy := false
AutoUpdate := IniRead(IniFile, "options", "auto", "1") = "1"
Folders := LoadFolders()

; A copy started from anywhere else installs itself and hands over to the installed copy.
if (A_ScriptDir != InstallDir) {
    SelfInstall()
    ExitApp
}

UpdateScript := A_ScriptDir "\update.ps1"
try FileDelete(TokenFile) ; the repository is public: no token (one saved by the old version is removed)
BuildMenu()
RefreshTip()
SetTimer(AutoCheck, CheckEveryMs)
SetTimer(FirstCheck, -5000) ; a separate function: re-setting AutoCheck's timer would replace its 10-minute period
return

; ---------------------------------------------------------------------------
; Folders
; ---------------------------------------------------------------------------

; Every supported AddOns folder on this PC: game folders (with a Wow*.exe) named _retail_ or containing "forever",
; under the WoW roots from Blizzard's registry entries and the usual install locations.
FindFolders() {
    roots := Map()
    for key in ["HKLM\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
        "HKLM\SOFTWARE\Blizzard Entertainment\World of Warcraft"] {
        try {
            path := RTrim(RegRead(key, "InstallPath"), "\")
            if RegExMatch(path, "i)\\_[a-z_]+_$")
                path := RegExReplace(path, "\\[^\\]+$") ; ...\World of Warcraft\_retail_ -> ...\World of Warcraft
            roots[path] := true
        }
    }
    for base in [EnvGet("ProgramFiles(x86)"), EnvGet("ProgramFiles"), "C:\Games", "D:\Games", "D:\", "E:\"] {
        base := RTrim(base, "\")
        if (base = "")
            continue
        loop files base "\World of Warcraft*", "D"
            roots[A_LoopFileFullPath] := true
    }
    found := []
    for root in roots {
        loop files root "\_*_", "D" {
            name := A_LoopFileName
            if !(name = "_retail_" || InStr(name, "forever"))
                continue
            hasGame := false
            loop files A_LoopFileFullPath "\Wow*.exe"
                hasGame := true
            if hasGame
                found.Push(A_LoopFileFullPath "\Interface\AddOns")
        }
    }
    return found
}

LoadFolders() {
    saved := IniRead(IniFile, "paths", "folders", "")
    if (saved = "")
        saved := IniRead(IniFile, "paths", "addons", "") ; the old version's single folder
    list := []
    if (saved != "") {
        for p in StrSplit(saved, "|")
            if (Trim(p) != "")
                list.Push(Trim(p))
    }
    ; Folders found now are added (a Forever install made later is picked up by itself).
    for p in FindFolders() {
        known := false
        for q in list
            if (q = p)
                known := true
        if !known
            list.Push(p)
    }
    SaveFolders(list)
    return list
}

SaveFolders(list) {
    s := ""
    for p in list
        s .= (s = "" ? "" : "|") p
    IniWrite(s, IniFile, "paths", "folders")
}

Flavor(folder) {
    return RegExMatch(folder, "i)\\(_[a-z_]+_)\\Interface", &m) ? m[1] : folder
}

; "## Version:" from the installed DMGAssist.toc (the nightly build stamps its version there).
InstalledVersion(folder) {
    toc := folder "\DMGAssist\DMGAssist.toc"
    if !FileExist(toc)
        return "not installed"
    loop read toc {
        if RegExMatch(A_LoopReadLine, "^## Version:\s*(.+)$", &m)
            return Trim(m[1])
    }
    return "unknown"
}

; ---------------------------------------------------------------------------
; Install, start with Windows, uninstall
; ---------------------------------------------------------------------------

TargetPath() {
    return InstallDir "\DMGAssistUpdater" (A_IsCompiled ? ".exe" : ".ahk")
}

CloseOthers() {
    DetectHiddenWindows(true)
    SetTitleMatchMode(2)
    for hwnd in WinGetList("DMGAssistUpdater ahk_class AutoHotkey") {
        if (hwnd != A_ScriptHwnd)
            try WinClose(hwnd)
    }
    Sleep(700)
}

SelfInstall() {
    DirCreate(InstallDir)
    CloseOthers()
    target := TargetPath()
    if A_IsCompiled {
        FileCopy(A_ScriptFullPath, target, true)
        FileInstall("update.ps1", InstallDir "\update.ps1", 1)
        try FileDelete(InstallDir "\DMGAssistUpdater.ahk") ; the old script version
    } else {
        if !FileExist(A_ScriptDir "\update.ps1") {
            MsgBox("update.ps1 must be next to this file to install it:`n" A_ScriptDir, AppName, "Icon!")
            return
        }
        FileCopy(A_ScriptFullPath, target, true)
        FileCopy(A_ScriptDir "\update.ps1", InstallDir "\update.ps1", true)
    }
    SetStartup(true, target)
    if A_IsCompiled
        Run('"' target '"', InstallDir)
    else
        Run('"' A_AhkPath '" "' target '"', InstallDir)
    msg := "Installed. It starts with Windows and keeps DMGAssist up to date every 10 minutes."
    if (Folders.Length = 0)
        msg .= "`nNo World of Warcraft folder was found: right-click the icon > Folders... to add one."
    TrayTip(msg, AppName)
    Sleep(1500)
}

; Start at login through Task Scheduler with the highest rights (no Windows prompt each time).
SetStartup(on, target := "") {
    if (target = "")
        target := TargetPath()
    if on {
        cmdLine := A_IsCompiled ? '\"' target '\"' : '\"' A_AhkPath '\" \"' target '\"'
        RunWait('schtasks.exe /Create /F /TN "' TaskName '" /SC ONLOGON /RL HIGHEST /TR "' cmdLine '"', , "Hide")
    } else {
        RunWait('schtasks.exe /Delete /F /TN "' TaskName '"', , "Hide")
    }
    try FileDelete(OldStartupLink) ; the first version used a Startup-folder shortcut
}

StartupOn() {
    return RunWait('schtasks.exe /Query /TN "' TaskName '"', , "Hide") = 0
}

Uninstall(*) {
    if MsgBox("Remove the DMGAssist updater from this PC?`n`nThe DMGAssist addons stay installed in your AddOns "
        . "folders; delete them there if you want them gone too.", AppName, "YesNo Icon?") != "Yes"
        return
    SetStartup(false)
    try DirDelete(ConfigDir, true)
    ; This program runs from InstallDir: remove it a few seconds after exiting.
    Run(A_ComSpec ' /c timeout /t 3 /nobreak >nul & rmdir /s /q "' InstallDir '"', , "Hide")
    ExitApp
}

; ---------------------------------------------------------------------------
; Tray
; ---------------------------------------------------------------------------

BuildMenu() {
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Check and update now", ManualUpdate)
    tray.Add("Installed versions", ShowVersion)
    tray.Add()
    tray.Add("Automatic updates (every 10 min)", ToggleAuto)
    if AutoUpdate
        tray.Check("Automatic updates (every 10 min)")
    tray.Add("Start with Windows", ToggleStartup)
    if StartupOn()
        tray.Check("Start with Windows")
    tray.Add()
    tray.Add("Folders...", EditFolders)
    tray.Add("Open AddOns folders", OpenFolders)
    tray.Add()
    tray.Add("Uninstall the updater", Uninstall)
    tray.Add("Exit", (*) => ExitApp())
    tray.Default := "Check and update now" ; double-click the icon
}

VersionsText(sep) {
    s := ""
    for f in Folders
        s .= (s = "" ? "" : sep) Flavor(f) ": " InstalledVersion(f)
    return s = "" ? "no WoW folder found" : s
}

RefreshTip() {
    tip := "DMGAssist`n" VersionsText("`n") "`nLast check: " LastCheck
    if !AutoUpdate
        tip .= " (automatic updates off)"
    if (LastError != "")
        tip .= "`n" SubStr(LastError, 1, 50)
    A_IconTip := SubStr(tip, 1, 127) ; Windows limits the tooltip to 127 characters
}

ShowVersion(*) {
    s := ""
    for f in Folders
        s .= InstalledVersion(f) "   " f "`n"
    MsgBox((s = "" ? "No World of Warcraft folder found.`n" : s) "`nLast check: " LastCheck, AppName)
}

OpenFolders(*) {
    for f in Folders {
        DirCreate(f)
        Run('"' f '"')
    }
}

EditFolders(*) {
    global Folders
    s := ""
    for f in Folders
        s .= f "`n"
    r := MsgBox("Installing into:`n`n" (s = "" ? "(none found)`n" : s) "`nAdd another AddOns folder?", AppName,
        "YesNo")
    if (r != "Yes")
        return
    picked := DirSelect("*C:\", 0, "Pick World of Warcraft\<game folder>\Interface\AddOns")
    if (picked = "")
        return
    Folders.Push(picked)
    SaveFolders(Folders)
    RefreshTip()
    RunUpdate(true)
}

; ---------------------------------------------------------------------------
; Updating
; ---------------------------------------------------------------------------

FirstCheck() {
    AutoCheck()
}

AutoCheck() {
    if AutoUpdate
        RunUpdate(false)
}

ManualUpdate(*) {
    RunUpdate(true)
}

; manual: show every result; automatic: only say something when a new build was installed or a new error appears.
RunUpdate(manual) {
    global Busy, LastCheck, LastError
    if Busy
        return
    if (Folders.Length = 0) {
        if manual
            MsgBox("No World of Warcraft folder was found. Use `"Folders...`" to add your AddOns folder.", AppName,
                "Icon!")
        return
    }
    Busy := true
    before := VersionsText(", ")
    if manual
        TrayTip("Checking for a new build...", AppName)
    list := ""
    for f in Folders
        list .= (list = "" ? "" : "|") f
    resultFile := A_Temp "\dmgassist-update-result.txt"
    try FileDelete(resultFile)
    RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' UpdateScript '" -AddOns "' list
        '" -Result "' resultFile '"', , "Hide")
    result := FileExist(resultFile) ? Trim(FileRead(resultFile)) : "ERROR PowerShell did not run."
    LastCheck := FormatTime(, "HH:mm")
    Busy := false
    if SubStr(result, 1, 3) = "OK " {
        LastError := ""
        RefreshTip()
        TrayTip("Now: " VersionsText(", ") "`nIn game: /reload", "DMGAssist updated")
    } else if SubStr(result, 1, 5) = "SAME " {
        LastError := ""
        RefreshTip()
        if manual
            TrayTip("Up to date: " before, AppName)
    } else {
        msg := SubStr(result, 7)
        isNew := msg != LastError
        LastError := msg
        RefreshTip()
        if manual
            MsgBox(msg, "DMGAssist update failed", "Icon!")
        else if isNew
            TrayTip(msg, "DMGAssist update failed")
    }
}

ToggleAuto(*) {
    global AutoUpdate
    AutoUpdate := !AutoUpdate
    IniWrite(AutoUpdate ? "1" : "0", IniFile, "options", "auto")
    if AutoUpdate
        A_TrayMenu.Check("Automatic updates (every 10 min)")
    else
        A_TrayMenu.Uncheck("Automatic updates (every 10 min)")
    RefreshTip()
}

ToggleStartup(*) {
    if StartupOn() {
        SetStartup(false)
        A_TrayMenu.Uncheck("Start with Windows")
    } else {
        SetStartup(true)
        A_TrayMenu.Check("Start with Windows")
    }
}
