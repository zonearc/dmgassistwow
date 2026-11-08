; DMGAssistUpdater.ahk: a tray icon that keeps DMGAssist and DMGAssist_Watchdog on the latest nightly build.
; AutoHotkey v2. Keep update.ps1 in the same folder.
;
; Double-click this file once (from wherever you unzipped it):
;   - it installs itself to %LOCALAPPDATA%\DMGAssistUpdater (replacing an older copy, which it closes),
;   - registers itself to start when you log in to Windows (a scheduled task with admin rights, so there is no
;     Windows prompt at every start; the AddOns folder under Program Files needs admin rights to write),
;   - and starts from there. The unzipped copy can be deleted afterwards.
; Then, every 10 minutes, it checks the nightly release and installs it when it is newer than what you have.
; Hover the icon: installed version and the time of the last check.
;
; Right-click the tray icon:
;   Check and update now        (double-click the icon does the same)
;   Installed version
;   Automatic updates           on/off (every 10 minutes)
;   Change AddOns folder...     if WoW is not in the default place
;   Open AddOns folder
;   Start with Windows          on/off
;   Exit

#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

if !A_IsAdmin {
    try Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
    ExitApp
}

AppName := "DMGAssist updater"
InstallDir := EnvGet("LOCALAPPDATA") "\DMGAssistUpdater"
ConfigDir := A_AppData "\DMGAssistUpdater"
DirCreate(ConfigDir)
IniFile := ConfigDir "\settings.ini"
TokenFile := ConfigDir "\token.txt"
DefaultAddOns := "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns"
AddOnsDir := IniRead(IniFile, "paths", "addons", FindAddOns())
AutoUpdate := IniRead(IniFile, "options", "auto", "1") = "1"
TaskName := "DMGAssistUpdater"
OldStartupLink := A_Startup "\DMGAssistUpdater.lnk"
CheckEveryMs := 10 * 60 * 1000
LastCheck := "not yet"
LastError := ""
Busy := false

; ---------------------------------------------------------------------------
; Install: a copy started from anywhere else moves itself into InstallDir and hands over to that copy.
; ---------------------------------------------------------------------------
if (A_ScriptDir != InstallDir) {
    SelfInstall()
    ExitApp
}

UpdateScript := A_ScriptDir "\update.ps1"
BuildMenu()
RefreshTip()
SetTimer(AutoCheck, CheckEveryMs)
; The repository is public: no token. One saved in the private-repo days is removed (an expired one only fails).
try FileDelete(TokenFile)
SetTimer(FirstCheck, -5000) ; first check shortly after start (a separate function: re-setting AutoCheck's
                            ; timer would replace its 10-minute period)
return

