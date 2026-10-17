# RelayWave: 2000s portal theme (test preview)

A responsive, dependency-free **static visual prototype** of the selected 2000s-style RelayWave mockup: deep blue and purple pixel sunset banner, bevelled blue-silver sidebar, bright yellow buttons, colorful workflow tiles, and a compact creator dashboard preview.

**This is NOT a replacement for the existing dashboard.** It is an isolated design proof-of-concept at /retro.html that links to the existing dashboard (/). It does not add APIs, modify backend logic, update databases, or redirect podcast RSS feeds. The dashboard numbers displayed inside the retro page are explicitly illustrative.

## Test it on your existing PVE1 VM 103

Run **on the Proxmox host pve1 as root**, not in the guest:

    curl -fsSL https://raw.githubusercontent.com/Notafbihoneypot/RelayWave/main/themes/retro-2000/deploy-to-vm.sh -o /root/relaywave-retro-deploy.sh
    bash /root/relaywave-retro-deploy.sh 103

If successful, open:

- Retro page: **http://192.168.1.32:8080/retro.html**
- Current dashboard: **http://192.168.1.32:8080/**

Replace the IP if the VM's DHCP address has changed. The script prints the actual address.

### What the deployer changes

1. Verifies VM 103 is podcast-test and the guest agent works.
2. Downloads the pinned HTML into /opt/opencast-test/app/public/retro.html in the guest, backing up any previous file.
3. If opencast-app is running, copies that single page into /app/public without restarting the backend.
4. Checks that the /retro.html page is served via the app.

The preview also survives subsequent image rebuilds because it lives in the on-disk public source directory.

No VM recreation, Podman host installation, publishing changes, Nostr key changes, or overwrite of the existing index.html.

### View without Proxmox

The preview is one self-contained HTML file with inline CSS and SVG. Download retro.html from this folder and open it locally.

### Rollback

The current dashboard is unaffected. To remove the preview, delete /opt/opencast-test/app/public/retro.html inside VM 103, then restart the RelayWave service at a convenient time to rebuild the image without it.

### Notes

- On mobile the sidebar and tiles stack to fit the screen.
- Links navigate within the preview, the live test dashboard, or public documentation/feedback pages.
- This is not ready for public deployment. Keep test VM ports LAN-only.
