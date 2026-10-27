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
4. Writes `~/.config/claude-science-watch/status.json` and publishes it for the watch app: to your relay Worker if one is set up (on every change and every 10 minutes), otherwise to a second ntfy topic, `<ntfyTopic>-status` (throttled, see below).

If the daemon is not running, the helper skips that poll.

"Session finished" fires when a session that was running stops without asking for input (most sessions go idle rather than "completed"), or when one is marked completed.

### Approving permissions from the watch

When a session asks for permission (for example to run Python or bash), the helper:

1. Pushes "Claude Science: Run python?" with the project, session and first line of code.
2. Adds the request, with a random one-time code, to the status feed. The watch app shows it under **Needs permission** with **Allow** and **Deny**.
3. Picks up answers from the relay (checked every 3 seconds) and from `<ntfyTopic>-reply` (used by the buttons on the ntfy alert). When an answer arrives, the helper checks the code (single use, expires after 1 hour) and sends `allow_once`, `allow` for the conversation, or `deny` to `/api/frames/<id>/resolve-input`.

**Allow once** applies to that one request; **Allow for chat** allows the same tool for the rest of the conversation. Questions that need a typed answer (`ask`) get the plain "needs your input" push instead. Anyone who knows the status or reply topic can answer requests, so keep both private. Set `approvalsEnabled` to `false` to turn this off.

Do not subscribe to the `-status` topic on your phone. It is a data feed for the watch, not alerts.

## Relay (recommended)

ntfy.sh allows 250 messages a day per IP address. Status updates and answers can use that up, and then the watch stops updating until the next day. `relay/` is a small Cloudflare Worker that carries status and answers instead, so ntfy only carries alerts. It fits in Cloudflare's free plan (100,000 requests a day; the helper uses about 30,000).

1. Create a free Cloudflare account, then:

   ```bash
   cd relay
   npx wrangler login
   npx wrangler deploy
   openssl rand -hex 24 | tee /dev/stderr | npx wrangler secret put RELAY_TOKEN
   ```

2. Put the Worker URL and the token in `~/.config/claude-science-watch/config.json` as `relayUrl` and `relayToken`, and restart the helper.
3. Add both to `watch/Config/Secrets.xcconfig` (see Build below) and rebuild the watch app.

The app's **Relay** section, at the bottom, shows how many requests the Worker has handled today against the 100,000 limit. Cloudflare resets the count at midnight UTC.

Every request needs the token. Anyone with it can read the status and answer permission requests, so keep it private.

## Watch app

`watch/ClaudeScienceWatch.xcodeproj` is a watch-only app (watchOS 11 or later) with a widget extension. Both fetch the latest status from the relay (or the `-status` topic on ntfy.sh without one), so the watch does not need to reach your Mac.

- **App:** 5-hour and weekly gauges, reset countdowns, running sessions, and how old the data is (orange when older than 45 minutes).
- **Expiry reminders:** with a free (Personal Team) account the install expires after 7 days. The app reads the expiry date from its provisioning profile, shows it at the bottom, and schedules watch notifications 24 hours and 1 hour before it. The *Expiry reminders* toggle turns them off. Reminders are rescheduled each time the app opens, so open it once after every redeploy.
- **Complications:**
  - *Limit rings*: two concentric rings. The outer ring is the 5-hour limit, the inner (cyan) ring is the weekly limit, and the middle shows the 5-hour percentage only. Circular slots show just the rings; rectangular slots add the reset times (`5h 8:00`, `Wk Thu`).
  - *5-hour limit* and *Weekly limit*: circular and corner gauges.
  - *Claude limits*: rectangular (both bars plus the 5-hour reset) and inline (`5h 6% · Wk 23%`).

  Complications refresh about every 15 minutes, which is as often as watchOS allows. Opening the app refreshes them at once. At a reset time the gauge drops to 0 % without waiting for a fetch.

### Build

1. Create `watch/Config/Secrets.xcconfig` (gitignored) with your status topic:

   ```
   CSW_STATUS_TOPIC = csw-xxxxxxxxxxxxxxxxxxxxxxxx-status
   CSW_RELAY_URL = https:/$()/claude-science-relay.<you>.workers.dev
   CSW_RELAY_TOKEN = <relayToken>
   ```

   The relay lines are optional. `$()` keeps xcconfig from reading `//` as a comment.

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
| `pollSeconds` | `30` | Time between polls |
| `thresholds` | `[50, 75, 90, 100]` | Percent levels that trigger a push |
| `notifyCompleted` | `true` | Push when a session finishes |
| `notifyNeedsInput` | `true` | Push when a session needs input |
| `includeNames` | `true` | Put project and session names in pushes. Set `false` to keep titles off ntfy.sh |
| `statusTopic` | `<ntfyTopic>-status` | Topic the watch app reads |
| `statusHeartbeatMinutes` | `60` | Without a relay, publish status to ntfy at least this often, even when unchanged |
| `replyTopic` | `<ntfyTopic>-reply` | Topic the watch posts Allow/Deny answers to |
| `relayUrl` | none | Relay Worker URL; status and answers go through it |
| `relayToken` | none | Token the relay checks (its `RELAY_TOKEN` secret) |
| `approvalsEnabled` | `true` | Relay permission requests to the watch |
| `ntfyServer` | `https://ntfy.sh` | Use a self-hosted ntfy server here if you prefer |

## Privacy

Alerts go through the public ntfy.sh server. With a relay, status and answers go through your own Worker and need its token. Anyone who knows the topic name can read them, so the topic is a random string; keep it private. Set `includeNames` to `false` if project or session names are sensitive.

## Caveats

The helper uses the Claude Science daemon's internal web API, which is not documented. A Claude Science update can change it and break the helper.
