import { access } from 'node:fs/promises';
import { constants } from 'node:fs';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const moduleDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(moduleDir, '..');

const candidateBinaryPaths = () => {
  const candidates = [];
  if (process.env.GINGA_BIN) {
    candidates.push(process.env.GINGA_BIN);
  }
  candidates.push(
    path.join(repoRoot, 'zig-out', 'bin', 'ginga'),
    path.join(repoRoot, 'ginga')
  );
  return candidates;
};

async function pathExists(candidate) {
  try {
    await access(candidate, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export async function resolveBinaryPath(explicitPath = '') {
  if (explicitPath) {
    const resolved = path.resolve(explicitPath);
    if (await pathExists(resolved)) {
      return resolved;
    }
    throw new Error(`ginga binary not found at ${resolved}`);
  }

  for (const candidate of candidateBinaryPaths()) {
    if (await pathExists(candidate)) {
      return candidate;
    }
  }

  throw new Error(
    'Unable to locate the ginga binary. Build it first or set GINGA_BIN.'
  );
}

function spawnCommand(binaryPath, args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath, args, {
      cwd: repoRoot,
      env: process.env,
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');

    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });

    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });

    child.on('error', reject);
    child.on('close', (code, signal) => {
      resolve({ code, signal, stdout, stderr });
    });

    if (input !== undefined) {
      child.stdin.write(input);
    }
    child.stdin.end();
  });
}

export function parseJsonPayload(rawOutput) {
  const trimmed = String(rawOutput ?? '').trim();
  if (!trimmed) {
    throw new Error('ginga returned an empty response');
  }

  try {
    return JSON.parse(trimmed);
  } catch {
    const firstBrace = trimmed.indexOf('{');
    const lastBrace = trimmed.lastIndexOf('}');
    if (firstBrace >= 0 && lastBrace > firstBrace) {
      return JSON.parse(trimmed.slice(firstBrace, lastBrace + 1));
    }
    throw new Error('ginga response was not valid JSON');
  }
}

export function parseErrorPayload(rawOutput) {
  const trimmed = String(rawOutput ?? '').trim();
  if (!trimmed) {
    return null;
  }

  try {
    const parsed = JSON.parse(trimmed);
    if (parsed && parsed.ok === false && parsed.error) {
      return parsed;
    }
  } catch {}

  return null;
}

export async function previewImage({ imagePath, binaryPath } = {}) {
  if (!imagePath || typeof imagePath !== 'string') {
    throw new Error('imagePath must be a non-empty string');
  }

  const resolvedBinary = await resolveBinaryPath(binaryPath);
  const request = {
    command: 'preview',
    imagePath: path.resolve(imagePath)
  };

  const result = await spawnCommand(
    resolvedBinary,
    ['preview'],
    `${JSON.stringify(request)}\n`
  );

  if (result.code !== 0) {
    const structured = parseErrorPayload(result.stderr) ?? parseErrorPayload(result.stdout);
    const message = structured?.error?.message ??
      `ginga preview exited with code ${result.code}${result.signal ? ` (${result.signal})` : ''}`;
    const error = new Error(
      message
    );
    error.code = structured?.error?.code ?? `EXIT_${result.code}`;
    error.details = structured?.error ?? null;
    error.stdout = result.stdout;
    error.stderr = result.stderr;
    error.binaryPath = resolvedBinary;
    throw error;
  }

  const payload = parseJsonPayload(result.stdout);
  return {
    binaryPath: resolvedBinary,
    command: [resolvedBinary, 'preview'],
    request,
    payload,
    stderr: result.stderr.trim()
  };
}

async function runCli() {
  const [, , command, ...rest] = process.argv;

  if (command !== 'preview') {
    process.stderr.write(
      'Usage: bun scripts/electron-bridge.mjs preview [--binary path] [imagePath]\n'
    );
    process.exitCode = 1;
    return;
  }

  let binaryPath = '';
  let imagePath = '';

  for (let index = 0; index < rest.length; index += 1) {
    const value = rest[index];
    if (value === '--binary') {
      binaryPath = rest[++index] ?? '';
      continue;
    }
    if (value === '--image') {
      imagePath = rest[++index] ?? '';
      continue;
    }
    if (!imagePath) {
      imagePath = value;
    }
  }

  try {
    const response = await previewImage({ imagePath, binaryPath });
    process.stdout.write(`${JSON.stringify(response, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    if (error && typeof error === 'object') {
      if ('stdout' in error && error.stdout) {
        process.stderr.write(`${error.stdout}\n`);
      }
      if ('stderr' in error && error.stderr) {
        process.stderr.write(`${error.stderr}\n`);
      }
    }
    process.exitCode = 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  await runCli();
}
