#!/bin/zsh

set -e

# Build and install
make clean && make CXXFLAGS="-DOLD_ACTIVATION_METHOD -DEXPERIMENTAL_FOCUS_FIRST" && make install

# Check if AutoRaise is running before attempting to kill it
if pgrep -x "AutoRaise" >/dev/null 2>&1; then
  echo "AutoRaise is running — killing process..."
  killall AutoRaise
  sleep 1
else
  echo "AutoRaise is not running."
fi

# Remove Accessibility permission entry for the app (macOS)
BUNDLE_ID="nl.postware.autoraise"
if command -v tccutil >/dev/null 2>&1; then
  echo "Resetting Accessibility permission for ${BUNDLE_ID}..."
  tccutil reset Accessibility "$BUNDLE_ID" || echo "tccutil failed; you may need to reset the permission manually in System Settings > Privacy & Security."
else
  echo "tccutil not available; please remove the Accessibility permission for ${BUNDLE_ID} manually."
fi
