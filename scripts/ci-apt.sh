#!/bin/bash
# Install apt packages on the CI runner, surviving one mirror being down: Ubuntu's own servers first (as the runner is
# set up), then other full mirrors. apt checks Ubuntu's signature on every package, so any full mirror is as safe.
# (2026-11-11 the runners couldn't resolve Ubuntu's servers; 2026-11-14 kernel.org's mirror refused connections.)
# Usage: scripts/ci-apt.sh lua5.1 liblua5.1-0-dev luarocks zip
set -u
MIRRORS="default http://azure.archive.ubuntu.com/ubuntu/ http://mirrors.edge.kernel.org/ubuntu/ http://mirrors.mit.edu/ubuntu/ http://mirror.math.princeton.edu/pub/ubuntu/"
APT="sudo apt-get -o Acquire::Retries=3 -o Acquire::ForceIPv4=true -o Acquire::http::Timeout=20"
for m in $MIRRORS; do
  if [ "$m" != "default" ]; then
    echo "apt: trying mirror $m"
    for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list; do
      if [ -f "$f" ]; then
        sudo sed -i -E "s#mirror\+file:/etc/apt/apt-mirrors\.txt#$m#g; s#https?://[a-z0-9.-]+(/pub)?/ubuntu/?( |\$)#$m\2#g" "$f"
      fi
    done
  fi
  if $APT update -qq && $APT install -y -qq "$@"; then
    exit 0
  fi
done
echo "apt: every mirror failed" >&2
exit 1
