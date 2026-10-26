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
4. Writes `~/.config/claude-science-watch/status.json`. It also publishes the same JSON to a second ntfy topic, `<ntfyTopic>-status`, when the numbers change and at least every 30 minutes. The watch app reads that topic.

If the daemon is not running, the helper skips that poll.

Do not subscribe to the `-status` topic on your phone. It is a data feed for the watch, not alerts.

## Watch app

`watch/ClaudeScienceWatch.xcodeproj` is a watch-only app (watchOS 11 or later) with a widget extension. Both fetch the latest message from the `-status` topic on ntfy.sh, so the watch does not need to reach your Mac.

- **App:** 5-hour and weekly gauges, reset countdowns, running sessions, and how old the data is (orange when older than 45 minutes).
- **Complications:**
  - *5-hour limit* and *Weekly limit*: circular and corner gauges.
  - *Claude limits*: rectangular (both bars plus the 5-hour reset) and inline (`5h 6% · Wk 23%`).

  Complications refresh about every 15 minutes, which is as often as watchOS allows. Opening the app refreshes them at once. At a reset time the gauge drops to 0 % without waiting for a fetch.

### Build

1. Create `watch/Config/Secrets.xcconfig` (gitignored) with your status topic:

   ```
   CSW_STATUS_TOPIC = csw-xxxxxxxxxxxxxxxxxxxxxxxx-status
   ```

2. Open `watch/ClaudeScienceWatch.xcodeproj` in Xcode.
3. For both targets, under Signing & Capabilities, pick your team. Change the bundle IDs if `com.yakavetsiv.claudesciencewatch` is taken.
4. Pick your Apple Watch as the run destination and run the `ClaudeScienceWatch` scheme.
5. On the watch, long-press the face, tap Edit, go to Complications, and pick *Claude Limits*.

Simulator build from the command line:

```bash
cd watch
xcodebuild -scheme ClaudeScienceWatch -destination 'platform=watchOS Simulator,name=Apple Watch Ultra 4 (49mm)' -derivedDataPath build/DerivedData build
```

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
| `statusTopic` | `<ntfyTopic>-status` | Topic the watch app reads |
| `statusHeartbeatMinutes` | `30` | Publish status at least this often, even when unchanged |
| `ntfyServer` | `https://ntfy.sh` | Use a self-hosted ntfy server here if you prefer |

## Privacy

Pushes go through the public ntfy.sh server. Anyone who knows the topic name can read them, so the topic is a random string; keep it private. Set `includeNames` to `false` if project or session names are sensitive.

## Caveats

The helper uses the Claude Science daemon's internal web API, which is not documented. A Claude Science update can change it and break the helper.
