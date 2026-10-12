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
990eeb3e7728123d58a38a5c8aecc042dda2712a3eb0b5f9bedd95032ab44a35
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
