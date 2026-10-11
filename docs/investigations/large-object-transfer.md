# Large Nikon object transfers

The iOS streaming path formerly returned a UINT32 cache resume position and added
received byte counts with wrapping arithmetic. At the 4 GiB boundary, that could
append bytes requested from an earlier camera offset while the local file remained
positioned at its true end.

The cache now returns the UINT64 result of `FileHandle.seekToEnd()` on the exact
opened descriptor. The actual streaming caller uses shared
`PTPObjectTransferCursor` and the same native camera session. It validates each
response before writing, advances durable progress after persistence, continues
short nonempty chunks and checks cancellation after a suspended camera read.
Wireless requests retain 1 MiB chunks; USB retains 4 MiB. Ownership and command
admission remain with their existing owners.

The catalog attempts an advertised 64-bit size query for the reserved UINT32
sentinel. A successful known size reaches the shared catalog, legacy row and
playback source. If unavailable, the row remains visible with unknown-size facts.
Camera-dependent unknown/sentinel sizes cannot establish download completion or a
fixed-length progressive asset. Existing nonempty local-only unknown-size rows
remain cached, and a separate removal-only retention fact preserves their operator
metadata without claiming a completed camera download. Unsupported transfer and request failures preserve partial
cache bytes; the existing playback completion path reports an incomplete transfer.
Already corrupted caches are not silently removed or treated as repaired.

The SIMULATED regression suite exercises the actual native session, catalog adapter
and file store, including a sparse file above 4 GiB without a giant allocation.
Hardware verification of the extended operations and actual firmware size reporting
is still pending. This Nikon-specific defect does not establish the cause of any
Pocket clip issue.
