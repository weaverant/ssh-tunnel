# Roadmap

## 0.2.0: opt-in ML-DSA host and user keys

- [ ] Opt-in `ssh-mldsa44-ed25519` host and user keys: a second `HostKey` line, both types in
  `HostKeyAlgorithms` and `PubkeyAcceptedAlgorithms`, an ML-DSA case in `tests/smoke.sh`. Local
  builds only for now; how to publish and announce it is still open. Tried by hand 2026-10-06
  with 10.6p1 clients on Linux and Windows: login, forwarding and host key rotation work, and an
  unmounted `HostKey` only logs an error. Traps: clients keep picking ED25519 while both host
  keys are mounted, and a client without ML-DSA is refused once the ED25519 key is gone.