; The retail AddOns folder: Blizzard's install path from the registry, else the default location.
FindAddOns() {
    for key in ["HKLM\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
        "HKLM\SOFTWARE\Blizzard Entertainment\World of Warcraft"] {
        try {
            path := RegRead(key, "InstallPath")
            path := RTrim(path, "\")
            if !InStr(path, "_retail_")
                path .= "\_retail_"
            if DirExist(path)
                return path "\Interface\AddOns"
        }
    }
    return DefaultAddOns
}

SelfInstall() {
    if !FileExist(A_ScriptDir "\update.ps1") {
        MsgBox("update.ps1 must be next to this file to install it:`n" A_ScriptDir, AppName, "Icon!")
        return
    }
    DirCreate(InstallDir)
    target := InstallDir "\DMGAssistUpdater.ahk"
    ; Close any other running updater (an installed copy, or an older one started from elsewhere).
    DetectHiddenWindows(true)
    SetTitleMatchMode(2)
    for hwnd in WinGetList("DMGAssistUpdater.ahk ahk_class AutoHotkey") {
        if (hwnd != A_ScriptHwnd)
            try WinClose(hwnd)
    }
    Sleep(500)
    FileCopy(A_ScriptFullPath, target, true)
    FileCopy(A_ScriptDir "\update.ps1", InstallDir "\update.ps1", true)
    SetStartup(true, target)
    Run('"' A_AhkPath '" "' target '"', InstallDir)
    TrayTip("Installed to " InstallDir "`nIt starts with Windows and updates DMGAssist every 10 minutes.",
        AppName)
    Sleep(1500)
}

; Start at login through Task Scheduler with the highest rights (no Windows prompt each time).
SetStartup(on, script := "") {
    if (script = "")
        script := A_ScriptFullPath
    if on {
        RunWait('schtasks.exe /Create /F /TN "' TaskName '" /SC ONLOGON /RL HIGHEST /TR "\"' A_AhkPath '\" \"'
            script '\""', , "Hide")
    } else {
        RunWait('schtasks.exe /Delete /F /TN "' TaskName '"', , "Hide")
    }
    try FileDelete(OldStartupLink) ; the older updater used a Startup-folder shortcut
}

StartupOn() {
    return RunWait('schtasks.exe /Query /TN "' TaskName '"', , "Hide") = 0
}

BuildMenu() {
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Check and update now", ManualUpdate)
    tray.Add("Installed version", ShowVersion)
    tray.Add()
    tray.Add("Automatic updates (every 10 min)", ToggleAuto)
    if AutoUpdate
        tray.Check("Automatic updates (every 10 min)")
    tray.Add("Start with Windows", ToggleStartup)
    if StartupOn()
        tray.Check("Start with Windows")
    tray.Add()
    tray.Add("Change AddOns folder...", SetFolder)
    tray.Add("Open AddOns folder", (*) => Run('"' AddOnsDir '"'))
    tray.Add()
    tray.Add("Exit", (*) => ExitApp())
    tray.Default := "Check and update now" ; double-click the icon
}

; "## Version:" from the installed DMGAssist.toc (the nightly build stamps its version there).
InstalledVersion() {
    toc := AddOnsDir "\DMGAssist\DMGAssist.toc"
    if !FileExist(toc)
        return "not installed"
    loop read toc {
        if RegExMatch(A_LoopReadLine, "^## Version:\s*(.+)$", &m)
            return Trim(m[1])
    }
    return "unknown"
}

RefreshTip() {
    tip := "DMGAssist " InstalledVersion() "`nLast check: " LastCheck
    if !AutoUpdate
        tip .= " (automatic updates off)"
    if (LastError != "")
        tip .= "`n" SubStr(LastError, 1, 60)
    A_IconTip := SubStr(tip, 1, 127) ; Windows limits the tooltip to 127 characters
}

ShowVersion(*) {
    MsgBox("Installed: " InstalledVersion() "`nLast check: " LastCheck "`nFolder: " AddOnsDir, AppName)
}

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
    if !DirExist(AddOnsDir) {
        if manual
            MsgBox("The AddOns folder was not found:`n" AddOnsDir "`n`nUse `"Change AddOns folder...`".", AppName,
                "Icon!")
        return
    }
    Busy := true
    before := InstalledVersion()
    if manual
        TrayTip("Checking for a new build...", AppName)
    resultFile := A_Temp "\dmgassist-update-result.txt"
    try FileDelete(resultFile)
    RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' UpdateScript '" -AddOns "' AddOnsDir
        '" -Result "' resultFile '" -Installed "' before '"', , "Hide")
    result := FileExist(resultFile) ? Trim(FileRead(resultFile)) : "ERROR PowerShell did not run."
    LastCheck := FormatTime(, "HH:mm")
    Busy := false
    if SubStr(result, 1, 3) = "OK " {
        LastError := ""
        RefreshTip()
        TrayTip("Now " InstalledVersion() " (was " before ").`nIn game: /reload", "DMGAssist updated")
    } else if SubStr(result, 1, 5) = "SAME " {
        LastError := ""
        RefreshTip()
        if manual
            TrayTip("You have the latest build: " before, AppName)
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

SetFolder(*) {
    global AddOnsDir
    picked := DirSelect("*" AddOnsDir, 0, "Pick World of Warcraft\_retail_\Interface\AddOns")
    if picked = ""
        return
    AddOnsDir := picked
    IniWrite(picked, IniFile, "paths", "addons")
    RefreshTip()
}
