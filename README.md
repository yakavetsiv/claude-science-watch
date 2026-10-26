# Claude Science Watch

Shows your Claude Science plan limits and session activity on your phone and Apple Watch.

## How it works

`helper/csw.js` runs on the Mac. Every 2 minutes it:

1. Signs in to the local Claude Science daemon (`localhost:8765`). It uses the same single-use link that `claude-science url` prints, and signs in again when the session expires.
2. Reads `/api/usage` (5-hour and weekly limits) and `/api/projects/dashboard` (sessions that need input or have finished).
3. Sends a push through [ntfy](https://ntfy.sh) when:
   - a limit crosses 50, 75, 90 or 100 %
   - a limit that was notified resets
   - a session needs your input
   - a session finishes
4. Writes `~/.config/claude-science-watch/status.json` for the watchOS app (not built yet).

If the daemon is not running, the helper skips that poll.

## Setup

1. Install the **ntfy** app on your iPhone. Subscribe to the topic in `~/.config/claude-science-watch/config.json` (`ntfyTopic`), on server `https://ntfy.sh`.
2. On the iPhone, allow ntfy notifications. In the Watch app, under Notifications, mirror ntfy to the watch.
3. Install the background agent:

   ```bash
   ~/Documents/claude-science-watch/helper/install.sh
   ```

   Log: `~/Library/Logs/claude-science-watch.log`. Uninstall with `install.sh --uninstall`.

## Commands

```bash
node helper/csw.js --status   # print current usage, send nothing
node helper/csw.js --test     # send a test push
node helper/csw.js --once     # one poll with notifications
```

## Config

`~/.config/claude-science-watch/config.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `pollSeconds` | `120` | Time between polls |
| `thresholds` | `[50, 75, 90, 100]` | Percent levels that trigger a push |
| `notifyCompleted` | `true` | Push when a session finishes |
| `notifyNeedsInput` | `true` | Push when a session needs input |
| `includeNames` | `true` | Put project and session names in pushes. Set `false` to keep titles off ntfy.sh |
| `ntfyServer` | `https://ntfy.sh` | Use a self-hosted ntfy server here if you prefer |

## Privacy

Pushes go through the public ntfy.sh server. Anyone who knows the topic name can read them, so the topic is a random string; keep it private. Set `includeNames` to `false` if project or session names are sensitive.

## Caveats

The helper uses the Claude Science daemon's internal web API, which is not documented. A Claude Science update can change it and break the helper.
