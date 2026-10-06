#!/bin/sh
#
# End-to-end smoke test for the ssh-tunnel image.
#
#   ./tests/smoke.sh                              build from this tree and test
#   IMAGE=ghcr.io/weaverant/ssh-tunnel:0.2.0 ./tests/smoke.sh    test a published image
#
# Spins up an nginx backend, the ssh-tunnel image under test (twice: with and
# without an ML-DSA host key) and an SSH client on a private network, then
# forwards a port through the tunnel and fetches the backend through it.
# Needs docker only.

set -e

cd "$(dirname "$0")/.."

# Git Bash mangles leading-slash arguments (--entrypoint /sbin/nologin becomes a
# C:/Program Files/Git/... path). Everything below uses relative build contexts,
# so disabling the translation is safe here.
export MSYS_NO_PATHCONV=1

WORK=tests/temp/smoke
NET=ssh-tunnel-smoke-net
WEB=ssh-tunnel-smoke-web
SRV=ssh-tunnel-smoke-sshd
SRV2=ssh-tunnel-smoke-sshd-mldsa
KG=ssh-tunnel-smoke-keygen
FAILED=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILED=1; }

cleanup() {
	docker rm -f "$WEB" "$SRV" "$SRV2" "$KG" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT
cleanup

# ---------------------------------------------------------------- build/setup

if [ -z "$IMAGE" ]; then
	IMAGE=ssh-tunnel:smoke
	echo "=== building $IMAGE from this tree ==="
	# No layer cache: the Dockerfile's apk line never changes, so a cached layer
	# keeps serving whatever OpenSSH Alpine edge had when it was first built.
	docker build -q --pull --no-cache -t "$IMAGE" . >/dev/null
else
	echo "=== testing published image $IMAGE ==="
	docker pull -q "$IMAGE" >/dev/null
fi

mkdir -p "$WORK"
ssh-keygen -t ed25519 -f "$WORK/host_key" -N "" -q
ssh-keygen -t ed25519 -f "$WORK/client_key" -N "" -q

# The ML-DSA keys are made inside the client image: the host's ssh-keygen may
# predate OpenSSH 10.6, the first release with the final key format.
cat > "$WORK/Dockerfile.client" <<'EOF'
FROM alpine:edge
RUN apk add --no-cache --upgrade openssh-client openssh-keygen
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
COPY --chmod=0600 client_key /root/.ssh/id_ed25519
RUN ssh-keygen -q -t mldsa44-ed25519 -N "" -f /root/mldsa_client_key && \
    ssh-keygen -q -t mldsa44-ed25519 -N "" -f /root/mldsa_host_key
EOF

# Uncached for the same reason as the image build above
docker build -q --pull --no-cache -f "$WORK/Dockerfile.client" -t ssh-tunnel-smoke-client "$WORK" >/dev/null
docker run --rm ssh-tunnel-smoke-client cat /root/mldsa_host_key > "$WORK/mldsa_host_key"
docker run --rm ssh-tunnel-smoke-client cat /root/mldsa_client_key.pub > "$WORK/mldsa_client_key.pub"
cat "$WORK/client_key.pub" "$WORK/mldsa_client_key.pub" > "$WORK/authorized_keys"

# The image carries ssh-keygen so host keys can be made without tooling on the
# host. If it works, its key replaces the one from the client image, so the
# ML-DSA server below runs on a key made the documented way. docker cp rather
# than a bind mount keeps this independent of the host's path conventions.
KEYGEN_OK=no
docker create --name "$KG" --entrypoint /usr/bin/ssh-keygen "$IMAGE" \
	-q -t mldsa44-ed25519 -N "" -f /tmp/key >/dev/null 2>&1 || true
docker start -a "$KG" >/dev/null 2>&1 || true
if docker cp "$KG:/tmp/key" "$WORK/keygen_key" >/dev/null 2>&1 &&
	grep -q "BEGIN OPENSSH PRIVATE KEY" "$WORK/keygen_key"; then
	KEYGEN_OK=yes
	cp "$WORK/keygen_key" "$WORK/mldsa_host_key"
fi
docker rm -f "$KG" >/dev/null 2>&1 || true

# Keys are baked in rather than bind-mounted: sshd's StrictModes rejects the
# 0777 that Docker Desktop reports for Windows bind mounts. Two servers: one
# with only the ED25519 host key, as every deployment before ML-DSA has it,
# and one that also has the ML-DSA host key.
cat > "$WORK/Dockerfile.server" <<EOF
FROM $IMAGE
COPY --chmod=0600 host_key /etc/ssh/host_keys/ssh_host_ed25519_key
COPY --chmod=0644 authorized_keys /etc/ssh/authorized_keys
EOF

cat > "$WORK/Dockerfile.server-mldsa" <<'EOF'
FROM ssh-tunnel-smoke-server
COPY --chmod=0600 mldsa_host_key /etc/ssh/host_keys/ssh_host_mldsa44_ed25519_key
EOF

docker build -q -f "$WORK/Dockerfile.server" -t ssh-tunnel-smoke-server "$WORK" >/dev/null
docker build -q -f "$WORK/Dockerfile.server-mldsa" -t ssh-tunnel-smoke-server-mldsa "$WORK" >/dev/null

docker network create "$NET" >/dev/null
docker run -d --name "$WEB" --network "$NET" nginx:alpine >/dev/null

# Same hardening as docker-compose.yml
start_server() {
	docker run -d --name "$1" --network "$NET" \
		--read-only --tmpfs /run --tmpfs /tmp \
		--security-opt no-new-privileges:true \
		--cap-drop ALL \
		--cap-add SETUID --cap-add SETGID --cap-add SYS_CHROOT --cap-add DAC_OVERRIDE \
		"$2" >/dev/null
	i=0
	while [ $i -lt 30 ]; do
		docker logs "$1" 2>&1 | grep -q "Server listening" && break
		i=$((i + 1))
		sleep 1
	done
}
start_server "$SRV" ssh-tunnel-smoke-server
start_server "$SRV2" ssh-tunnel-smoke-server-mldsa

echo

# ---------------------------------------------------------------------- tests

VERSION=$(docker run --rm --entrypoint /usr/sbin/sshd "$IMAGE" -V 2>&1 || true)
case "$VERSION" in
OpenSSH_*) pass "sshd reports a version: $VERSION" ;;
*) fail "sshd -V returned: $VERSION" ;;
esac

