#!/usr/bin/env node

// Runs the prebuilt native binary for this machine. The binaries are the
// release assets, shipped in dist/ under the same names.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const platforms = { linux: "linux", darwin: "macos", win32: "windows" };
// Windows on ARM runs the x64 binary under emulation.
const architectures = { x64: "amd64", arm64: process.platform === "win32" ? "amd64" : "arm64" };

const platform = platforms[process.platform];
const architecture = architectures[process.arch];
const extension = process.platform === "win32" ? ".exe" : "";
const binary =
  platform && architecture &&
  fileURLToPath(
    new URL(`../dist/nimver-${platform}-${architecture}${extension}`, import.meta.url),
  );

if (!binary || !existsSync(binary)) {
  process.stderr.write(
    `nimver: no prebuilt binary for ${process.platform}-${process.arch}.\n` +
      "Build it from source with `nimble install nimver`, or see https://github.com/vinpogo/nimver/releases\n",
  );
  process.exit(1);
}

const run = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (run.error) {
  process.stderr.write(`nimver: could not run ${binary}: ${run.error.message}\n`);
  process.exit(1);
}
if (run.signal) {
  process.kill(process.pid, run.signal);
}
process.exit(run.status ?? 1);
