/*
 * Minimal nologin: refuse the login, exit non-zero.
 *
 * Alpine's /sbin/nologin is a symlink to /bin/busybox, so copying it into the
 * jail would place a complete multi-call binary -- a shell, nc, wget and some
 * 400 other applets -- inside an image whose whole claim is that it has none.
 * Built statically so the jail needs no libraries for it either.
 */

#include <unistd.h>

int
main(void)
{
	static const char msg[] = "This account is not available\n";

	(void)write(STDERR_FILENO, msg, sizeof(msg) - 1);
	return 1;
}
