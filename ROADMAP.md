# Roadmap

- [ ] Decide whether the `0.1` line gets further OpenSSH updates or ends at 0.1.6. Until then
  new releases go to `0.2` only.
- [ ] With the next release: `softprops/action-gh-release@v2` to `@v3` in
  `.github/workflows/build.yml`. v2 targets Node.js 20, which GitHub now forces onto
  Node.js 24 with a warning (v0.2.1 build, 2026-11-05). v3.0.0 changes only the runtime.
  Only a tag push can test it, so that release's build is the first run.
- [x] 0.2.1 (2026-11-05): OpenSSH 10.6p2, and `authorized_keys` read from a mounted
  `user_keys` directory, so a replaced file takes effect without a restart. The single-file
  mount still works with the old restart caveat. See "Configuration" in the README.
- [x] 0.2.0 (2026-10-06): opt-in `ssh-mldsa44-ed25519` host and user keys, `ssh-keygen` in the
  image, host key directory mount. See "Post-quantum authentication (ML-DSA)" in the README.
