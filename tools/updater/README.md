# DMGAssist updater (Windows)

A tray icon that keeps DMGAssist and DMGAssist_Watchdog on the latest nightly build, in every World of Warcraft
install on the PC it supports: **retail (`_retail_`) and WoW Forever**. It checks every 10 minutes and installs a
newer build by itself. Hover the icon to see the version in each folder and the time of the last check.

## Install (once)
1. Install [AutoHotkey v2](https://www.autohotkey.com/), download **DMGAssist_Updater.zip** from the
   [nightly release](https://github.com/zonearc/dmgassistwow/releases/tag/nightly), unzip it anywhere and double-click
   **DMGAssistUpdater.ahk**. It asks for admin rights once: AddOns folders under Program Files need them.
   (There is no compiled .exe: Microsoft Defender flags unsigned compiled AutoHotkey programs that do this kind of
   work, a false positive we can't avoid without paid code signing.)
2. That's it. It:
   - installs itself to `%LOCALAPPDATA%\DMGAssistUpdater`, replacing and closing an older copy (including the old
     AutoHotkey script version),
   - starts when you log in to Windows (a scheduled task with admin rights, so there is no prompt each time),
   - finds your WoW folders (Blizzard's registry entry and the usual install locations): `_retail_` and any game
     folder whose name contains "forever"; a Forever install added later is picked up on the next start,
   - installs DMGAssist into each of them and keeps them up to date.

No GitHub account or key is needed while the repository is public. If it is private, the updater needs a
read-only GitHub key once:

1. github.com → your picture → **Settings** → **Developer settings** → **Personal access tokens** →
   **Fine-grained tokens** → **Generate new token**.
2. Name `DMGAssist updater`, expiration up to 1 year, **Repository access: Only select repositories** →
   `zonearc/dmgassistwow`, **Permissions → Contents: Read-only**. Generate and copy it.
   (Korbin: the repository owner makes the key and gives it to you, or adds you as a collaborator.)
3. Right-click the updater's tray icon → **GitHub key...** → paste → OK.

The key is saved in `github-token.txt` in the updater's folder and is only ever sent to GitHub.

## Use
Nothing to do. When a new build is installed, a notification says so; in game type `/reload`.
Right-click the icon for **Check and update now** (double-click does the same), **Installed versions**,
**Automatic updates** on/off, **Start with Windows** on/off, **Folders...** (add an AddOns folder it didn't find),
**Open AddOns folders**, and **Uninstall the updater**.

## Uninstall
Right-click → **Uninstall the updater**, or run `Uninstall-DMGAssistUpdater.ahk` from `DMGAssist_Updater.zip`
(it also removes older versions of the updater). The addons themselves stay in your AddOns folders.

## What it does
`update.ps1` asks GitHub for the `nightly` release. Folders already on that version are left alone. Otherwise it
downloads `DMGAssist.zip` (both addons), checks it contains both addon folders, and only then
replaces the two folders in each AddOns folder that needs it. Nothing else in AddOns is touched. If anything fails,
the installed addons are left as they were; an automatic check reports a new error once, a manual check always.

