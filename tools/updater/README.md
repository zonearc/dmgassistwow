# DMGAssist tray updater (Windows)

A tray icon that keeps DMGAssist and DMGAssist_Watchdog on the latest nightly build. It checks every
10 minutes and installs a newer build by itself. Hover the icon to see the installed version and the time of the
last check.

## Setup (once)
1. Install [AutoHotkey v2](https://www.autohotkey.com/).
2. Download `DMGAssist_Updater.zip` from the nightly release, unzip it anywhere, and double-click
   `DMGAssistUpdater.ahk`. Windows asks for admin rights once: the default AddOns folder is under Program Files.
   It then:
   - installs itself to `%LOCALAPPDATA%\DMGAssistUpdater` (a newer copy replaces the older one and closes it),
   - registers itself to start when you log in, as a scheduled task with admin rights, so there is no prompt at
     every start,
   - and starts from there. You can delete the unzipped folder.
3. Make a GitHub token (the repository is private): GitHub → Settings → Developer settings → Personal access
   tokens → **Fine-grained tokens** → Generate. Repository access: **Only select repositories** →
   `zonearc/dmgassistwow`. Permissions: **Contents: Read-only**. Copy the token.
4. Right-click the tray icon → **Set GitHub token...** → paste. It is stored only on this PC
   (`%APPDATA%\DMGAssistUpdater\token.txt`). It checks right away.

To install a newer updater later, double-click the new `DMGAssistUpdater.ahk` the same way.

## Use
Nothing to do. When a new build is installed, a notification says so; in game type `/reload`.
Right-click for **Check and update now** (double-clicking the icon does the same), **Automatic updates** on/off,
**Start with Windows** on/off, **Change AddOns folder...** (the default is
`C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns`) and **Open AddOns folder**.

## What it does
`update.ps1` asks GitHub for the `nightly` release. If its version is the one installed, it stops there.
Otherwise it downloads `DMGAssist.zip` and `DMGAssist_Watchdog.zip`, checks each contains its addon folder, and
only then replaces the two folders. Nothing else in AddOns is touched. If anything fails, the installed addons are
left as they were; an automatic check reports a new error once, a manual check always.

To remove it: right-click → turn off **Start with Windows** → **Exit**, then delete
`%LOCALAPPDATA%\DMGAssistUpdater` and `%APPDATA%\DMGAssistUpdater`.
