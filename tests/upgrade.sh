#!/bin/sh
#
# Upgrade test: the previous release in its old compose layout, then the new
# image on the same files, then the README migration to the user_keys directory.
#
#   ./tests/upgrade.sh                                         new image built from this tree
#   NEW=ghcr.io/weaverant/ssh-tunnel:0.2.1 ./tests/upgrade.sh   new image is a published one
#   OLD=ghcr.io/weaverant/ssh-tunnel:0.2.0 ./tests/upgrade.sh   old image, default :latest
#
# OLD must be 0.2.0 or newer (ML-DSA keys). Run it before tagging, while :latest
# is still the previous release. The project directory lives on the Docker host
# (inside the VM on Docker Desktop), so the bind mounts carry the Linux owners
# and modes that sshd checks; a Windows bind mount reports 0777. Compose runs in
# a docker:cli container on the docker socket. Needs docker only.

set -e

cd "$(dirname "$0")/.."

# Git Bash would rewrite the /var/tmp and socket paths below into C:/... paths.
export MSYS_NO_PATHCONV=1

OLD=${OLD:-ghcr.io/weaverant/ssh-tunnel:latest}
P=/var/tmp/ssh-tunnel-upgrade
PROJ=ssh-tunnel-upgrade
CL=ssh-tunnel-upgrade-client

cleanup() {
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v "$P:$P" -w "$P" \
		docker:cli compose -p "$PROJ" down >/dev/null 2>&1 || true
	docker run --rm -v "$P:$P" alpine:edge sh -c "rm -rf $P/*" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

if [ -z "$NEW" ]; then
	NEW=ssh-tunnel:upgrade
	echo "=== building $NEW from this tree ==="
	# Uncached, for the same reason as in smoke.sh: the apk layer never changes.
	docker build -q --pull --no-cache -t "$NEW" . >/dev/null
else
	docker pull -q "$NEW" >/dev/null
fi
docker pull -q "$OLD" >/dev/null
docker pull -q docker:cli >/dev/null
echo "=== upgrade from $OLD to $NEW ==="

# Client with one ED25519 and one ML-DSA user key. No build context needed.
docker build -q --pull --no-cache -t "$CL" - >/dev/null <<'DOCKERFILE'
FROM alpine:edge
RUN apk add --no-cache --upgrade openssh-client openssh-keygen
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
    ssh-keygen -q -t ed25519 -N "" -f /root/.ssh/id_ed25519 && \
    ssh-keygen -q -t mldsa44-ed25519 -N "" -f /root/mldsa_client_key
DOCKERFILE

# The old layout: host key directory, single authorized_keys owned by uid 1000.
docker run --rm -i -v "$P:$P" -w "$P" "$CL" sh -s <<'SETUP'
set -e
mkdir host_keys
ssh-keygen -q -t ed25519 -N "" -f host_keys/ssh_host_ed25519_key
ssh-keygen -q -t mldsa44-ed25519 -N "" -f host_keys/ssh_host_mldsa44_ed25519_key
{ ssh-keygen -y -f /root/.ssh/id_ed25519; ssh-keygen -y -f /root/mldsa_client_key; } > authorized_keys
chown 1000:1000 authorized_keys
chmod 644 authorized_keys
SETUP

echo

set +e
docker run --rm -i -v /var/run/docker.sock:/var/run/docker.sock -v "$P:$P" -w "$P" \
	-e OLD="$OLD" -e NEW="$NEW" -e PROJ="$PROJ" -e CL="$CL" \
	docker:cli sh -s <<'INNER'
FAILED=0
pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; FAILED=1; }

ED=/root/.ssh/id_ed25519
ML=/root/mldsa_client_key

