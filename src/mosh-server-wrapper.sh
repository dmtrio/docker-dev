#!/bin/bash
# mosh-server wrapper — installed as /usr/local/bin/mosh-server, which
# precedes /usr/bin on PATH, so the `mosh-server new ...` command that the
# mosh client launches over SSH resolves here. Pins the server to the UDP
# range the firewall accepts and the compose overlay publishes; a client
# cannot land on an unreachable port. Appended -p wins over any client-sent
# -p (mosh-server takes the last occurrence).
exec /usr/bin/mosh-server "$@" -p "${MOSH_PORTS:-60000:60010}"
