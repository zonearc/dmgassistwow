; DMGAssistUpdater.ahk: a tray icon that installs the latest nightly build of DMGAssist and DMGAssist_Watchdog.
; AutoHotkey v2. Keep update.ps1 in the same folder.
;
; Right-click the tray icon:
;   Update DMGAssist now        download the latest nightly build and install it (double-click does the same)
;   Installed version           what is in your AddOns folder now
;   Set GitHub token...         one-time setup (the repository is private): a read-only token, kept on this PC
;   Change AddOns folder...     if WoW is not in the default place
;   Open AddOns folder
;   Run at Windows startup      on/off
;   Exit
;
; It runs as administrator (one Windows prompt when it starts) because the default AddOns folder is under
; Program Files, which needs admin rights to write.

#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

if !A_IsAdmin {
    try Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
    ExitApp
}

ConfigDir := A_AppData "\DMGAssistUpdater"
DirCreate(ConfigDir)
IniFile := ConfigDir "\settings.ini"
TokenFile := ConfigDir "\token.txt"
DefaultAddOns := "C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns"
AddOnsDir := IniRead(IniFile, "paths", "addons", DefaultAddOns)
UpdateScript := A_ScriptDir "\update.ps1"
StartupLink := A_Startup "\DMGAssistUpdater.lnk"

BuildMenu()
RefreshTip()
if !FileExist(TokenFile)
    TrayTip("Right-click this icon and choose `"Set GitHub token...`" once, then `"Update DMGAssist now`".",
        "DMGAssist updater")
return

BuildMenu() {
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Update DMGAssist now", DoUpdate)
    tray.Add("Installed version", ShowVersion)
    tray.Add()
    tray.Add("Set GitHub token...", SetToken)
    tray.Add("Change AddOns folder...", SetFolder)
    tray.Add("Open AddOns folder", (*) => Run('"' AddOnsDir '"'))
    tray.Add("Run at Windows startup", ToggleStartup)
    if FileExist(StartupLink)
        tray.Check("Run at Windows startup")
    tray.Add()
    tray.Add("Exit", (*) => ExitApp())
    tray.Default := "Update DMGAssist now" ; double-click the icon to update
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
    A_IconTip := "DMGAssist updater`nInstalled: " InstalledVersion()
}

ShowVersion(*) {
    MsgBox("Installed: " InstalledVersion() "`nFolder: " AddOnsDir, "DMGAssist updater")
}

DoUpdate(*) {
    if !FileExist(TokenFile) {
        SetToken()
        if !FileExist(TokenFile)
            return
    }
    if !FileExist(UpdateScript) {
        MsgBox("update.ps1 must be in the same folder as this script:`n" A_ScriptDir, "DMGAssist updater", "Icon!")
        return
    }
    if !DirExist(AddOnsDir) {
        MsgBox("The AddOns folder was not found:`n" AddOnsDir "`n`nUse `"Change AddOns folder...`".",
            "DMGAssist updater", "Icon!")
        return
    }
    before := InstalledVersion()
    TrayTip("Downloading the latest build...", "DMGAssist updater")
    resultFile := A_Temp "\dmgassist-update-result.txt"
    try FileDelete(resultFile)
    RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' UpdateScript '" -AddOns "' AddOnsDir
        '" -Result "' resultFile '"', , "Hide")
    result := FileExist(resultFile) ? Trim(FileRead(resultFile)) : "ERROR PowerShell did not run."
    RefreshTip()
    if SubStr(result, 1, 3) = "OK " {
        TrayTip(SubStr(result, 4) "`nWas: " before "`nIn game: /reload", "DMGAssist updated")
    } else {
        MsgBox(SubStr(result, 7), "DMGAssist update failed", "Icon!")
    }
}

SetToken(*) {
    ib := InputBox("Paste a GitHub token with read access to zonearc/dmgassistwow.`n"
        . "(GitHub > Settings > Developer settings > Fine-grained tokens: only that repository, "
        . "Contents: Read-only.)`n`nKept only on this PC, in " TokenFile,
        "DMGAssist updater", "Password w520 h190")
    if ib.Result != "OK" || Trim(ib.Value) = ""
        return
    try FileDelete(TokenFile)
    FileAppend(Trim(ib.Value), TokenFile)
    TrayTip("Token saved. Right-click > Update DMGAssist now.", "DMGAssist updater")
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

ToggleStartup(*) {
    if FileExist(StartupLink) {
        FileDelete(StartupLink)
        A_TrayMenu.Uncheck("Run at Windows startup")
    } else {
        FileCreateShortcut(A_ScriptFullPath, StartupLink, A_ScriptDir)
        A_TrayMenu.Check("Run at Windows startup")
    }
}