login() { # $1 = key path in the client image
	docker run --rm --network "${PROJ}_default" "$CL" ssh -p 2222 \
		-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o IdentitiesOnly=yes -o LogLevel=ERROR -i "$1" tunnel@ssh-tunnel id 2>&1
}
# ForceCommand is nologin, so a successful login prints its message.
accepted() { # $1 = label, $2 = key
	out=$(login "$2")
	case "$out" in
	*"This account is not available"*) pass "$1" ;;
	*) fail "$1: $(echo "$out" | tr '\n' ' ')" ;;
	esac
}
refused() {
	out=$(login "$2")
	case "$out" in
	*"Permission denied"*) pass "$1" ;;
	*) fail "$1: $(echo "$out" | tr '\n' ' ')" ;;
	esac
}
fingerprints() {
	docker run --rm --network "${PROJ}_default" "$CL" sh -c \
		'ssh-keyscan -p 2222 ssh-tunnel 2>/dev/null | ssh-keygen -lf - | sort'
}
compose_file() { # $1 = image, $2 = authorized_keys mount
	cat > docker-compose.yml <<YML
services:
  ssh-tunnel:
    image: $1
    volumes:
      - ./host_keys:/etc/ssh/host_keys:ro
      - $2
    read_only: true
    tmpfs:
      - /run
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - SETUID
      - SETGID
      - SYS_CHROOT
      - DAC_OVERRIDE
YML
}
up() {
	docker compose -p "$PROJ" up -d >/dev/null 2>&1
	wait_listening
}
# A restart clears sshd's per-source penalties, which the refused logins of
# the previous step would otherwise turn into dropped connections.
restart() {
	docker compose -p "$PROJ" restart >/dev/null 2>&1
	wait_listening
}
wait_listening() {
	i=0
	while [ $i -lt 30 ]; do
		docker compose -p "$PROJ" logs --since 30s 2>&1 | grep -q "Server listening" && return
		i=$((i + 1))
		sleep 1
	done
}

OLD_MOUNT=./authorized_keys:/etc/ssh/authorized_keys:ro
NEW_MOUNT=./user_keys:/etc/ssh/user_keys:ro

compose_file "$OLD" "$OLD_MOUNT"
up
accepted "old image, old layout: ED25519 user key" "$ED"
accepted "old image, old layout: ML-DSA user key" "$ML"
FP_OLD=$(fingerprints)

compose_file "$NEW" "$OLD_MOUNT"
up
accepted "new image, old layout unchanged: ED25519 user key" "$ED"
accepted "new image, old layout unchanged: ML-DSA user key" "$ML"
FP_NEW=$(fingerprints)
if [ -n "$FP_OLD" ] && [ "$FP_OLD" = "$FP_NEW" ]; then
	pass "host key fingerprints unchanged by the upgrade"
else
	fail "host key fingerprints changed: [$FP_OLD] -> [$FP_NEW]"
fi

# The migration as the README describes it
mkdir user_keys && chmod 755 user_keys && mv authorized_keys user_keys/
compose_file "$NEW" "$NEW_MOUNT"
up
accepted "migrated to user_keys: ED25519 user key" "$ED"
accepted "migrated to user_keys: ML-DSA user key" "$ML"

# Replace the file the way an editor does, without the ED25519 key
grep '^ssh-mldsa44-ed25519 ' user_keys/authorized_keys > user_keys/new
chown 1000:1000 user_keys/new && chmod 644 user_keys/new
mv user_keys/new user_keys/authorized_keys
refused "replaced file, no restart: removed ED25519 key refused" "$ED"
accepted "replaced file, no restart: kept ML-DSA key accepted" "$ML"

# The permission rules the README states
chmod 775 user_keys; restart
refused "user_keys 0775 refused" "$ML"
chmod 755 user_keys; chown 1001:1001 user_keys; restart
refused "user_keys owned by uid 1001 refused" "$ML"
chown 1000:1000 user_keys; restart
accepted "user_keys 0755 owned by uid 1000 accepted" "$ML"
chown 0:0 user_keys; restart
accepted "user_keys 0755 owned by root accepted" "$ML"

if [ "$FAILED" -ne 0 ]; then
	echo "--- sshd log ---"
	docker compose -p "$PROJ" logs --no-log-prefix 2>&1 | tail -20
fi
exit "$FAILED"
INNER
FAILED=$?
set -e

echo
if [ "$FAILED" -eq 0 ]; then
	echo "All checks passed."
else
	echo "Upgrade test FAILED."
fi
exit "$FAILED"
