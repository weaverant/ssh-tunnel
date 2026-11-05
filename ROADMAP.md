# Roadmap

- [ ] Decide whether the `0.1` line gets further OpenSSH updates or ends at 0.1.6. Until then
  new releases go to `0.2` only.
- [x] 0.2.1 (2026-11-05): OpenSSH 10.6p2, and `authorized_keys` read from a mounted
  `user_keys` directory, so a replaced file takes effect without a restart. The single-file
  mount still works with the old restart caveat. See "Configuration" in the README.
- [x] 0.2.0 (2026-10-06): opt-in `ssh-mldsa44-ed25519` host and user keys, `ssh-keygen` in the
  image, host key directory mount. See "Post-quantum authentication (ML-DSA)" in the README.
