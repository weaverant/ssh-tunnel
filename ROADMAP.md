# Roadmap

- [ ] Decide whether the `0.1` line gets further OpenSSH updates or ends at 0.1.6. Until then
  new releases go to `0.2` only.
- [ ] `authorized_keys` is a single-file mount, so a replaced file is not seen until the
  container restarts (documented in the README). Consider also reading it from a mounted
  directory, which does not have that trap.
- [x] 0.2.0 (2026-10-06): opt-in `ssh-mldsa44-ed25519` host and user keys, `ssh-keygen` in the
  image, host key directory mount. See "Post-quantum authentication (ML-DSA)" in the README.
