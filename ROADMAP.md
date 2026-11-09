# Roadmap

- [ ] `make_latest` in the release step is untested. Without it the v0.1.7 backport took the
  GitHub "Latest" badge from v0.2.1 (reset by hand, 2026-11-09). Check the badge after the
  next tag push on each line.
- [x] 0.1.7 (2026-11-09, branch `0.1`): OpenSSH 10.6p2. The `0.1` line gets OpenSSH updates
  as backports on that branch. Its build was the first run of `action-gh-release@v3`, now
  on `main` too.
- [x] 0.2.1 (2026-11-05): OpenSSH 10.6p2, and `authorized_keys` read from a mounted
  `user_keys` directory, so a replaced file takes effect without a restart. The single-file
  mount still works with the old restart caveat. See "Configuration" in the README.
- [x] 0.2.0 (2026-10-06): opt-in `ssh-mldsa44-ed25519` host and user keys, `ssh-keygen` in the
  image, host key directory mount. See "Post-quantum authentication (ML-DSA)" in the README.
