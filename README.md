# RelayWave — Proxmox single-node test installer

One-file installer for the **LAN-only development/test stack**. Run it on a Proxmox VE host (intended for **PVE1**); it creates a dedicated Debian 13 virtual machine and installs Podman and the app stack **inside the VM**, not on the PVE host.

## Install on PVE1

Log in as `root` on PVE1, then run:

```bash
curl -fsSL https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/install.sh -o /root/relaywave-install.sh && bash /root/relaywave-install.sh
```

**Do not use `curl ... | bash`**: the installer reads an embedded archive from its own `install.sh` file, so it needs to exist on disk.

For a safer inspected installation:

```bash
curl -fsSL https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/install.sh -o /root/relaywave-install.sh
sha256sum /root/relaywave-install.sh
less /root/relaywave-install.sh
bash /root/relaywave-install.sh
```

Expected SHA-256 for this initial installer:

```
b903baee8a8c2259a135462b8d5f955efd0743fe1d12595abdc8e1ccc1b7fb06
```

## Defaults

| Setting | Default |
| --- | --- |
| Guest OS | Debian 13 cloud image |
| VM resources | 2 vCPU, 4 GiB RAM, 40 GiB disk |
| Network | `vmbr0`, DHCP |
| VM name | `podcast-test` |
| Disk storage | Detected Proxmox image storage |
| Container runtime | Podman installed in guest if needed |

Installer prompts allow changing these defaults. It creates the VM, embeds the app in Cloud-Init, starts the VM, waits for the guest agent/app, and prints the discovered LAN IP and the generated VM console/SSH password.

## Service endpoints

- Dashboard: `http://<VM-IP>:8080`
- Blossom/media edge: `http://<VM-IP>:8081`
- Nostr relay: `ws://<VM-IP>:7447`

## Safety and limitations

- **TEST MODE ONLY**: don't port-forward these ports or deploy on an Internet-accessible bridge without proper network isolation. The installer assumes the VM's bridge is trusted LAN; it does not itself enforce a Proxmox firewall rule.
- Don't use real secrets or depend on the test stack for production publishing.
- This installer has passed syntax checks but has **not** been tested against your actual PVE1 hardware/configuration.
- Podman runs inside a dedicated VM. The installer may update a Proxmox directory storage's allowed content types to enable Cloud-Init snippets.
- Protect the generated VM login password and the Cloud-Init snippet containing its password hash.

To troubleshoot after creation, open the VM console and run `sudo tail -f /var/log/opencast-bootstrap.log`. To remove it, use the VMID reported by the script and confirm the VM is the test VM before destroying it.

## If the installer appears to fail

**Do not rerun the installer immediately**: the script may already have created a VM. On PVE1, run the read-only diagnostic helper:

```bash
curl -fsSL https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/diagnose.sh -o /root/relaywave-diagnose.sh && bash /root/relaywave-diagnose.sh
```

If you chose a custom VM name, pass its VMID: `bash /root/relaywave-diagnose.sh 123`.

The tool reports VM status, whether the guest agent responds, Cloud-Init progress, recent bootstrap logs, Podman status, and the app service/container state. It does not change or delete anything. **Review any network addresses or sensitive log lines before sharing output.** If no VM exists, send the error printed by the original installer. The installer currently cannot diagnose a failed stage without its terminal output or guest logs.

### Recover an existing VM after the nftables/Podman netavark failure

If VM `103` named `podcast-test` exists but the app cannot start, **do not rerun install.sh** (which would create another VM). Run on PVE1:

```bash
curl -fsSL https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/repair-vm.sh -o /root/relaywave-repair.sh && bash /root/relaywave-repair.sh 103
```

This checks the VM name, requires the guest agent, installs `nftables` if missing, qualifies the upstream Deno/Node container images for Podman, restarts `opencast-test.service`, and reports actual service status. It never deletes or creates VMs. If the app still fails, share the printed error without private data.

## Verify an existing podcast without email

The single-node installer now includes a private RSS administrative-control challenge.
Open **Import podcast** in the dashboard, connect a Nostr signer (the disposable test signer works only on your trusted LAN), paste the current podcast RSS feed and generate a one-time code.

Add the code to the **original host** as a channel-level Podcasting 2.0 TXT field with `purpose="verify"`. Save the feed, return to RelayWave and choose **Verify ownership**. Claims are linked to the authenticated Nostr public key. Challenges last 30 minutes. The verifier fetches only public HTTPS feeds with pinned public DNS addresses, no redirects, strict size limits and no contact with private network addresses.

This build **only verifies administrative feed control**. It does not copy media, publish imported RSS, notify directories, or redirect listeners. Feed host must expose Podcast TXT editing. No email is collected.

### Upgrade an existing RelayWave test VM

**Do not rerun `install.sh` on PVE1.** That creates another VM. For the existing `podcast-test` VM 103, run as root on PVE1:

```bash
curl -fsSL https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/update-vm.sh -o /root/relaywave-update.sh && bash /root/relaywave-update.sh 103
```

This uses Proxmox guest-agent execution to update only the application source inside VM 103, rebuild/restart the Podman stack and keep persistent volumes intact. The feature updater can also run again safely and does not change any other VM.

### Repair the Blossom short-name build error

On Debian 13 with Podman's default strict registry configuration, a vendored Blossom Dockerfile containing `FROM denoland/deno:debian` fails because it has no fully qualified registry. The in-place repair command above patches this to `docker.io/denoland/deno:debian` and makes the correction persist through service restarts. It also qualifies the app's Node base image and corrects health checks for LAN-only bindings. The fresh VM installer has the same correction before its first build. Avoid weakening Podman policy by adding an unqualified registry search path.

### Existing VM 103: tested relay startup repair v2

The original RelayWave test bundle references `ghcr.io/mattn/nostr-relay:latest` three times (image lookup, pull, launch). The earlier repair failed by expecting only one occurrence. The new helper changes only the actual `podman run` command, ensures stale test containers can be removed without deleting bind-mounted data, and keeps the change idempotent.

Download the versioned repair **on PVE1** (do not reuse any old local `repair-vm.sh` download):

```bash
curl -fsSL https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/repair-vm-v2.sh -o /root/relaywave-repair-v2.sh && bash /root/relaywave-repair-v2.sh 103
```

The repair script pins the v2 runtime helper to commit `e8aa237` to avoid accidentally executing a cached older helper. No VM recreation or data-directory deletion is performed.
