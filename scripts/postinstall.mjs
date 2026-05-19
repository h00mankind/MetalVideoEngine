/**
 * Postinstall: download the prebuilt `mve` binary from the GitHub
 * Release matching this package's version, extract it to `bin/mve`,
 * and mark it executable.
 *
 * Skips silently on any non-(darwin, arm64) host. The package's
 * package.json declares `os`/`cpu` so npm already refuses to install
 * on other platforms, but the skip is defence in depth.
 *
 * Skips on `npm install --ignore-scripts` (npm doesn't run this file
 * at all in that mode — nothing to do here).
 *
 * Honoured env vars:
 *   MVE_SKIP_DOWNLOAD=1   — don't download. Used by CI that supplies
 *                           the binary out of band, or when the user
 *                           has set MVE_BIN to a system-wide install.
 */
import { createWriteStream, existsSync } from 'node:fs';
import { mkdir, chmod, rename, rm } from 'node:fs/promises';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { readFile } from 'node:fs/promises';

const execFileP = promisify(execFile);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pkgRoot = path.resolve(__dirname, '..');
const binDir = path.join(pkgRoot, 'bin');
const binPath = path.join(binDir, 'mve');

function log(msg) {
  process.stderr.write(`[metal-video-engine] ${msg}\n`);
}

async function main() {
  if (process.env.MVE_SKIP_DOWNLOAD === '1') {
    log('MVE_SKIP_DOWNLOAD=1 — not downloading binary.');
    return;
  }

  if (process.platform !== 'darwin' || process.arch !== 'arm64') {
    log(`Skipping binary download — platform ${process.platform}/${process.arch} not supported (need darwin/arm64).`);
    return;
  }

  const pkg = JSON.parse(await readFile(path.join(pkgRoot, 'package.json'), 'utf8'));
  const tag = `v${pkg.version}`;
  const assetName = `mve-${tag}-darwin-arm64.zip`;
  const url = `https://github.com/h00mankind/MetalVideoEngine/releases/download/${tag}/${assetName}`;

  log(`Downloading ${assetName} from ${url}`);

  await mkdir(binDir, { recursive: true });

  const tmpZip = path.join(os.tmpdir(), `mve-postinstall-${process.pid}.zip`);
  const tmpExtractDir = path.join(os.tmpdir(), `mve-postinstall-${process.pid}.d`);

  try {
    const res = await fetch(url, { redirect: 'follow' });
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} ${res.statusText} for ${url}`);
    }
    await pipeline(Readable.fromWeb(res.body), createWriteStream(tmpZip));

    await mkdir(tmpExtractDir, { recursive: true });
    // unzip is part of the macOS base system; this avoids pulling a
    // dependency just for one zip per install.
    await execFileP('unzip', ['-q', '-o', tmpZip, '-d', tmpExtractDir]);

    const extracted = path.join(tmpExtractDir, 'mve');
    if (!existsSync(extracted)) {
      throw new Error(`zip did not contain expected file 'mve' — got: ${tmpExtractDir}`);
    }

    await rename(extracted, binPath);
    await chmod(binPath, 0o755);

    log(`Installed ${binPath}`);
  } catch (err) {
    log(`Binary download failed: ${err?.message ?? err}`);
    log('You can still build from source: `swift build -c release` in a checkout of github.com/h00mankind/MetalVideoEngine, then set MVE_BIN=<path>.');
    // Don't fail the install — the package is still useful if the
    // consumer overrides MVE_BIN. Exiting non-zero would block any
    // `npm install` that includes this as a transitive dep.
  } finally {
    await rm(tmpZip, { force: true });
    await rm(tmpExtractDir, { recursive: true, force: true });
  }
}

main().catch((err) => {
  log(`unexpected error: ${err?.stack ?? err}`);
});
