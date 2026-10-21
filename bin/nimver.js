#!/usr/bin/env node

// Commit-msg hooks installed by 5.3.0 or earlier call this path, so it stays
// as long as those hooks may be around. Re-running `nimver install-hooks
// --force` points a hook at the native binary instead.

import("./nimver.mjs");
