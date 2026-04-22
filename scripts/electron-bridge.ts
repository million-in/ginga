import { access, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import type {
  ConvertEngineResponse,
  InspectEngineResponse,
  PreviewEnginePayload,
  PreviewEngineRequest,
  PreviewEngineResponse
} from '../electron/shared';

type BridgeExecutionResult = {
  code: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
};

type StructuredErrorPayload = {
  ok: false;
  error?: {
    code?: string;
    message?: string;
  };
};

type PreviewImageOptions = {
  imagePath?: string;
  binaryPath?: string;
};

type InspectImageOptions = {
  imagePath?: string;
  binaryPath?: string;
};

type ConvertImageOptions = {
  inputPath?: string;
  outputPath?: string;
  quality?: number;
  binaryPath?: string;
};

type BridgeError = Error & {
  code: string;
  details: unknown;
  stdout: string;
  stderr: string;
  binaryPath: string;
};

const moduleDir = path.dirname(fileURLToPath(import.meta.url));

function resolveRepoRoot(fromDir: string): string {
  if (path.basename(fromDir) === 'scripts') {
    return path.resolve(fromDir, '..');
  }

  if (
    path.basename(fromDir) === 'dist' &&
    path.basename(path.dirname(fromDir)) === 'electron'
  ) {
    return path.resolve(fromDir, '..', '..');
  }

  return process.cwd();
}

const repoRoot = resolveRepoRoot(moduleDir);

function pathCandidatesFromPathEnv(): string[] {
  const rawPath = process.env.PATH ?? '';
  if (!rawPath) {
    return [];
  }

  return rawPath
    .split(path.delimiter)
    .filter(Boolean)
    .map((entry) => path.join(entry, 'ginga'));
}

export const candidateBinaryPaths = (): string[] => {
  const candidates: string[] = [];
  if (process.env.GINGA_BIN) {
    candidates.push(process.env.GINGA_BIN);
  }
  candidates.push(
    path.join(repoRoot, 'zig-out', 'bin', 'ginga'),
    path.join(repoRoot, 'ginga')
  );
  if (process.env.HOME) {
    candidates.push(
      path.join(process.env.HOME, '.local', 'bin', 'ginga'),
      path.join(process.env.HOME, 'bin', 'ginga')
    );
  }
  candidates.push(
    '/usr/local/bin/ginga',
    '/opt/homebrew/bin/ginga',
    ...pathCandidatesFromPathEnv()
  );
  return [...new Set(candidates)];
};

async function pathExists(candidate: string): Promise<boolean> {
  try {
    await access(candidate, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export async function resolveBinaryPath(explicitPath = ''): Promise<string> {
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
    'Unable to locate the ginga binary. Run `bun run build` first or set GINGA_BIN.'
  );
}

function spawnCommand(
  binaryPath: string,
  args: string[],
  input?: string
): Promise<BridgeExecutionResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(binaryPath, args, {
      cwd: repoRoot,
      env: {
        PATH: process.env.PATH,
        HOME: process.env.HOME,
        TMPDIR: process.env.TMPDIR,
        TEMP: process.env.TEMP,
        TMP: process.env.TMP
      },
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');

    child.stdout.on('data', (chunk: string) => {
      stdout += chunk;
    });

    child.stderr.on('data', (chunk: string) => {
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

export function parseJsonPayload<T>(rawOutput: unknown): T {
  const trimmed = String(rawOutput ?? '').trim();
  if (!trimmed) {
    throw new Error('ginga returned an empty response');
  }

  try {
    return JSON.parse(trimmed) as T;
  } catch {
    throw new Error('ginga response was not valid JSON');
  }
}

export function parseErrorPayload(rawOutput: unknown): StructuredErrorPayload | null {
  const trimmed = String(rawOutput ?? '').trim();
  if (!trimmed) {
    return null;
  }

  try {
    const parsed = JSON.parse(trimmed) as StructuredErrorPayload;
    if (parsed && parsed.ok === false && parsed.error) {
      return parsed;
    }
  } catch {}

  return null;
}

function toBridgeError(
  message: string,
  resolvedBinary: string,
  result: BridgeExecutionResult,
  structured: StructuredErrorPayload | null
): BridgeError {
  const error = new Error(message) as BridgeError;
  error.code = structured?.error?.code ?? `EXIT_${result.code}`;
  error.details = structured?.error ?? null;
  error.stdout = result.stdout;
  error.stderr = result.stderr;
  error.binaryPath = resolvedBinary;
  return error;
}

export async function previewImage({
  imagePath,
  binaryPath
}: PreviewImageOptions = {}): Promise<PreviewEngineResponse> {
  if (!imagePath || typeof imagePath !== 'string') {
    throw new Error('imagePath must be a non-empty string');
  }

  const resolvedBinary = await resolveBinaryPath(binaryPath);
  const request: PreviewEngineRequest = {
    command: 'preview',
    imagePath: path.resolve(imagePath),
    spectralMode: 'approximate'
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
    throw toBridgeError(message, resolvedBinary, result, structured);
  }

  const payload = parseJsonPayload<PreviewEnginePayload>(result.stdout);
  return {
    binaryPath: resolvedBinary,
    command: [resolvedBinary, 'preview'],
    request,
    payload,
    stderr: result.stderr.trim()
  };
}

export async function inspectImage({
  imagePath,
  binaryPath
}: InspectImageOptions = {}): Promise<InspectEngineResponse> {
  if (!imagePath || typeof imagePath !== 'string') {
    throw new Error('imagePath must be a non-empty string');
  }

  const resolvedBinary = await resolveBinaryPath(binaryPath);
  const resolvedImagePath = path.resolve(imagePath);
  const result = await spawnCommand(resolvedBinary, ['inspect', resolvedImagePath]);

  if (result.code !== 0) {
    const structured = parseErrorPayload(result.stderr) ?? parseErrorPayload(result.stdout);
    const message = structured?.error?.message ??
      `ginga inspect exited with code ${result.code}${result.signal ? ` (${result.signal})` : ''}`;
    throw toBridgeError(message, resolvedBinary, result, structured);
  }

  return {
    binaryPath: resolvedBinary,
    command: [resolvedBinary, 'inspect', resolvedImagePath],
    imagePath: resolvedImagePath,
    payload: parseJsonPayload<InspectEngineResponse['payload']>(result.stdout),
    stderr: result.stderr.trim()
  };
}

function encodingForConversion(sourceFormat: string, outputFormat: string): 'lossless' | 'lossy' {
  if (outputFormat === 'jpeg' || outputFormat === 'jpg' || outputFormat === 'webp') {
    return 'lossy';
  }
  if (outputFormat === 'spd') {
    return sourceFormat === 'spd' ? 'lossless' : 'lossy';
  }
  if (outputFormat === 'png') {
    return 'lossless';
  }
  return 'lossy';
}

function ratioOrNull(sourceBytes: number, outputBytes: number): number | null {
  if (!sourceBytes || !outputBytes) {
    return null;
  }

  return sourceBytes / outputBytes;
}

export async function convertImage({
  inputPath,
  outputPath,
  quality = 90,
  binaryPath
}: ConvertImageOptions = {}): Promise<ConvertEngineResponse> {
  if (!inputPath || typeof inputPath !== 'string') {
    throw new Error('inputPath must be a non-empty string');
  }
  if (!outputPath || typeof outputPath !== 'string') {
    throw new Error('outputPath must be a non-empty string');
  }

  const resolvedBinary = await resolveBinaryPath(binaryPath);
  const resolvedInputPath = path.resolve(inputPath);
  const resolvedOutputPath = path.resolve(outputPath);
  const request = {
    command: 'convert' as const,
    inputPath: resolvedInputPath,
    outputPath: resolvedOutputPath,
    quality
  };
  const args = ['convert', resolvedInputPath, resolvedOutputPath];
  const outputExtension = path.extname(resolvedOutputPath).toLowerCase();
  if (outputExtension !== '.png' && outputExtension !== '.spd') {
    args.push('--quality', String(quality));
  }

  const result = await spawnCommand(resolvedBinary, args);
  if (result.code !== 0) {
    const structured = parseErrorPayload(result.stderr) ?? parseErrorPayload(result.stdout);
    const message = structured?.error?.message ??
      `ginga convert exited with code ${result.code}${result.signal ? ` (${result.signal})` : ''}`;
    throw toBridgeError(message, resolvedBinary, result, structured);
  }

  const [source, output, sourceStat, outputStat] = await Promise.all([
    inspectImage({ imagePath: resolvedInputPath, binaryPath: resolvedBinary }),
    inspectImage({ imagePath: resolvedOutputPath, binaryPath: resolvedBinary }),
    stat(resolvedInputPath),
    stat(resolvedOutputPath)
  ]);

  const outputFormat = output.payload.format;
  return {
    binaryPath: resolvedBinary,
    command: [resolvedBinary, ...args],
    request,
    source,
    output,
    details: {
      sourcePath: resolvedInputPath,
      outputPath: resolvedOutputPath,
      sourceFormat: source.payload.format,
      outputFormat,
      sourceWidth: source.payload.width,
      sourceHeight: source.payload.height,
      outputWidth: output.payload.width,
      outputHeight: output.payload.height,
      sourceBytes: sourceStat.size,
      outputBytes: outputStat.size,
      compressionRatio: ratioOrNull(sourceStat.size, outputStat.size),
      outputEncoding: encodingForConversion(source.payload.format, outputFormat),
      quality: outputFormat === 'png' || outputFormat === 'spd' ? null : quality
    },
    stderr: result.stderr.trim()
  };
}

async function runCli(): Promise<void> {
  const [, , command, ...rest] = process.argv;

  if (command !== 'preview' && command !== 'inspect' && command !== 'convert') {
    process.stderr.write(
      'Usage: bun scripts/electron-bridge.ts <preview|inspect|convert> [--binary path] [--image path] [--output path] [--quality n]\n'
    );
    process.exitCode = 1;
    return;
  }

  let binaryPath = '';
  let imagePath = '';
  let outputPath = '';
  let quality = 90;

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
    if (value === '--output') {
      outputPath = rest[++index] ?? '';
      continue;
    }
    if (value === '--quality') {
      quality = Number.parseInt(rest[++index] ?? '90', 10);
      continue;
    }
    if (!imagePath) {
      imagePath = value;
      continue;
    }
    if (!outputPath) {
      outputPath = value;
    }
  }

  try {
    const response = command === 'preview'
      ? await previewImage({ imagePath, binaryPath })
      : command === 'inspect'
        ? await inspectImage({ imagePath, binaryPath })
        : await convertImage({ inputPath: imagePath, outputPath, quality, binaryPath });
    process.stdout.write(`${JSON.stringify(response, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    if (error && typeof error === 'object') {
      if ('stdout' in error && error.stdout) {
        process.stderr.write(`${String(error.stdout)}\n`);
      }
      if ('stderr' in error && error.stderr) {
        process.stderr.write(`${String(error.stderr)}\n`);
      }
    }
    process.exitCode = 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  runCli().catch((error: unknown) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
