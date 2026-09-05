# Self-hosted RustDesk server — deploy notes

Host: TrueNAS `192.168.1.72`, stack at `/mnt/HDDs/Applications/rustdesk-server/`.
Public name: `vpn.omaryazeedi.com` (existing DDNS, refreshed every 5 min).

**Not deployed.** Step 2 decides whether the rest is worth doing.

## Why this became necessary

RustDesk's public servers now refuse anonymous connections and demand an
account. ID resolution goes through them even for a LAN connection, so this is
no longer a performance question.

## 1. Copy the stack up

```
scp -r deploy/rustdesk-server truenas_admin@192.168.1.72:/tmp/
sudo mv /tmp/rustdesk-server /mnt/HDDs/Applications/
```

## 2. Port mappings — UDP first

Everything proven inbound on 2026-08-08 was TCP. RustDesk registration and
heartbeat run over **UDP 21116**. If UDP does not survive the double NAT,
nothing else here matters, so prove that one before doing any of the rest.

Two layers, both required.

**ONT** `192.168.100.1` — Forward Rules → IPv4 Port Mapping → New.
Type: User-defined · WAN: `2_INTERNET_R_VID…` · Internal Host `192.168.100.20`
(the Velop's WAN) · External Source IP and Port both BLANK · click **Add** to
reveal the protocol/port row before Apply.

**Velop** → internal host `192.168.1.72`.

| Port | Proto | Purpose | Missing means |
|------|-------|---------|---------------|
| 21116 | **UDP** | ID registration, heartbeat | nothing connects at all |
| 21116 | TCP | NAT hole punching | everything falls back to relay |
| 21115 | TCP | NAT type detection | punching quality degrades |
| 21117 | TCP | relay (hbbr) | fails when P2P is impossible |

Never forward 443 on the Velop — it hijacks the Velop's own admin HTTPS and
locks you out of `https://192.168.1.1`.

21118/21119 are websocket ports for the browser client. Skip them.

## 3. Start

```
cd /mnt/HDDs/Applications/rustdesk-server && sudo docker compose up -d
```

```
sudo docker compose logs --tail=40
```

A restart loop means the volumes were changed away from named volumes and hit
the ACL trap.

## 4. Take the public key

```
sudo docker exec hbbs cat /root/id_ed25519.pub
```

With `key` set, hbbs refuses any client that cannot present it — which is what
makes a publicly reachable ID server safe to run. Treat it as a secret.

## 5. Verify from outside

LAN success proves nothing; the whole point is the path from outside.

```
curl -H 'Accept: application/json' 'https://check-host.net/check-tcp?host=vpn.omaryazeedi.com%3A21117&max_nodes=5'
```

then `/check-result/<id>`. That covers TCP 21117 only — check-host has no UDP
probe, so **UDP 21116 can only be proven by a real client connecting from
mobile data with wifi off.**

## 6. Point the clients at it

- **Fork (Windows + Android):** compiled in via `load_custom_client()` in
  `src/common.rs`, next to the app name. Needs the key from step 4, so it
  cannot be done first. After a rebuild both devices come up configured — no
  typing, no login, no nag.
- **Desktop stock RustDesk:** Settings → Network → ID/Relay Server. Host and
  peer must share a rendezvous server or they cannot see each other.

## 7. Pin the images

```
sudo docker image inspect rustdesk/rustdesk-server:1.1.14 --format '{{index .RepoDigests 0}}'
```

## Rollback

```
cd /mnt/HDDs/Applications/rustdesk-server && sudo docker compose down
```

Clients keep working only while they have not been repointed; once the key is
compiled in they will not fall back to the public server on their own.