# Regression test: Alpine's /sbin/nologin is a symlink to /bin/busybox, and a
# dereferencing cp put the whole multi-call binary -- shell included -- into the
# image through v0.1.3.
NOLOGIN=$(docker run --rm --entrypoint /sbin/nologin "$IMAGE" --help 2>&1 || true)
case "$NOLOGIN" in
*BusyBox* | *busybox*) fail "/sbin/nologin is busybox: $NOLOGIN" ;;
*"This account is not available"*) pass "/sbin/nologin is the static stub" ;;
*) fail "/sbin/nologin behaved unexpectedly: $NOLOGIN" ;;
esac

TUNNEL=$(docker run --rm --network "$NET" ssh-tunnel-smoke-client sh -c "
	ssh -p 2222 -f -N -L 8080:$WEB:80 \
	    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    -o ExitOnForwardFailure=yes \
	    tunnel@$SRV
	sleep 2
	wget -qS -O /dev/null http://127.0.0.1:8080/ 2>&1
" 2>&1 || true)
case "$TUNNEL" in
*"200 OK"*) pass "port forward reaches the backend" ;;
*) fail "port forward failed: $(echo "$TUNNEL" | tr '\n' ' ')" ;;
esac

SHELL_OUT=$(docker run --rm --network "$NET" ssh-tunnel-smoke-client sh -c "
	ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    tunnel@$SRV 'id' 2>&1
" 2>&1 || true)
case "$SHELL_OUT" in
*uid=*) fail "shell session returned command output: $SHELL_OUT" ;;
*"This account is not available"*) pass "shell session refused" ;;
*) fail "shell session behaved unexpectedly: $SHELL_OUT" ;;
esac

# ML-DSA, the hybrid post-quantum signature type of OpenSSH 10.6. $SRV has no
# ML-DSA host key, so the tests above already show a missing one is not fatal.
MLDSA_USER=$(docker run --rm --network "$NET" ssh-tunnel-smoke-client sh -c "
	ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    -o IdentitiesOnly=yes -i /root/mldsa_client_key \
	    tunnel@$SRV 'id' 2>&1
" 2>&1 || true)
case "$MLDSA_USER" in
*"This account is not available"*) pass "ML-DSA user key accepted" ;;
*) fail "ML-DSA user key not accepted: $(echo "$MLDSA_USER" | tr '\n' ' ')" ;;
esac

MLDSA_HOST=$(docker run --rm --network "$NET" ssh-tunnel-smoke-client sh -c "
	ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	    -o HostKeyAlgorithms=ssh-mldsa44-ed25519 \
	    tunnel@$SRV2 'id' 2>&1
" 2>&1 || true)
case "$MLDSA_HOST" in
*"This account is not available"*) pass "ML-DSA host key served" ;;
*) fail "ML-DSA host key not served: $(echo "$MLDSA_HOST" | tr '\n' ' ')" ;;
esac

if [ "$KEYGEN_OK" = yes ]; then
	pass "ssh-keygen in the image made the ML-DSA host key"
else
	fail "ssh-keygen in the image did not produce an ML-DSA key"
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "All checks passed."
else
	echo "Smoke test FAILED."
	echo "--- sshd log ---"
	docker logs "$SRV" 2>&1 | tail -20
fi
exit "$FAILED"
