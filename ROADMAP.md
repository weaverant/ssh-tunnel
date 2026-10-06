# Roadmap

## 0.2.0: opt-in ML-DSA host and user keys

- [ ] Bake in a second `HostKey` line and allow `ssh-mldsa44-ed25519` next to `ssh-ed25519` in
  `HostKeyAlgorithms` and `PubkeyAcceptedAlgorithms`; add an ML-DSA case to `tests/smoke.sh` and
  document the optional mount. Tried by hand on 10.6p1 (2026-10-06, not in the smoke test yet):
  an unmounted `HostKey` only logs "Unable to load host key"; with both keys mounted clients
  still pick ED25519 (their own preference order); a client without ML-DSA support is refused
  once the ED25519 host key is removed, so check the clients in use before removing it.
