# ssh-tunnel

Minimal, hardened, distroless SSH container for TCP port forwarding. Built on OpenSSH 10.3 with post-quantum cryptography (PQC) key exchange.

## Features

- **Distroless** -- `FROM scratch`, no shell, no package manager (~8MB image)
- **PQC key exchange** -- ML-KEM-768 hybrid (FIPS 203) with X25519 fallback
- **ED25519 only** -- host keys and user authentication
- **Tunnel-only** -- local TCP forwarding, no shell, no SFTP, no SCP
- **Hardened** -- read-only filesystem, dropped capabilities, no-new-privileges

## Quick Start

Generate a host key:

```bash
mkdir host_keys
ssh-keygen -t ed25519 -f host_keys/ssh_host_ed25519_key -N ""
```

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

## Configuration

All hardening is baked into the image. No environment variables, no runtime configuration.

The container expects two bind mounts:

| Mount | Container Path | Mode |
|---|---|---|
| Host key | `/etc/ssh/host_keys/ssh_host_ed25519_key` | `ro`, `0600` |
| Authorized keys | `/etc/ssh/authorized_keys` | `ro`, `0644` |

## Security

### sshd

| Setting | Value |
|---|---|
| Authentication | Public key only (ED25519) |
| Key exchange | `mlkem768x25519-sha256`, `sntrup761x25519-sha512`, `curve25519-sha256` |
| Ciphers | `chacha20-poly1305`, `aes256-gcm` |
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

## Building

```bash
docker build -t ssh-tunnel .
```

## License

MIT
