# Unlock Alert

**Get a push notification on your phone the moment someone tries to get into your Windows laptop.**

Someone typed a wrong PIN? Opened the lid? Switched it on while you were out? Your phone buzzes within seconds, wherever you are.

```
🚨 FAILED sign-in on MY-LAPTOP
22:19:00, Sat 10 Oct
Reason: wrong PIN
How: Windows Hello PIN
```

- **No account, no app to build, no cloud dashboard.** It's a few PowerShell scripts plus the free [ntfy](https://ntfy.sh) app on your phone.
- **Works at the lock screen.** It runs as SYSTEM, so nobody needs to be signed in.
- **Works from anywhere.** It only needs the laptop and your phone to have internet.
- **Survives low battery.** It keeps working after Windows Energy Saver kicks in.

## What you get notified about

| Event | Phone alert |
|---|---|
| Wrong **PIN** (Windows Hello) | 🚨 urgent, loud |
| Wrong **password** | 🚨 urgent, loud |
| Laptop **switched on** (full boot) | ⚡ high |
| Successful sign-in / unlock | 🔓 low, silent |
| Woke from sleep / lid opened | 👀 low, silent |

The silent ones give you a record without buzzing every time *you* unlock it. You can turn any of them off.

## Requirements

- Windows 10 or 11 (Home works)
- Admin rights, **once**, to install
- A phone (Android or iOS) with the free **ntfy** app

## Install

### 1. Get the files
Either clone it:
```powershell
git clone https://github.com/Shrithu10/unlock-alert.git
cd unlock-alert
```
or click **Code → Download ZIP**, extract it, and open PowerShell in that folder. If you downloaded the ZIP, unblock the files once:
```powershell
Get-ChildItem | Unblock-File
```

### 2. Run the installer as administrator
Right-click **PowerShell**, choose **Run as administrator**, `cd` into the folder, then:
```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```
It prints something like:
```
Watcher installed and started.
Watcher is running (pid 1234).

On your phone: ntfy app -> + -> subscribe to topic:
  unlock-alert-xxxxxxxxxxxxxxxxxxxx   (yours will be different)
```

### 3. Subscribe on your phone
Install **ntfy** ([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy) / [iOS](https://apps.apple.com/app/ntfy/id1625396347)), tap **+**, and enter the topic name that the installer printed. A test notification arrives within a few seconds.

> **Android:** go to Settings → Apps → ntfy → Battery and set it to **Unrestricted**, otherwise the phone may hold notifications back.

### 4. Test it
Press **Win + L**, type a wrong PIN, then unlock normally. You should get a loud **FAILED sign-in** alert, then a quiet **unlocked** one.

## Settings

Edit `C:\ProgramData\UnlockAlert\config.json` (as admin):

```json
{
  "ntfyServer": "https://ntfy.sh",
  "ntfyTopic": "unlock-alert-…",
  "notifyFailed": true,
  "notifyUnlock": true,
  "notifyWake": true,
  "notifyBoot": true
}
```

Changes apply to the next alert; you don't need to reinstall. To use a topic of your own choosing, put it in the repo's `config.json` **before** installing. Re-running the installer always keeps the existing topic.

Every alert is also written to `C:\ProgramData\UnlockAlert\alerts.log`, even if it couldn't be sent.

## Uninstall
As administrator:
```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## How it works

```
 boot / logon / every 5 min ──► Task Scheduler ──► watcher.ps1  (SYSTEM, always running)
                                                      │  listens to:
                                                      │   • Security log        4625 wrong password, 4624 sign-in
                                                      │   • Windows Hello log   7001 wrong PIN
                                                      │   • System log          wake / boot
                                                      ▼
                                                   alert.ps1 ──curl──► ntfy.sh ──► your phone
```

- **`watcher.ps1`** is one long-running process that subscribes to the event logs. A single always-running process is used instead of one scheduled task per event because Windows stops starting event-triggered tasks once Energy Saver turns on; a process that's already running keeps going. Task Scheduler (re)starts it at boot, at logon and every 5 minutes, and it restarts if it crashes.
- **`alert.ps1`** formats the message and sends it with Windows' built-in `curl.exe`. If the network isn't up yet (right after boot or wake), it retries for 3 minutes.
- **`install.ps1`** copies everything to `C:\ProgramData\UnlockAlert` and locks the folder so only admins can change the scripts, because they run as SYSTEM. It also makes sure Windows logs sign-in attempts, and registers the task.

## Privacy

- Nothing leaves your laptop except the notification text itself: time, reason, and username for password attempts.
- ntfy topics are public **to anyone who knows the name**, which is why the installer generates a random 20-character one. Don't share it.
- Want full control? [Self-host ntfy](https://docs.ntfy.sh/install/) and set `ntfyServer` to your own server.

## Limitations

- **No alert while the laptop is fully off or asleep with the lid closed.** Nothing can run then. You'll get the alert as soon as someone switches it on or opens the lid.
- **The laptop needs internet**, normally a saved Wi-Fi it joins at the lock screen. With no connection, the attempt is still logged locally, but the phone alert is lost after 3 minutes of retrying.
- Only tested with PIN and password. Failed face or fingerprint attempts may not be reported; Windows usually just falls back to asking for the PIN, which is reported.

## Troubleshooting

| Problem | Check |
|---|---|
| No notifications at all | Look at `C:\ProgramData\UnlockAlert\alerts.log`. Events listed but `send failed` → the laptop can't reach ntfy.sh. Nothing listed → see next row. |
| Is it running? | `C:\ProgramData\UnlockAlert\watcher-heartbeat.txt` is updated every minute. |
| Wrong PIN not detected | Windows Hello PIN failures go to the *Microsoft-Windows-HelloForBusiness/Operational* log (event 7001), not the Security log; the watcher reads both. |
| Phone gets them late | Turn off battery optimisation for ntfy on your phone. |

## License

MIT
