# nfsd direct I/O on AlmaLinux 10

Checks whether the AlmaLinux 10 kernel's nfsd can serve NFS READ and WRITE
without filling the server's cache (`/sys/kernel/debug/nfsd/io_cache_read`
and `io_cache_write`), over md RAID0 + XFS and over ZFS.

Loop devices stand in for NVMe and the client is the server itself over
TCP, so the throughput figures are only for comparison between modes.
