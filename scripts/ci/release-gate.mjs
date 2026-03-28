import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const moduleDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(moduleDir, '..', '..');

function runGit(args) {
  return execFileSync('git', args, {
    cwd: repoRoot,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore']
  }).trim();
}

function tryRunGit(args) {
  try {
    return runGit(args);
  } catch {
    return '';
  }
}

function parseBuildZonVersion(text) {
  const match = text.match(/\.version\s*=\s*"([^"]+)"/);
  if (!match) {
    throw new Error('build.zig.zon is missing .version');
  }
  return match[1];
}

function extractChangelogSection(changelog, version) {
  const header = `## [${version}]`;
  const start = changelog.indexOf(header);
  if (start === -1) {
    return null;
  }

  const bodyStart = changelog.indexOf('\n', start);
  const nextHeader = changelog.indexOf('\n## [', bodyStart + 1);
  return changelog.slice(start, nextHeader === -1 ? changelog.length : nextHeader).trim();
}

function parseStatusFiles(statusText) {
  return statusText
    .split('\n')
    .map((line) => line.trimEnd())
    .filter(Boolean)
    .map((line) => line.slice(3))
    .map((file) => file.replace(/^"|"$/g, ''));
}

function fileMatchesPrefix(file, prefix) {
  return file === prefix || file.startsWith(`${prefix}/`);
}

async function main() {
  const mode = process.argv[2] ?? 'mergeable';
  if (!['mergeable', 'releasable'].includes(mode)) {
    throw new Error('usage: bun scripts/ci/release-gate.mjs <mergeable|releasable>');
  }

  const [policyText, flagsText, packageText, zonText, changelogText] = await Promise.all([
    readFile(path.join(repoRoot, 'release', 'policy.json'), 'utf8'),
    readFile(path.join(repoRoot, 'release', 'feature-flags.json'), 'utf8'),
    readFile(path.join(repoRoot, 'package.json'), 'utf8'),
    readFile(path.join(repoRoot, 'build.zig.zon'), 'utf8'),
    readFile(path.join(repoRoot, 'CHANGELOG.md'), 'utf8')
  ]);

  const policy = JSON.parse(policyText);
  const flags = JSON.parse(flagsText).flags ?? [];
  const packageVersion = JSON.parse(packageText).version;
  const buildVersion = parseBuildZonVersion(zonText);
  const versionsSynced = packageVersion === buildVersion;

  const changelogSection = extractChangelogSection(changelogText, packageVersion);
  const changelogValid = changelogSection !== null;

  const changedFiles = new Set();
  const baseCandidates = [];
  if (process.env.GATE_BASE) {
    baseCandidates.push(process.env.GATE_BASE);
  }
  if (process.env.GITHUB_BASE_REF) {
    baseCandidates.push(`origin/${process.env.GITHUB_BASE_REF}`);
  }
  baseCandidates.push('HEAD^');

  for (const base of baseCandidates) {
    const diff = tryRunGit(['diff', '--name-only', base, 'HEAD']);
    if (diff) {
      diff.split('\n').filter(Boolean).forEach((file) => changedFiles.add(file));
      break;
    }
  }

  const statusFiles = parseStatusFiles(tryRunGit(['status', '--porcelain']));
  for (const file of statusFiles) {
    changedFiles.add(file);
  }

  const changedFileList = [...changedFiles].sort();
  const enabledFlags = new Set(
    flags.filter((flag) => ['enabled', 'canary'].includes(flag.state)).map((flag) => flag.name)
  );

  const requiredFlags = new Set();
  for (const file of changedFileList) {
    for (const [prefix, flagName] of Object.entries(policy.riskyPathFlags ?? {})) {
      if (fileMatchesPrefix(file, prefix)) {
        requiredFlags.add(flagName);
      }
    }
  }

  const missingFlags = [...requiredFlags].filter((flagName) => !enabledFlags.has(flagName));
  const canaryEligible =
    missingFlags.length === 0 &&
    !(policy.canaryBlockedPrefixes ?? []).some((prefix) =>
      changedFileList.some((file) => fileMatchesPrefix(file, prefix))
    );

  const mergeable = versionsSynced && changelogValid;
  const releasable = mergeable && missingFlags.length === 0;
  const ok = mode === 'mergeable' ? mergeable : releasable;

  const reportDir = path.join(repoRoot, '.reports');
  await mkdir(reportDir, { recursive: true });

  const generatedAt = process.env.SOURCE_DATE_EPOCH
    ? new Date(Number(process.env.SOURCE_DATE_EPOCH) * 1000).toISOString()
    : new Date().toISOString();

  const releaseNotes = changelogSection ?? `## [${packageVersion}]\n\n- changelog entry missing\n`;
  const gitHead = tryRunGit(['rev-parse', 'HEAD']);
  const rolloutMetadata = {
    version: packageVersion,
    commit: process.env.GITHUB_SHA ?? (gitHead || 'unknown'),
    generatedAt,
    mergeable,
    releasable,
    canaryEligible,
    changedFiles: changedFileList,
    requiredFlags: [...requiredFlags].sort(),
    missingFlags
  };

  const report = {
    ok,
    mode,
    packageVersion,
    buildVersion,
    versionsSynced,
    changelogValid,
    mergeable,
    releasable,
    canaryEligible,
    changedFiles: changedFileList,
    requiredFlags: [...requiredFlags].sort(),
    missingFlags
  };

  await Promise.all([
    writeFile(path.join(repoRoot, policy.releaseNotesPath), `${releaseNotes}\n`),
    writeFile(path.join(repoRoot, policy.rolloutMetadataPath), `${JSON.stringify(rolloutMetadata, null, 2)}\n`),
    writeFile(path.join(repoRoot, policy.reportPath), `${JSON.stringify(report, null, 2)}\n`)
  ]);

  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (!ok) {
    process.exitCode = 1;
  }
}

await main();
