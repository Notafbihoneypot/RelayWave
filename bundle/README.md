# OpenCast — single-node Proxmox test bundle

This bundle turns one small Debian VM on Proxmox into a **LAN-only OpenCast integration test node**. It is intentionally not the final production architecture.

## What runs in the VM

```text
Android / browser on your LAN
          |
          v
  nginx privacy edge
  :8080 OpenCast app
  :8081 Blossom cache/origin gateway
          |
     +----+----------------+
     |                     |
     v                     v
OpenCast app           Blossom server
JSON test DB           local blob storage
     |
     +------> local Nostr relay :7447
```

Included:

- Current OpenCast PWA/API test build.
- Disposable **TEST_MODE** Nostr identity for safe workflow testing.
- Local Blossom origin using `hzrd149/blossom-server` with BUD-11 signed upload auth.
- Local Nostr relay using `ghcr.io/mattn/nostr-relay`.
- nginx edge in front of the app and Blossom.
- HTTP cache for public Blossom GET/HEAD requests.
- No nginx access logs.
- Container stdout/stderr goes to a **volatile systemd journal**.
- In-memory IP rate limiting at nginx; it is not written to the analytics database.
- Aggregate-only OpenCast analytics already present in the app.
- Passphrase-encrypted `age` backup/restore scripts.

### Important prototype limitation

The current OpenCast prototype still uses `data/db.json`, not PostgreSQL. That is deliberate here: this package is for end-to-end testing of publishing, media, RSS, Nostr, tips, analytics and discovery. PostgreSQL/multi-tenant production storage is the next database migration, not something this bundle falsely claims to include.

## Recommended VM

For local testing:

- Debian 13
- 2 vCPU
- 4 GB RAM
- 32 GB disk
- VirtIO NIC on your normal LAN bridge
- DHCP initially

The included Proxmox script uses the official Debian 13 genericcloud image and creates those defaults.

## Option A — create the VM with the included script

Copy this bundle to a Proxmox host or extract only `proxmox/create-vm.sh` there, then run:

```bash

chmod +x proxmox/create-vm.sh
./proxmox/create-vm.sh
```

The script asks for:

- VMID
- Proxmox storage
- bridge (normally `vmbr0`)
- CPU/RAM/disk
- SSH public key or a cloud-init password

It downloads Debian 13 genericcloud, creates the VM, enables DHCP and starts it.

## Option B — create the VM in the Proxmox GUI

Create a normal Debian 13 VM with roughly **2 vCPU / 4 GB / 32 GB**, attach it to `vmbr0`, install Debian, then copy this extracted folder into the VM.

## Install inside the VM

Copy the extracted `OpenCast-Proxmox-Test` folder into the VM. For example from another Linux machine:

```bash
scp -r OpenCast-Proxmox-Test opencast@VM_IP:/tmp/
```

Then in the VM:

```bash
cd /tmp/OpenCast-Proxmox-Test
sudo ./install-in-vm.sh
```

The installer:

1. installs Podman and required tools;
2. installs qemu-guest-agent;
3. clones/builds the current Blossom server;
4. builds the bundled OpenCast image;
5. pulls the local relay and nginx images;
6. detects the VM's LAN IP;
7. enables volatile journald;
8. installs a systemd service;
9. starts the stack.

## Open it

If the VM is `192.168.1.80`:

```text
OpenCast:      http://192.168.1.80:8080
Blossom edge: http://192.168.1.80:8081
Nostr relay:  ws://192.168.1.80:7447
```

On Android, browse to the OpenCast URL and use **Test identity**. This HTTP LAN deployment is for the disposable signer and core workflow. NIP-55/PWA production-style testing should later use a trusted HTTPS hostname.

Recommended test order:

1. Test identity.
2. Publication → save.
3. Article → sign/publish.
4. Podcast → publish metadata/episode.
5. Media → upload a small audio file to local Blossom.
6. RSS → open the generated feed.
7. Monero → use a **public receiving address only**.
8. Insights → seed private demo analytics.
9. Discover → query local content / relay search.
10. Cross-post → generate previews / simulated queue.

## Commands inside the VM

```bash
sudo /opt/opencast-test/scripts/status.sh
sudo /opt/opencast-test/scripts/logs.sh
sudo /opt/opencast-test/scripts/set-lan-ip.sh 192.168.1.80  # if the VM address changes
sudo systemctl restart opencast-test
sudo systemctl stop opencast-test
sudo systemctl start opencast-test
```

Persistent test data:

```text
/opt/opencast-test/data/app       OpenCast JSON datastore
/opt/opencast-test/data/blossom   Blossom SQLite + blobs
/opt/opencast-test/data/relay     relay SQLite database
/opt/opencast-test/data/cache     disposable public edge cache
```

## LAN exposure

The Podman published ports are bound to the VM's selected **LAN IPv4 address**, not `0.0.0.0`. Do not port-forward 8080/8081/7447 from your router while `TEST_MODE=1`. A DHCP reservation is recommended so the URL does not change.

## Encrypted backup

Create a passphrase-encrypted snapshot:

```bash
sudo /opt/opencast-test/scripts/backup.sh /mnt/backup/opencast-test.tar.age
```

`age` prompts for the passphrase. Keep that passphrase **off the VM**.

Restore:

```bash
sudo /opt/opencast-test/scripts/restore.sh /mnt/backup/opencast-test.tar.age
```

## Privacy behavior in this local test

- nginx access logs: **off**
- journald: **volatile**, capped, and removed on reboot
- full listener IPs in OpenCast analytics DB: **not stored**
- full User-Agent strings in analytics DB: **not stored**
- city/precise location analytics: **not collected**
- Monero tips ↔ listener analytics joins: **not implemented**
- edge request limiting: uses IP only in RAM while the request/rate-limit state exists

The VM host and your LAN router can still observe network metadata. This setup tests our application's privacy behavior; it is not confidential-computing protection against the Proxmox host administrator.

## Internet access during install

The installer needs outbound HTTPS once to pull container images and clone Blossom. After images are present, normal LAN testing can continue even if external Nostr search/directory features are unavailable.

## TEST_MODE warning

`TEST_MODE=1` is intentionally enabled. Anyone who can reach this VM can use the shared disposable signer endpoint. Keep this deployment on a trusted LAN. Do **not** expose port 8080 to the public Internet while TEST_MODE is enabled.

## Shadow-migration audit for the Yellowball test feed

This bundle includes a read-only migration auditor for the test feed `https://feeds.yellowball.fm/7IvrdL`.
It does **not** modify the live RSS feed, redirect directories, or change the existing host.

After the VM installer has installed Node.js, run:

```bash
cd /tmp/OpenCast-Proxmox-Test   # or wherever you copied this bundle
./tools/audit-yellowball.sh
```

The report is written to `~/yellowball-shadow-audit/` as:

- `source-feed.xml` — untouched source XML snapshot
- `audit.json` — full machine-readable migration report
- `episodes.csv` — episode/GUID/enclosure audit table

The auditor preserves/inspects GUIDs and publication dates, probes enclosure sizes, MIME types and byte-range support, estimates one-copy/two-copy/backup storage, detects Podcasting 2.0 tags, and flags broken media links.

To also make a local **shadow copy** of every episode (this can use substantial disk/bandwidth):

```bash
./tools/audit-yellowball.sh --copy-media
```

Do not set a 301 redirect or change directory listings during this test.
