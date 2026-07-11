# Security Policy

Report vulnerabilities through GitHub private vulnerability reporting.

LocalWrap launches only allowlisted developer tools without a shell. It is
hardened but intentionally not sandboxed because it operates on user-selected
repositories. Preview and browser navigation require explicit-port HTTP(S)
loopback URLs. Migration is copy-only, and corrupt native stores are preserved
before recovery.

Published macOS artifacts must omit `get-task-allow`, contain arm64 and x86_64,
pass strict signature verification, be accepted and stapled by Apple, pass
Gatekeeper assessment, and include a SHA-256 checksum.
