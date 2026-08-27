#!/bin/sh
#
# End-to-end smoke test for the ssh-tunnel image.
#
#   ./tests/smoke.sh                              build from this tree and test
#   IMAGE=ghcr.io/weaverant/ssh-tunnel:0.1.5 ./tests/smoke.sh    test a published image
#
# Spins up three containers on a private network -- an nginx backend, the
# ssh-tunnel image under test, and an SSH client -- then forwards a port
# through the tunnel and fetches the backend through it. Needs docker only.

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
FAILED=0

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILED=1; }

cleanup() {
	docker rm -f "$WEB" "$SRV" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
	rm -rf "$WORK"
}
trap cleanup EXIT
cleanup

# ---------------------------------------------------------------- build/setup

if [ -z "$IMAGE" ]; then
	IMAGE=ssh-tunnel:smoke
	echo "=== building $IMAGE from this tree ==="
	docker build -q -t "$IMAGE" . >/dev/null
else
	echo "=== testing published image $IMAGE ==="
	docker pull -q "$IMAGE" >/dev/null
fi

mkdir -p "$WORK"
ssh-keygen -t ed25519 -f "$WORK/host_key" -N "" -q
ssh-keygen -t ed25519 -f "$WORK/client_key" -N "" -q
cp "$WORK/client_key.pub" "$WORK/authorized_keys"

# Keys are baked in rather than bind-mounted: sshd's StrictModes rejects the
# 0777 that Docker Desktop reports for Windows bind mounts.
cat > "$WORK/Dockerfile.server" <<EOF
FROM $IMAGE
COPY --chmod=0600 host_key /etc/ssh/host_keys/ssh_host_ed25519_key
COPY --chmod=0644 authorized_keys /etc/ssh/authorized_keys
EOF

cat > "$WORK/Dockerfile.client" <<'EOF'
FROM alpine:edge
RUN apk add --no-cache --upgrade openssh-client
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
COPY --chmod=0600 client_key /root/.ssh/id_ed25519
EOF

docker build -q -f "$WORK/Dockerfile.server" -t ssh-tunnel-smoke-server "$WORK" >/dev/null
docker build -q -f "$WORK/Dockerfile.client" -t ssh-tunnel-smoke-client "$WORK" >/dev/null

docker network create "$NET" >/dev/null
docker run -d --name "$WEB" --network "$NET" nginx:alpine >/dev/null

# Same hardening as docker-compose.yml
docker run -d --name "$SRV" --network "$NET" \
	--read-only --tmpfs /run --tmpfs /tmp \
	--security-opt no-new-privileges:true \
	--cap-drop ALL \
	--cap-add SETUID --cap-add SETGID --cap-add SYS_CHROOT --cap-add DAC_OVERRIDE \
	ssh-tunnel-smoke-server >/dev/null

i=0
while [ $i -lt 30 ]; do
	docker logs "$SRV" 2>&1 | grep -q "Server listening" && break
	i=$((i + 1))
	sleep 1
done

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

echo
if [ "$FAILED" -eq 0 ]; then
	echo "All checks passed."
else
	echo "Smoke test FAILED."
	echo "--- sshd log ---"
	docker logs "$SRV" 2>&1 | tail -20
fi
exit "$FAILED"
