/*
 * Misaligned O_DIRECT against a block device or a file on one.  Each case
 * either must be refused with EINVAL or must succeed and read back what was
 * written.  Prints one PASS or FAIL line per case; exits 1 on any FAIL.
 *
 *   dioal <path> <lbs>
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

static int fails;
static const char *path;

static void expect_einval(const char *name, ssize_t r)
{
	if (r < 0 && errno == EINVAL)
		printf("PASS %s %s: EINVAL\n", path, name);
	else {
		printf("FAIL %s %s: got %zd (%s), want EINVAL\n", path, name,
		       r, r < 0 ? strerror(errno) : "no error");
		fails++;
	}
}

int main(int argc, char **argv)
{
	struct iovec iov[3];
	size_t lbs, len;
	char *buf, *chk;
	ssize_t r;
	int fd;

	if (argc != 3)
		return 2;
	path = argv[1];
	lbs = strtoul(argv[2], NULL, 0);
	len = 4 * lbs;
	fd = open(path, O_RDWR | O_DIRECT);
	if (fd < 0) {
		perror(path);
		return 2;
	}
	if (posix_memalign((void **)&buf, 1 << 21, 1 << 22) ||
	    posix_memalign((void **)&chk, 4096, 1 << 20))
		return 2;
	for (size_t i = 0; i < (1 << 22); i++)
		buf[i] = (char)(i * 7 + 3);

	/* A start address off the DMA alignment. */
	expect_einval("write misaligned address", pwrite(fd, buf + 1, len, 0));
	expect_einval("read misaligned address", pread(fd, buf + 1, len, 0));

	/* A misaligned segment after an aligned one. */
	iov[0].iov_base = buf;            iov[0].iov_len = lbs;
	iov[1].iov_base = buf + 8192 + 1; iov[1].iov_len = len - lbs;
	expect_einval("writev aligned then misaligned", pwritev(fd, iov, 2, 0));

	/* A segment length off the DMA alignment, total still whole blocks. */
	iov[0].iov_base = buf;        iov[0].iov_len = lbs + 3;
	iov[1].iov_base = buf + 8192; iov[1].iov_len = len - lbs - 3;
	expect_einval("writev misaligned length", pwritev(fd, iov, 2, 0));

	/*
	 * Segments that meet the 512-byte DMA alignment but are not whole
	 * pages, in a large folio when THP backs the buffer: valid, and must
	 * come back intact.
	 */
	iov[0].iov_base = buf + 512;          iov[0].iov_len = 3584;
	iov[1].iov_base = buf + 65536 + 1024; iov[1].iov_len = 512;
	iov[2].iov_base = buf + 131072;       iov[2].iov_len = len - 4096;
	r = pwritev(fd, iov, 3, lbs * 8);
	if (r != (ssize_t)len) {
		printf("FAIL %s writev 512-aligned segments: %zd (%s)\n", path,
		       r, r < 0 ? strerror(errno) : "short");
		fails++;
	} else if (pread(fd, chk, len, lbs * 8) != (ssize_t)len ||
		   memcmp(chk, buf + 512, 3584) ||
		   memcmp(chk + 3584, buf + 65536 + 1024, 512) ||
		   memcmp(chk + 4096, buf + 131072, len - 4096)) {
		printf("FAIL %s writev 512-aligned segments: data differs\n", path);
		fails++;
	} else
		printf("PASS %s writev 512-aligned segments: stored intact\n", path);

	memset(chk, 0, len);
	iov[0].iov_base = chk + 512;  iov[0].iov_len = 3584;
	iov[1].iov_base = chk + 8192; iov[1].iov_len = len - 3584;
	r = preadv(fd, iov, 2, lbs * 8);
	if (r != (ssize_t)len || memcmp(chk + 512, buf + 512, 3584) ||
	    memcmp(chk + 8192, buf + 65536 + 1024, 512)) {
		printf("FAIL %s readv 512-aligned segments: %zd\n", path, r);
		fails++;
	} else
		printf("PASS %s readv 512-aligned segments: read back intact\n", path);

	close(fd);
	return fails ? 1 : 0;
}
