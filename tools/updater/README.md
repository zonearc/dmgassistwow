# DMGAssist updater (Windows)

A tray icon that keeps DMGAssist and DMGAssist_Watchdog on the latest nightly build, in every World of Warcraft
install on the PC it supports: **retail (`_retail_`) and WoW Forever**. It checks every 10 minutes and installs a
newer build by itself. Hover the icon to see the version in each folder and the time of the last check.

## Install (once)
1. Download **DMGAssistUpdater.exe** from the [nightly release](https://github.com/zonearc/dmgassistwow/releases/tag/nightly)
   (or the latest weekly release) and run it. Nothing else is needed.
   - Windows may say "Windows protected your PC" (the program isn't code-signed): **More info → Run anyway**.
   - It asks for admin rights once: AddOns folders under Program Files need them.
2. That's it. It:
   - installs itself to `%LOCALAPPDATA%\DMGAssistUpdater`, replacing and closing an older copy (including the old
     AutoHotkey script version),
   - starts when you log in to Windows (a scheduled task with admin rights, so there is no prompt each time),
   - finds your WoW folders (Blizzard's registry entry and the usual install locations): `_retail_` and any game
     folder whose name contains "forever"; a Forever install added later is picked up on the next start,
   - installs DMGAssist into each of them and keeps them up to date.

No GitHub account or token is needed.

## Use
Nothing to do. When a new build is installed, a notification says so; in game type `/reload`.
Right-click the icon for **Check and update now** (double-click does the same), **Installed versions**,
**Automatic updates** on/off, **Start with Windows** on/off, **Folders...** (add an AddOns folder it didn't find),
**Open AddOns folders**, and **Uninstall the updater**.

## Uninstall
Right-click → **Uninstall the updater**. For the old AutoHotkey script version (before the .exe), run
`Uninstall-DMGAssistUpdater.ahk` from `DMGAssist_Updater.zip` (needs AutoHotkey v2), or simply run the new
DMGAssistUpdater.exe, which replaces the old version. The addons themselves stay in your AddOns folders.

## What it does
`update.ps1` asks GitHub for the `nightly` release. Folders already on that version are left alone. Otherwise it
downloads `DMGAssist.zip` and `DMGAssist_Watchdog.zip`, checks each contains its addon folder, and only then
replaces the two folders in each AddOns folder that needs it. Nothing else in AddOns is touched. If anything fails,
the installed addons are left as they were; an automatic check reports a new error once, a manual check always.

## Running from source
`DMGAssistUpdater.ahk` (AutoHotkey v2) with `update.ps1` next to it works the same way; the nightly build compiles
it into the .exe.
