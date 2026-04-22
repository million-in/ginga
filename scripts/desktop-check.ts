import { mkdir, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { candidateBinaryPaths } from './electron-bridge';

const moduleDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(moduleDir, '..');
const desktopOutDir = path.join(repoRoot, 'electron', 'dist');

async function readText(relativePath: string): Promise<string> {
  const absolutePath = path.join(repoRoot, relativePath);
  return readFile(absolutePath, 'utf8');
}

async function buildDesktop(outDir: string): Promise<void> {
  await rm(outDir, { force: true, recursive: true });
  await mkdir(outDir, { recursive: true });

  const nodeResult = await Bun.build({
    entrypoints: [
      path.join(repoRoot, 'electron', 'main.ts'),
      path.join(repoRoot, 'electron', 'preload.ts')
    ],
    outdir: outDir,
    target: 'node',
    format: 'cjs',
    external: ['electron']
  });

  if (!nodeResult.success) {
    const message = nodeResult.logs
      .map((log) => log.message)
      .filter(Boolean)
      .join('\n');
    throw new Error(message || `Failed to build Electron Node sources into ${outDir}`);
  }

  const rendererResult = await Bun.build({
    entrypoints: [path.join(repoRoot, 'electron', 'renderer.ts')],
    outdir: outDir,
    target: 'browser',
    format: 'iife'
  });

  if (!rendererResult.success) {
    const message = rendererResult.logs
      .map((log) => log.message)
      .filter(Boolean)
      .join('\n');
    throw new Error(message || `Failed to build Electron renderer into ${outDir}`);
  }
}

async function validateBootstrap(outDir: string): Promise<void> {
  const [packageJson, indexHtml] = await Promise.all([
    readText('package.json'),
    readText('electron/index.html')
  ]);

  const parsed = JSON.parse(packageJson) as { main?: string };
  if (parsed.main !== 'electron/dist/main.js') {
    throw new Error('package.json main must point to electron/dist/main.js');
  }

  if (!indexHtml.includes('./dist/renderer.js')) {
    throw new Error('electron/index.html must load ./dist/renderer.js');
  }

  const distMain = await readFile(path.join(outDir, 'main.js'), 'utf8');
  const distPreload = await readFile(path.join(outDir, 'preload.js'), 'utf8');
  if (distMain.includes('import.meta.require') || distPreload.includes('import.meta.require')) {
    throw new Error('Electron main/preload bundles must be emitted as Node/CommonJS, not Bun ESM');
  }

  if (
    distMain.includes('node_modules/electron/index.js') ||
    distPreload.includes('node_modules/electron/index.js')
  ) {
    throw new Error('Electron main/preload bundles must externalize the electron runtime module');
  }
}

async function main(): Promise<void> {
  const mode = process.argv[2] ?? 'check';
  const outDir = mode === 'build' ? desktopOutDir : path.join(os.tmpdir(), 'ginga-desktop-check');

  await buildDesktop(outDir);
  await validateBootstrap(outDir);

  const candidates = candidateBinaryPaths();
  const repoBinary = path.join(repoRoot, 'zig-out', 'bin', 'ginga');
  const globalHomebrewBinary = '/opt/homebrew/bin/ginga';

  if (candidates.indexOf(repoBinary) === -1) {
    throw new Error('electron bridge must include the repo-local zig-out/bin/ginga candidate');
  }
  if (
    candidates.indexOf(globalHomebrewBinary) !== -1 &&
    candidates.indexOf(repoBinary) > candidates.indexOf(globalHomebrewBinary)
  ) {
    throw new Error('electron bridge must prefer the repo-local binary before the global Homebrew install');
  }

  process.stdout.write(`desktop sources OK (${mode})\n`);
}

main().catch((error: unknown) => {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
});
