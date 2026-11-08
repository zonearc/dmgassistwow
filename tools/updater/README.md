# DMGAssist tray updater (Windows)

A tray icon: right-click → **Update DMGAssist now** downloads the latest nightly build of DMGAssist and
DMGAssist_Watchdog and installs them into your AddOns folder. Double-clicking the icon does the same.

## One-time setup
1. Install [AutoHotkey v2](https://www.autohotkey.com/).
2. Unzip this folder anywhere (keep `DMGAssistUpdater.ahk` and `update.ps1` together) and double-click
   `DMGAssistUpdater.ahk`. Windows asks for admin rights: the default AddOns folder is under Program Files.
3. Make a GitHub token (the repository is private): GitHub → Settings → Developer settings → Personal access
   tokens → **Fine-grained tokens** → Generate. Repository access: **Only select repositories** →
   `zonearc/dmgassistwow`. Permissions: **Contents: Read-only**. Copy the token.
4. Right-click the tray icon → **Set GitHub token...** → paste. It is stored only on this PC
   (`%APPDATA%\DMGAssistUpdater\token.txt`).
5. Optional: right-click → **Run at Windows startup**.

## Use
Right-click → **Update DMGAssist now**. A notification shows the new version; in game type `/reload`.
Hover the icon to see the installed version.

The default folder is `C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns`; use
**Change AddOns folder...** if yours differs.

## What it does
`update.ps1` asks GitHub for the `nightly` release, downloads `DMGAssist.zip` and `DMGAssist_Watchdog.zip`,
checks each contains its addon folder, and only then replaces the two folders. Nothing else in AddOns is
touched. If anything fails, a message says why and the installed addons are left as they were.
