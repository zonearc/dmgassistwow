; Uninstall-DMGAssistUpdater.ahk: removes the DMGAssist tray updater (the old AutoHotkey script versions and the
; new DMGAssistUpdater.exe): stops it, removes its start-with-Windows entries, its installed copy and its settings
; (including a saved GitHub token). The DMGAssist addons themselves stay in your AddOns folders.
; AutoHotkey v2. Not needed before installing DMGAssistUpdater.exe, which replaces the old version by itself.

#Requires AutoHotkey v2.0

if !A_IsAdmin {
    try Run('*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"')
    ExitApp
}

if MsgBox("Remove the DMGAssist updater from this PC?`n`nThe DMGAssist addons stay installed.",
    "Uninstall DMGAssist updater", "YesNo Icon?") != "Yes"
    ExitApp

; 1. Stop every running copy (script or exe).
DetectHiddenWindows(true)
SetTitleMatchMode(2)
for hwnd in WinGetList("DMGAssistUpdater ahk_class AutoHotkey") {
    if (hwnd != A_ScriptHwnd)
        try WinClose(hwnd)
}
try ProcessClose("DMGAssistUpdater.exe")
Sleep(1000)

; 2. Start-with-Windows entries: the scheduled task and the first version's Startup-folder shortcut.
RunWait('schtasks.exe /Delete /F /TN "DMGAssistUpdater"', , "Hide")
try FileDelete(A_Startup "\DMGAssistUpdater.lnk")

; 3. Installed copy and settings.
removed := ""
for dir in [EnvGet("LOCALAPPDATA") "\DMGAssistUpdater", A_AppData "\DMGAssistUpdater"] {
    if DirExist(dir) {
        try {
            DirDelete(dir, true)
            removed .= "`n" dir
        }
    }
}

MsgBox("The DMGAssist updater is removed." (removed != "" ? "`n`nDeleted:" removed : "")
    . "`n`nIf you unzipped the old updater somewhere yourself, you can delete that folder too.",
    "Uninstall DMGAssist updater")
