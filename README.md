# ha_one_click_install

One command turns a fresh Debian machine into a complete Home Assistant setup:
Ansible configures the host, and Docker Compose runs the services.

```bash
curl -fsSL https://raw.githubusercontent.com/notabotsl/ha_one_click_install/main/install.sh | sudo bash
```

Then open `http://<machine-ip>:8123` and create your Home Assistant account.

## What you get

| Component | What it does | URL / port |
|---|---|---|
| **Home Assistant** (container) | The core (host networking, Bluetooth via D-Bus, USB access) | `:8123` |
| **Mosquitto** | MQTT broker with authentication | `:1883` |
| **Zigbee2MQTT** | Zigbee coordinator to MQTT bridge (auto-discovered by HA) | `:8080` |
| **Node-RED** | Flow automations, with the Home Assistant nodes preinstalled | `:1880` |
| **ESPHome** | Builds and flashes ESP32/ESP8266 devices | `:6052` |
| **HACS** | Home Assistant Community Store (custom integrations/cards) | in HA |
| Matter server *(optional)* | Matter/Thread controller for HA | `ws://:5580/ws` |
| code-server *(optional)* | VS Code in the browser for editing configs | `:8443` |

Host extras: Docker CE from the official repository with container log rotation,
Bluetooth (BlueZ), Avahi/mDNS, unattended security upgrades, ModemManager disabled
so it doesn't grab USB radios, a daily backup timer, and the `ha-stack` management
command.

These containers replace the "add-ons" of Home Assistant OS. HA Container has no
Supervisor, so add-ons run as separate containers in the same compose project.

## Requirements

- Debian 12 (bookworm) or 13 (trixie). Ubuntu 22.04+ and Raspberry Pi OS 64-bit also work.
- amd64 or arm64. Home Assistant no longer ships 32-bit images.
- At least 2 GB RAM and 32 GB of storage. An SSD is strongly preferred over an SD card.
- A Zigbee USB coordinator (optional), e.g. Sonoff ZBDongle-E/-P, Home Assistant Connect ZBT-1, ConBee II/III, SMLIGHT.

## Install options

Pass options after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/notabotsl/ha_one_click_install/main/install.sh \
  | sudo bash -s -- --tz Europe/Madrid --with-matter
```

| Option | Effect |
|---|---|
| `--tz ZONE` | Set the host and container timezone |
| `--zigbee-device PATH` | Use this coordinator (`/dev/serial/by-id/...`) instead of autodetecting |
| `--zigbee-adapter TYPE` | `zstack`, `ember`, `deconz`, `zigate` or `zboss` |
| `--no-zigbee` / `--no-nodered` / `--no-esphome` / `--no-hacs` / `--no-backup` | Leave out that component |
| `--with-matter` / `--with-code-server` | Add that component |
| `--update` | Pull newer images during this run |
| `--branch NAME` | Install from another branch |
| `-- <ansible args>` | Pass the rest to `ansible-playbook`, e.g. `-- -e ha_admin_user=me -v` |

Options are saved to `/etc/ha-stack/config.yml`, so re-runs keep them. Every
variable in [`group_vars/all.yml`](group_vars/all.yml) can be set in that file
(image tags, ports, passwords, backup schedule, and so on).

### What install.sh does

1. Checks the OS and architecture, and installs `git`, `python3-venv` and `python3-apt`.
2. Clones this repository to `/opt/ha-stack-installer`, or updates it on later runs.
3. Installs a recent `ansible-core` into `/opt/ha-stack-installer-venv` and the
   collections listed in `requirements.yml`.
4. Runs `site.yml` against `localhost`. The log goes to `/var/log/ha-stack-install.log`.

## Day-to-day: `ha-stack`

```text
sudo ha-stack status              # containers
sudo ha-stack logs zigbee2mqtt    # follow logs
sudo ha-stack restart homeassistant
sudo ha-stack update              # pull new images and recreate containers
sudo ha-stack backup              # back up now
sudo ha-stack credentials         # generated passwords
sudo ha-stack config              # edit /etc/ha-stack/config.yml
sudo ha-stack reconfigure --with-code-server   # re-run the installer
```

## After install: connect the pieces in Home Assistant

Go to **Settings → Devices & services → Add integration** and set up:

1. **MQTT**: broker `127.0.0.1`, port `1883`, user `mqtt`, and the password from
   `sudo ha-stack credentials`. Zigbee2MQTT devices then show up automatically.
2. **HACS**: follow the GitHub device-login flow.
3. **Matter** (if enabled): `ws://127.0.0.1:5580/ws`.
4. **Node-RED**: in Node-RED, add a *Home Assistant server* with base URL
   `http://host.docker.internal:8123` and a long-lived access token from your HA profile.
