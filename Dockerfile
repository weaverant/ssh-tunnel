# Stage 1: Gather sshd and its runtime dependencies
FROM alpine:edge AS builder

RUN apk add --no-cache openssh-server

# Build the minimal filesystem
RUN mkdir -p /jail/etc/ssh/host_keys \
             /jail/home/tunnel/.ssh \
             /jail/var/empty \
             /jail/run \
             /jail/sbin \
             /jail/usr/sbin \
             /jail/lib \
             /jail/tmp && \
    # Copy binaries (OpenSSH 10.x splits sshd into three)
    cp /usr/sbin/sshd /jail/usr/sbin/ && \
    mkdir -p /jail/usr/lib/ssh && \
    cp /usr/lib/ssh/sshd-session /jail/usr/lib/ssh/ && \
    cp /usr/lib/ssh/sshd-auth /jail/usr/lib/ssh/ && \
    cp /sbin/nologin /jail/sbin/ && \
    # Copy shared library dependencies for all binaries
    for bin in /usr/sbin/sshd /usr/lib/ssh/sshd-session /usr/lib/ssh/sshd-auth /sbin/nologin; do \
      ldd "$bin" 2>/dev/null | awk '/=>/ {print $3}' | while read lib; do \
        if [ -n "$lib" ] && [ -f "$lib" ]; then \
          dir=$(dirname "$lib"); \
          mkdir -p "/jail$dir"; \
          cp -nL "$lib" "/jail$dir/"; \
        fi; \
      done; \
    done && \
    # Copy musl dynamic linker
    cp /lib/ld-musl-*.so.1 /jail/lib/ && \
    # Minimal passwd/group - three users: root, sshd (privsep), tunnel
    echo "root:x:0:0:root:/:/sbin/nologin"                          > /jail/etc/passwd && \
    echo "sshd:x:65534:65534:sshd privsep:/var/empty:/sbin/nologin" >> /jail/etc/passwd && \
    echo "tunnel:x:1000:1000:tunnel:/home/tunnel:/sbin/nologin"     >> /jail/etc/passwd && \
    echo "root:x:0:"    > /jail/etc/group && \
    echo "sshd:x:65534:" >> /jail/etc/group && \
    echo "tunnel:x:1000:" >> /jail/etc/group && \
    # Permissions
    chmod 755 /jail/var/empty && \
    chown root:root /jail/var/empty && \
    chmod 700 /jail/home/tunnel/.ssh && \
    chown 1000:1000 /jail/home/tunnel/.ssh

# Stage 2: Distroless runtime
FROM scratch

COPY --from=builder /jail /
COPY sshd_config /etc/ssh/sshd_config

EXPOSE 2222

ENTRYPOINT ["/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_config"]
