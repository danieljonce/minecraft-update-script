# Minecraft Update Script 1.0.0

Keeps a **Paper/Spigot** Minecraft server's cross-version and Bedrock plugins up to date, and tells you which Paper version is actually safe to run.

## Get it

```bash
curl -fsSL -o update-mc-plugins.sh https://raw.githubusercontent.com/danieljonce/minecraft-update-script/main/update-mc-plugins.sh && chmod +x update-mc-plugins.sh
```

Re-run the same command any time to pull the latest version. (See [Install](#install) for putting it somewhere permanent.)

## Usage

```
update-mc-plugins.sh <server-dir> [options]
update-mc-plugins.sh --plugins-dir <path> [options]
```

`<server-dir>` is a **positional** argument — the folder containing your server jar and `plugins/`. There is no `--server-dir` flag.

Quote the path if it contains spaces: `update-mc-plugins.sh "/srv/my server"`

## Requirements

- Linux (or anything with bash)
- `bash`, `curl`, `jq`, `sha256sum` (coreutils), `flock` (util-linux)

```bash
# Debian / Ubuntu
sudo apt install jq curl coreutils util-linux
```

Run it as **the user that owns the server files** (the script checks the plugins folder is writable).

---

## Quick start

Always dry-run first. It resolves everything, prints the full plan, and changes nothing:

```bash
update-mc-plugins.sh /path/to/server --dry-run
```

Then run it for real:

```bash
update-mc-plugins.sh /path/to/server
```

**Stop your server first.** Swapping jars under a running server does nothing until the next restart, and can leave a plugin's on-disk jar out of sync with the running code.

The script checks whether a java process is using that directory and reports it every run:

```
server state: stopped (no java process using this directory)
```

If the server **is** running and this isn't a dry-run, it asks before touching anything:

```
WARNING: Server appears to be RUNNING (pid 4127).
WARNING: Jars swapped now will NOT load until you restart, and a plugin's
         on-disk jar may not match the running code.
Continue anyway? [y/N]
```

Pressing Enter (the default) aborts safely. Pass `-y`/`--yes` to skip the question.

**From cron there is no prompt** — it never blocks waiting for input that will never come. It warns, proceeds, and reminds you to restart. If you want cron to leave a running server strictly alone, bracket the job with a stop/start (see [Daily cron job](#daily-cron-job)).

---

## What

It manages five plugins, each fetched from its project's **official** channel:

| Plugin | Purpose | Source |
|---|---|---|
| **ViaVersion** | Lets *newer* clients join an older server | Hangar (`hangar.papermc.io`) |
| **ViaBackwards** | Lets *older* clients join a newer server | Hangar |
| **ViaRewind** | Extends Via support back to 1.7/1.8 clients | Hangar |
| **Geyser-Spigot** | Lets Bedrock players join a Java server | GeyserMC (`download.geysermc.org`) |
| **Floodgate-Spigot** | Lets Bedrock players join without a Java account | GeyserMC |

It works with **any** Minecraft install that has a `plugins/` folder — a plain directory, systemd, Docker, Crafty, Pterodactyl, AMP, whatever. It only touches files. **It never starts or stops your server.**

---

## Why

Chasing the newest Paper release breaks things. Geyser only ever supports the newest Minecraft version *it* has caught up to, and it usually lags a few days behind a Minecraft release. Update Paper on day one and Bedrock support silently dies.

This script inverts the problem:

1. It asks every plugin what the **highest Minecraft version** it supports is.
2. The **ceiling** is the **lowest** of those numbers — the lowest common denominator, so no plugin gets left behind. (Usually Geyser is the laggard, but nothing assumes that; whichever plugin is furthest behind sets the limit.)
3. It then reports two **independent** facts about your Paper install:
   - **Compatibility** — is your Paper *above* the ceiling? That's the only thing that breaks plugins.
   - **Stable build** — is a newer *stable* Paper build available at or below the ceiling?

Running a Paper newer than the newest **stable** build is fine, as long as it's still within the ceiling — it just means PaperMC hasn't promoted a stable build for it yet.

Then **ViaVersion** does the rest: players whose clients auto-update to a version newer than your server can still connect. That's what lets you sit on a stable, mature Paper version instead of chasing releases.

---

## How

The script is a single self-contained file. "Installing" it just means putting it somewhere permanent and making it executable — there's nothing to compile and no dependencies to vendor.

```bash
# 1. create a place for it (only needed once)
sudo mkdir -p /opt/scripts

# 2. download it there and make it executable
sudo curl -fsSL -o /opt/scripts/update-mc-plugins.sh \
  https://raw.githubusercontent.com/danieljonce/minecraft-update-script/main/update-mc-plugins.sh
sudo chmod +x /opt/scripts/update-mc-plugins.sh
```

Re-run those two commands to update to the latest version. The `-f` flag matters: without it, a failed download writes GitHub's 404 page into your script file instead of erroring out.

> **Don't put the download in cron.** Auto-pulling and running a script unattended means any bad commit executes on your server. Pull when you intend to, then `--dry-run` before the real run.

If you already have the file locally, `install` copies it and sets permissions in one step:

```bash
sudo install -m 755 update-mc-plugins.sh /opt/scripts/update-mc-plugins.sh
```

`-m 755` means *owner can read/write/execute, everyone else can read/execute* — i.e. it lands ready to run. It's equivalent to a `cp` followed by `chmod 755`.

`/opt/scripts` is just a convention for locally-installed scripts — nothing depends on it. Any stable path works, as long as **cron can reach it** (which is why a home directory like `~/update-mc-plugins.sh` is a poor choice for a scheduled job: `~` isn't reliably defined in cron's environment).

Verify it's in place:

```bash
/opt/scripts/update-mc-plugins.sh --help
```

If you'd rather not use `sudo`, keep it anywhere you own and call it by absolute path:

```bash
chmod +x ~/update-mc-plugins.sh
/home/youruser/update-mc-plugins.sh /path/to/server --dry-run
```

---

### Options

| Option | Description |
|---|---|
| `--plugins-dir <path>` | Plugins folder if it isn't `<server-dir>/plugins`. Passed alone, the server dir is inferred as its parent. |
| `--channel <release\|beta\|any>` | Build channel. Default `release` = **stable only**. `beta` tracks Hangar's Snapshot channel / GeyserMC's experimental builds. Applied to all plugins, so the Via trio always stays on one channel together. |
| `--update-paper` | Actually upgrade Paper to the newest stable build at/below the ceiling. Default is to only *report* that an update exists. |
| `--allow-downgrade` | Permit `--update-paper` to roll Paper **down** when your install is above the ceiling. Off by default (world-compat risk). |
| `--server-jar <name>` | Paper jar filename. Auto-detected when unambiguous. |
| `--no-paper` | Skip the Paper check entirely; just manage plugins. |
| `--skip <a,b>` | Don't manage these plugins, e.g. `--skip ViaRewind,Floodgate`. |
| `--keep-backups <n>` | Keep only the newest *n* backup sets. Default `10`. |
| `--dry-run` | Print the full plan, change nothing. |
| `-y`, `--yes` | Skip the "server is running — continue?" confirmation. Only relevant on a terminal; cron never prompts. |
| `--viaversion-url <url>` | Override a plugin's download URL, bypassing its API. Also `--viabackwards-url`, `--viarewind-url`, `--geyser-url`, `--floodgate-url`. |
| `-h`, `--help` | Full help. |

### What it does on a real run

- Installs any missing plugin; updates any whose checksum differs from the latest build.
- **Does nothing** if everything is already current — no downloads, no file churn. Safe to run daily.
- Removes **duplicate jars** of the same plugin (e.g. both `ViaVersion.jar` and `ViaVersion-5.10.0.jar`), which otherwise cause Paper's `Ambiguous plugin name` error.
- Backs up every replaced/removed jar to `plugins/_backups/<timestamp>/` before touching it.
- Verifies every download against its published SHA-256 before installing.
- Uses a lock file, so overlapping cron runs can't collide.

---

## Directory layouts

The script needs the folder that contains `plugins/`. Here's where that lives in common setups.

### 1. Generic / self-hosted install

The plain case — a directory with the server jar in it:

```
/srv/minecraft/survival/
├── paper.jar
├── server.properties
├── version_history.json     <- Paper writes this; used for the Paper check
├── world/
└── plugins/                 <- the script writes here
    ├── ViaVersion.jar
    ├── ViaBackwards.jar
    ├── ViaRewind.jar
    ├── Geyser-Spigot.jar
    └── floodgate-spigot.jar
```

```bash
/opt/scripts/update-mc-plugins.sh /srv/minecraft/survival --dry-run
```

### 2. Crafty Controller

Crafty stores each server in a folder named after its **server UUID**. On a native install the root is typically:

```
/var/opt/minecraft/crafty/crafty-4/servers/<server-uuid>/
├── paper.jar
├── version_history.json
└── plugins/
```

Get the UUID from the URL when you open the server in the Crafty web UI, or find the folder directly:

```bash
# find the server dir (look for the one containing plugins/)
sudo find / -type d -name plugins -path '*crafty*' 2>/dev/null
```

```bash
/opt/scripts/update-mc-plugins.sh \
  /var/opt/minecraft/crafty/crafty-4/servers/e3acb514-acbb-407e-b368-bd25e9f269cc --dry-run
```

> Crafty paths vary between the installer, Docker, and older versions. Always confirm with the `find` above rather than assuming.

### 3. Pterodactyl

Pterodactyl (Wings 1.x) stores each server's files in a volume named after the **server UUID**:

```
/var/lib/pterodactyl/volumes/<server-uuid>/
├── server.jar
├── version_history.json
└── plugins/
```

```bash
# list server volumes
sudo ls /var/lib/pterodactyl/volumes/
```

```bash
sudo /opt/scripts/update-mc-plugins.sh \
  /var/lib/pterodactyl/volumes/1a2b3c4d-5e6f-7890-abcd-ef1234567890 --dry-run
```

> If you upgraded from Pterodactyl 0.7, files may still be under `/srv/daemon-data/`. Check `data:` in `/etc/pterodactyl/config.yml` for the real path. Because servers run in Docker containers, run the script on the **host** (as root or the `pterodactyl` user), and restart the server from the panel afterwards.

### 4. AMP (CubeCoders)

AMP keeps everything under the `amp` user's home, in a per-**instance** folder. For the Minecraft module the server files sit in a `Minecraft/` subfolder:

```
/home/amp/.ampdata/instances/<InstanceName>/Minecraft/
├── paper.jar
├── version_history.json
└── plugins/
```

```bash
# find it (AMP hides the datastore behind a dot-folder)
sudo find /home/amp/.ampdata/instances -maxdepth 3 -type d -name plugins
```

```bash
sudo -u amp /opt/scripts/update-mc-plugins.sh \
  "/home/amp/.ampdata/instances/MinecraftSurvival/Minecraft" --dry-run
```

> Run it **as the `amp` user** (`sudo -u amp`), or AMP's files end up owned by root and the panel breaks. If you moved your datastore, the path differs — use the `find` above.

### Can't find it? (works for any panel)

Locate the plugins folder, then hand its **parent** to the script:

```bash
sudo find / -type d -name plugins 2>/dev/null | grep -v -E 'node_modules|/proc'
```

Or point the script straight at the plugins folder and let it infer the rest:

```bash
/opt/scripts/update-mc-plugins.sh --plugins-dir /odd/location/plugins
```

---

## Daily cron job

The script is built for unattended use: it plans first, and **does nothing at all** on the (vast majority of) days when no plugin has changed. No restart, no downtime, no file churn.

### Step 1 — verify it works by hand first

```bash
/opt/scripts/update-mc-plugins.sh /srv/minecraft/survival --dry-run
```

### Step 2 — install the cron job

Edit the crontab **for the user that owns the server files**:

```bash
sudo crontab -e -u minecraft     # or: crontab -e   (if you own the files)
```

Add a daily run at 04:30, logging everything:

```cron
30 4 * * * /opt/scripts/update-mc-plugins.sh /srv/minecraft/survival >> /var/log/mc-plugins.log 2>&1
```

Make sure the log is writable by that user:

```bash
sudo touch /var/log/mc-plugins.log
sudo chown minecraft /var/log/mc-plugins.log
```

### Step 3 — restart the server so the new jars load

The script only swaps files. Bracket it with your own stop/start so updates actually take effect. Pick whichever matches your setup.

**systemd:**

```cron
30 4 * * * systemctl stop minecraft && /opt/scripts/update-mc-plugins.sh /srv/minecraft/survival; systemctl start minecraft
```

> The `;` before `systemctl start` (rather than `&&`) is deliberate — the server comes back up **even if the update fails**.

**Docker Compose:**

```cron
30 4 * * * cd /srv/mc && docker compose stop mc && /opt/scripts/update-mc-plugins.sh /srv/mc/data; docker compose start mc
```

**Panel-managed (Crafty / Pterodactyl / AMP):** schedule the update during a window when the panel already restarts the server. Set the panel's scheduled restart for, say, 04:35, and run the script at 04:30 — it finishes in seconds, and the restart picks up the new jars. Or stop the server in the panel, run the script, and start it again.

**No restart mechanism?** Run the script anyway. Nothing breaks — the new jars simply sit on disk until your next restart.

### A safer cron: skip the wrapper, keep the schedule

If you'd rather never have cron stop your server, just run the script bare:

```cron
30 4 * * * /opt/scripts/update-mc-plugins.sh /srv/minecraft/survival >> /var/log/mc-plugins.log 2>&1
```

Then restart at your leisure. New jars only take effect after a restart, so the worst case is that you get the update a bit later.

### Cron tips

- Cron has a minimal `PATH`. If the script can't find `jq` or `curl`, add `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` at the top of the crontab.
- Always use **absolute paths** in cron.
- Quote any path containing spaces.
- Watch it work: `tail -f /var/log/mc-plugins.log`

---

## Reading the output

A healthy run where nothing needs doing:

```
=== plugin update check ===
server dir:  /srv/minecraft/survival
plugins dir: /srv/minecraft/survival/plugins
channel:     release (release = stable only)
Plugin max MC versions: ViaVersion=26.2 ViaBackwards=26.2 ViaRewind=26.2 Geyser=26.2 Floodgate=?
Compatibility ceiling (lowest common denominator): 26.2  (all agree)
Paper: installed=26.2  newest-stable-within-ceiling=26.1.2 (build 74)
Paper 26.2 is within the plugin ceiling 26.2 -- compatible.
No stable Paper build for 26.2 yet (newest stable is 26.1.2); you're on a pre-stable
  build. Compatible with your plugins -- no action needed.
Plugin status:
  - ViaVersion: 5.10.0 [Release]  [current]
  - ViaBackwards: 5.10.0 [Release]  [current]
  - ViaRewind: 4.1.2 [Release]  [current]
  - Geyser: 2.11.0-b1190 [default]  [current]
  - Floodgate: 2.2.5-b138 [default]  [current]
Everything is current. Nothing to do.
=== no action taken ===
```

**Things you might see:**

| Message | What it means |
|---|---|
| `Compatibility ceiling ... (all agree)` | Every plugin supports the same max version. Nothing is holding you back. |
| `... (limited by Geyser)` | Geyser is behind the others and sets the ceiling. Normal after a Minecraft release. |
| `Installed Paper X is ABOVE the plugin ceiling Y` | **The one that matters.** Your Paper is newer than the plugins support — Geyser will likely break. Either wait for Geyser to catch up, or roll Paper back to the ceiling. |
| `No stable Paper build for X yet` | Informational. You're on a pre-stable Paper build, still within the ceiling. Fine. |
| `Paper update AVAILABLE: X -> Y` | A newer *stable* Paper exists within the ceiling. Re-run with `--update-paper` to take it. |
| `Floodgate=?` | Expected. The GeyserMC API doesn't publish supported MC versions for Floodgate; it tracks Geyser and never sets the ceiling. |
| `N duplicate jar(s) to remove` | Two jars declare the same plugin. The script will clean this up. |

---

## FAQ

**Do I need all five plugins?**
No. Use `--skip` to drop any you don't want, e.g. `--skip ViaRewind` if you don't care about 1.7/1.8 clients, or `--skip Geyser,Floodgate` if you don't want Bedrock support.

**Why is it not just grabbing the newest Paper?**
Because that's what breaks Bedrock. The newest Paper is frequently ahead of what Geyser supports. The script deliberately caps Paper at what all your plugins support, and leans on ViaVersion to keep newer clients connecting.

**What does `--channel beta` do?**
Pulls Snapshot/experimental builds instead of stable. Useful right after a Minecraft release, when the Via team ships support as a beta before promoting a stable build. Your daily cron should stay on the default `release`.

**Something broke — how do I roll back?**
Every replaced jar is in `plugins/_backups/<timestamp>/` (and Paper jars in `_paper_backups/`). Copy the old one back and restart.

**Can it update the server jar too?**
Yes, with `--update-paper` — but only to the newest **stable** build at or below the plugin ceiling. It will never push you past what your plugins support. Rolling Paper *down* additionally requires `--allow-downgrade`, and you should back up your world first.

**It says my plugins folder isn't writable.**
Run as the user that owns the server files (`sudo -u minecraft ...`, `sudo -u amp ...`). Running as root on a panel-managed server can leave root-owned files that break the panel.