5. **ESPHome**: devices you flash are discovered automatically.

## Zigbee

The playbook looks in `/dev/serial/by-id/` for a known coordinator and guesses the
adapter type from its name (for example, ZBDongle-E/ZBT-1 → `ember`,
ZBDongle-P/CC2652 → `zstack`, ConBee → `deconz`). If it finds no stick and
`ha_zigbee2mqtt_enabled` is `auto` (the default), Zigbee2MQTT is skipped. Plug the
stick in and run `sudo ha-stack reconfigure` to add it.

Zigbee2MQTT writes its own `configuration.yaml` (it stores the generated network key
there), so the playbook only seeds that file once. The MQTT credentials, serial port
and frontend settings come from `secrets/zigbee2mqtt.env` and always override it.
**Back up `zigbee2mqtt/data`**: if you lose the network key, you have to re-pair
every device.

## Remote provisioning

You can also run the playbook from your workstation:

```bash
cp inventory/remote.example.yml inventory/remote.yml   # edit host/user
ansible-galaxy collection install -r requirements.yml -p collections
ansible-playbook -i inventory/remote.yml site.yml -K
```

## Layout on the target

```text
/opt/ha-stack/
├── compose.yml              # generated, do not edit
├── homeassistant/           # HA /config (yours; seeded only once)
├── mosquitto/{config,data,log}
├── zigbee2mqtt/data/
├── nodered/                 # settings.js is managed; flows are yours
├── esphome/  matter/  code-server/
└── secrets/                 # credentials.yml, *.env (root only, 0600)
/etc/ha-stack/config.yml     # your settings
/var/backups/ha-stack/       # daily archives (7 kept by default)
```

## Backups and restore

`ha-stack-backup.timer` runs daily at 03:30. It archives `/opt/ha-stack`, including
the secrets, and takes a consistent `sqlite3 .backup` copy of the HA database. To
restore:

```bash
sudo ha-stack stop
sudo tar -xzf /var/backups/ha-stack/ha-stack-YYYYmmdd-HHMMSS.tar.gz -C /opt
sudo tar -xzf /var/backups/ha-stack/ha-stack-YYYYmmdd-HHMMSS.tar.gz -C /opt/ha-stack/homeassistant home-assistant_v2.db
sudo ha-stack start
```

Copy the archives off the machine as well, for example to a NAS or with
`rclone`/`restic`. Home Assistant's own backups (Settings → System → Backups) are
a good second layer.

## Security notes

- Every web UI is password-protected with generated credentials, and MQTT does not
  allow anonymous clients.
- Docker-published ports bypass `ufw`/`iptables` INPUT rules. Keep this machine on
  a trusted LAN and use a VPN (WireGuard/Tailscale) or Nabu Casa for remote access.
  Don't port-forward these services.
- Home Assistant runs `privileged` with host networking, as the official
  container docs recommend for USB and Bluetooth.

## Uninstall

```bash
sudo docker compose --project-directory /opt/ha-stack down
sudo systemctl disable --now ha-stack-backup.timer
sudo rm -rf /opt/ha-stack /opt/ha-stack-installer /opt/ha-stack-installer-venv /etc/ha-stack \
  /usr/local/bin/ha-stack /usr/local/sbin/ha-stack-backup /etc/systemd/system/ha-stack-backup.*
```
