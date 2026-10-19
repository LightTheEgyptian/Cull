#!/bin/bash
cd "$(dirname "$0")"
clear
echo "Building Cull…"
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed. An installer window will open."
  xcode-select --install
  exit 0
fi
/bin/bash ./build.sh 2>&1 | tee build.log
echo
echo "You can close this window."
