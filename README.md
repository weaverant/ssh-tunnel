# ssh-tunnel

Minimal, hardened, distroless SSH container for TCP port forwarding. Built on OpenSSH 10.6 with post-quantum cryptography (PQC) key exchange and optional post-quantum authentication.

## Features

- **Distroless** -- `FROM scratch`, no shell, no package manager (~8MB image)
- **No busybox** -- `/sbin/nologin` is a static stub, not Alpine's multi-call binary
- **PQC key exchange** -- ML-KEM-768 hybrid (FIPS 203) with X25519 fallback
- **ED25519 keys** -- host keys and user authentication, hybrid post-quantum ML-DSA optional
- **Tunnel-only** -- local TCP forwarding, no shell, no SFTP, no SCP
- **Hardened** -- read-only filesystem, dropped capabilities, no-new-privileges

## Quick Start

Generate a host key. The image carries `ssh-keygen`, so nothing has to be installed on the host:

```bash
mkdir host_keys
docker run --rm --entrypoint /usr/bin/ssh-keygen -v "$PWD/host_keys:/out" \
  ghcr.io/weaverant/ssh-tunnel:latest \
  -t ed25519 -N "" -C ssh-tunnel -f /out/ssh_host_ed25519_key
```

The key files are written by the container, so on Linux they belong to root. A local `ssh-keygen -t ed25519 -f host_keys/ssh_host_ed25519_key -N ""` works just as well.

Create an `authorized_keys` file with your public key(s):

```bash
cp ~/.ssh/id_ed25519.pub authorized_keys
```

Start the container:

```bash
docker compose up -d
```

Connect:

```bash
ssh -p 2222 -N -L 8080:internal-host:80 tunnel@gateway
```

## Published image

Prebuilt images are published to the GitHub Container Registry, so you don't have to build locally:

```bash
docker pull ghcr.io/weaverant/ssh-tunnel:latest
```

Available tags:

| Tag | Tracks |
|---|---|
| `latest` | Newest release |
| `0.2.0` | A specific pinned release |
| `0.2` | Latest patch within a major.minor line |

To run the published image directly with the same hardening as `docker-compose.yml`:

```bash
docker run -d --name ssh-tunnel \
  -p 2222:2222 \
  --read-only --tmpfs /run --tmpfs /tmp \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --cap-add SETUID --cap-add SETGID --cap-add SYS_CHROOT --cap-add DAC_OVERRIDE \
  -v "$PWD/host_keys:/etc/ssh/host_keys:ro" \
  -v "$PWD/authorized_keys:/etc/ssh/authorized_keys:ro" \
  ghcr.io/weaverant/ssh-tunnel:latest
```

Or point `docker-compose.yml` at the published image by replacing `build: .` with `image: ghcr.io/weaverant/ssh-tunnel:latest`.

## Configuration

All hardening is baked into the image. No environment variables, no runtime configuration.

The container expects two bind mounts:

| Mount | Container Path | Mode |
|---|---|---|
| Host key directory | `/etc/ssh/host_keys` | `ro`, private keys `0600` |
| Authorized keys | `/etc/ssh/authorized_keys` | `ro`, `0644` |

sshd looks for `ssh_host_ed25519_key` and `ssh_host_mldsa44_ed25519_key` in the host key directory and runs on whichever it finds. A deployment that mounts the single ED25519 key file, as documented before 0.2.0, keeps working unchanged.

## Post-quantum authentication (ML-DSA)

Key exchange is always post-quantum (ML-KEM-768 hybrid). Authentication uses ED25519 keys by default. Since 0.2.0 the image also accepts `ssh-mldsa44-ed25519`, the hybrid post-quantum signature type introduced in OpenSSH 10.6, for host keys and for user keys. Nothing changes until you opt in, and both key types work side by side.

A client needs OpenSSH 10.6 or newer to use ML-DSA. Older clients keep working with ED25519 for as long as the ED25519 keys stay in place.

### Upgrading from 0.1.x

Pull the new image and restart. No configuration change is needed. sshd logs one line at every start for the host key type that is not there:

```
Unable to load host key: /etc/ssh/host_keys/ssh_host_mldsa44_ed25519_key
```

That line is expected and harmless: sshd runs on the keys it finds.

### Switching to ML-DSA

1. **Add an ML-DSA host key** next to the existing one and restart:

   ```bash
   docker run --rm --entrypoint /usr/bin/ssh-keygen -v "$PWD/host_keys:/out" \
     ghcr.io/weaverant/ssh-tunnel:latest \
     -t mldsa44-ed25519 -N "" -C ssh-tunnel -f /out/ssh_host_mldsa44_ed25519_key
   docker compose restart
   ```

   If your setup still mounts the single ED25519 key file, mount the directory instead (`./host_keys:/etc/ssh/host_keys:ro`) and recreate the container. Existing clients notice nothing. OpenSSH 10.6 clients that already know the host learn the new key on their next connection.

2. **Add ML-DSA user keys.** Each user creates one with `ssh-keygen -t mldsa44-ed25519` and you append the public key to `authorized_keys`. No restart is needed, and the ED25519 keys keep working.

3. **Let clients verify the host with ML-DSA.** While both host keys are present, clients choose ED25519. To use the ML-DSA host key already, set this on the client:

   ```
   Host gateway
       HostKeyAlgorithms ssh-mldsa44-ed25519,ssh-ed25519
   ```

4. **Retire ED25519 (optional).** Once every client runs OpenSSH 10.6 or newer, remove the ED25519 public keys from `authorized_keys`, delete `host_keys/ssh_host_ed25519_key` and its `.pub`, and restart. From then on a client without ML-DSA support cannot connect, and the startup log line names the ED25519 key instead.

## Security

### sshd

| Setting | Value |
|---|---|
| Authentication | Public key only (ED25519 or ML-DSA hybrid) |
| Key exchange | `mlkem768x25519-sha256`, `sntrup761x25519-sha512`, `curve25519-sha256` |
| Ciphers | `chacha20-poly1305`, `aes256-gcm` |
| Compression | Disabled |
| Forwarding | Local TCP only |
| Shell access | None (`ForceCommand /sbin/nologin`, `PermitTTY no`) |
| SFTP/SCP | Disabled |
| Agent/X11 forwarding | Disabled |

### Container

| Setting | Value |
|---|---|
| Filesystem | Read-only |
| Capabilities | All dropped, only SETUID/SETGID/SYS_CHROOT/DAC_OVERRIDE added |
| Privilege escalation | Blocked (`no-new-privileges`) |
| Base image | `scratch` (no shell, no package manager) |
| Binaries present | `sshd`, `sshd-session`, `sshd-auth`, `ssh-keygen`, static `nologin` -- nothing else |

## Building

```bash
docker build -t ssh-tunnel .
```

## Testing

`tests/smoke.sh` builds the image, stands up an nginx backend, two ssh-tunnel containers with the full `docker-compose.yml` hardening (one with only an ED25519 host key, one that also has an ML-DSA host key) and an SSH client on a private network, then forwards a port through the tunnel and fetches the backend through it. Needs only docker.

```bash
./tests/smoke.sh                                          # build from this tree and test
IMAGE=ghcr.io/weaverant/ssh-tunnel:0.2.0 ./tests/smoke.sh  # test a published image
```

It checks the reported OpenSSH version, that `/sbin/nologin` is the static stub rather than busybox, that the port forward reaches the backend, that a shell session is refused, that ML-DSA user and host keys work, and that the image's own `ssh-keygen` produces the ML-DSA host key. Exits non-zero on any failure.

## License

MIT
