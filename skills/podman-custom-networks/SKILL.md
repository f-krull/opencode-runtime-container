---
name: podman-custom-networks
description: |
  Creates and uses custom rootless Podman (CNI) networks on this host despite the Ubuntu podman 3.4.4 "CNI network ... not found" version bug.
  MUST be used whenever the user says "create a podman network", "put containers on the same network", "connect nginx and the auth backend", "fix CNI network", or when a container run fails with "CNI network ... not found" or "error configuring network namespace".
  ALWAYS apply the post-create cniVersion fixup and verify with a real container run before reporting success; `podman network ls` alone is NOT proof.
license: MIT
compatibility: opencode
metadata:
  author: fkrull
  version: 1.0.0
  category: dev-environment
  tags: [podman, cni, networking, containers, rootless, troubleshooting]
---

## What I do
- Create custom CNI networks on the host's rootless podman that containers can actually attach to
- Work around the `cniVersion` 1.0.0/0.4.0 mismatch between the Ubuntu-patched podman and its firewall plugin
- Verify network usability end-to-end (container start + container-to-container name resolution)

## When to use me (Triggers)
- "create a podman network", "make a network for nginx and the auth backend", "podman network create"
- "put both containers on the same network", "connect these containers", "they need to talk to each other"
- Errors: `CNI network "..." not found`, `error configuring network namespace for container ...`
- "why can't my containers reach each other", "the network exists but the container won't start"

## When NOT to use me
- Default networking (no `--network` flag, or `--network podman`) — works out of the box
- `host`, `slirp4netns`, `private`, `none` modes — works as-is
- Podman ≥ 4 (netavark) or rootful podman elsewhere — this bug does not exist there
- DNS/HTTP issues *inside* a running container, or port publishing problems

## Instructions (Step-by-step)

### 0. Environment facts (the trap)
- Agents run inside a container; `podman` is a remote client to the **host's rootless podman 3.4.4** (Ubuntu 22.04 build) via the mounted socket.
- The Ubuntu-patched build writes custom networks with `"cniVersion": "1.0.0"` (upstream 3.4.4 wrote `0.4.0`).
- Ubuntu's `containernetworking-plugins 0.9.1` ships a `firewall` plugin supporting **only 0.4.0**. Every custom conflist contains a `firewall` plugin entry, so libcni rejects the whole list at container start → `CNI network "X" not found`.
- **`podman network ls` / `inspect` lie**: they read the files without version validation and list broken networks as if they were fine. Only a successful `podman run --network X` proves anything.
- The host CNI dir is `/home/fkrull/.config/cni/net.d/` and is NOT mounted into the agent container — edit it only via the helper container in step 2.
- The `VERSION` column in `podman network ls` does reflect the file: `1.0.0` = not fixed, `0.4.0` = fixed.

### 1. Create the network
```bash
podman network create <name>
# optional: --subnet 10.89.150.0/24   (pick a free 10.89.x.0/24)
```
Existing networks/subnets: `podman` = 10.88.0.0/16, `tsd-net` = 10.89.0.0/24, `testnet1` = 10.89.1.0/24, `net2` = 10.89.2.0/24.

### 2. Fix the cniVersion (ALWAYS, immediately after create)
```bash
podman run --rm --network none -v /home/fkrull/.config/cni/net.d:/mnt \
  alpine sh -c 'sed -i "s/\"cniVersion\": \"1.0.0\"/\"cniVersion\": \"0.4.0\"/" /mnt/<name>.conflist && grep -H cniVersion /mnt/<name>.conflist'
```
- Use the absolute host path — `~` expands to the *container* home and fails.
- Expected output: `/mnt/<name>.conflist:   "cniVersion": "0.4.0",`
- No service restart or sleep is needed; the next `podman run` picks it up immediately.

### 3. Verify with a real run (required)
```bash
podman run --rm --network <name> alpine true && echo NETWORK_OK
```
For service wiring, also verify name resolution (containers reach each other by container name, via the dnsname plugin):
```bash
podman run -d --rm --name netcheck1 --network <name> alpine sleep 60
podman run --rm --network <name> alpine ping -c 1 -W 3 netcheck1
podman rm -f netcheck1
```

### 4. Use it
- Start services with `--network <name>`; reference peers by container name (e.g. nginx → `http://auth:3047`).
- Reuse existing networks when they fit; do not recreate or rename networks in use.

## Rules & Constraints (CRITICAL)
- You MUST NEVER report a custom network as working based on `podman network ls` / `inspect` — ALWAYS run a container on it.
- You MUST ALWAYS fix the conflist right after `podman network create`; every new network regresses to 1.0.0.
- You MUST use the absolute host path `/home/fkrull/.config/cni/net.d` in the fixup mount; NEVER `~`.
- You MUST verify with `podman run --network <name> ... ` before wiring real services.
- You MUST NOT touch `/etc/cni/net.d` (root-owned); rootless custom networks live in `/home/fkrull/.config/cni/net.d`.
- NEVER `podman network rm -f` a network that running containers still use; stop them first.

## Examples

### Example 1: wire nginx + auth backend on a new network
```bash
podman network create app-net                                   # 1. create
podman run --rm --network none -v /home/fkrull/.config/cni/net.d:/mnt \
  alpine sh -c 'sed -i "s/\"cniVersion\": \"1.0.0\"/\"cniVersion\": \"0.4.0\"/" /mnt/app-net.conflist'   # 2. fix
podman run --rm --network app-net alpine true                   # 3. verify
podman run -d --name auth  --network app-net <auth-image>       # 4. use
podman run -d --name nginx --network app-net -p 8080:80 nginx
# nginx config proxies to http://auth:<port>
```

### Example 2: user reports "CNI network \"tsd-net\" not found" while `network ls` shows it
1. `podman network ls` → check VERSION column: if 1.0.0, it is the trap.
2. Apply step 2 to that conflist (name → file `tsd-net.conflist`).
3. Verify with step 3, then continue the original task.

## Error Handling & Edge Cases
- **`CNI network "X" not found` / `error configuring network namespace`** → 99% the version trap: run `grep cniVersion` check (step 2); fix and re-verify. Do NOT debug CNI cache, service restarts, or timing — those are red herrings on this host.
- **`podman run` works but containers cannot reach each other by name** → check both are on the same `--network`, and re-run the ping test from step 3.
- **Subnet collision on create** → pick another free `10.89.x.0/24`.
- **Fixup mount fails / path missing** → inspect the host view with `podman run --rm --network none -v /:/host:ro alpine ls /host/home/fkrull/.config/cni/net.d`; create the network first (the file appears only after `network create`).
- **Future-proofing**: if the host is ever upgraded (podman ≥ 4 / netavark, or a newer firewall plugin is installed), the fixup becomes a harmless no-op; the run-verification step remains the source of truth.

## References & Resources
- Root cause detail: Ubuntu podman writes `version.Current()` = 1.0.0 (`libpod/network/cni/cni_conversion.go`), while plugin validation (libcni `ValidateNetworkList`) requires every plugin to advertise the list version; Ubuntu's `firewall` plugin advertises only `0.4.0`.
- Listing vs. attaching asymmetry: `network ls` uses the raw loader (`pkg/domain/infra/abi/network.go` → `LoadCNIConfsFromDir`, no validation); attaching uses the validated loader + ocicni (`CNI network %q not found`).
- Durable alternative (not required): newer `firewall` plugin in a personal dir + `cni_plugin_dirs` in `~/.config/containers/containers.conf`, or upgrade podman.
- Environment docs: repo `AGENTS.md` (Security Model, Podman Client Version).
