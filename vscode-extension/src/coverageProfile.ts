import * as fs from 'fs';
import * as path from 'path';

export interface LineCoverage {
  covered: number[];
  uncovered: number[];
}

export type CoverageProfile = Map<string, LineCoverage>;

export interface CoverageDocumentState {
  filePath: string;
  isDirty: boolean;
}

export interface FileModificationState {
  ctimeMs: number;
  device: number;
  inode: number;
  mtimeMs: number;
  size: number;
}

export function canonicalFilePath(filePath: string, baseDirectory = process.cwd()): string {
  let absolutePath = path.isAbsolute(filePath)
    ? path.normalize(filePath)
    : path.resolve(baseDirectory, filePath);
  let existingPath = absolutePath;
  while (true) {
    try {
      const realExistingPath = fs.realpathSync.native(existingPath);
      absolutePath = path.resolve(realExistingPath, path.relative(existingPath, absolutePath));
      break;
    } catch {
      const parent = path.dirname(existingPath);
      if (parent === existingPath) {
        break;
      }
      existingPath = parent;
    }
  }
  return process.platform === 'win32' ? absolutePath.toLowerCase() : absolutePath;
}

export function instrumentCoverageArgs(args: string[], coverageDirectory: string): string[] {
  return ['-no-skip-unused', '-coverage', coverageDirectory, ...args];
}

export function coverageArgsForRun(
  args: string[],
  coverageDirectory?: string
): string[] {
  return coverageDirectory ? instrumentCoverageArgs(args, coverageDirectory) : [...args];
}

export function recordFileChange(changedFiles: Set<string>, filePath: string): void {
  changedFiles.add(canonicalFilePath(filePath));
}

export function readFileModificationState(filePath: string): FileModificationState | undefined {
  try {
    const stat = fs.statSync(filePath);
    if (!stat.isFile()) {
      return undefined;
    }
    return {
      ctimeMs: stat.ctimeMs,
      device: stat.dev,
      inode: stat.ino,
      mtimeMs: stat.mtimeMs,
      size: stat.size,
    };
  } catch {
    return undefined;
  }
}

export function fileModificationStateMatches(
  filePath: string,
  expected: FileModificationState
): boolean {
  const current = readFileModificationState(filePath);
  return (
    current !== undefined &&
    current.ctimeMs === expected.ctimeMs &&
    current.device === expected.device &&
    current.inode === expected.inode &&
    current.mtimeMs === expected.mtimeMs &&
    current.size === expected.size
  );
}

export function pruneStaleCoverageFiles(
  profile: CoverageProfile,
  fileStates: Map<string, FileModificationState>
): boolean {
  let removedFile = false;
  for (const filePath of profile.keys()) {
    const state = fileStates.get(filePath);
    if (!state || !fileModificationStateMatches(filePath, state)) {
      profile.delete(filePath);
      fileStates.delete(filePath);
      removedFile = true;
    }
  }
  return removedFile;
}

export function seedDirtyFileInvalidations(
  changedFiles: Map<string, number>,
  documents: readonly CoverageDocumentState[],
  generation: number
): void {
  changedFiles.clear();
  for (const document of documents) {
    if (document.isDirty) {
      changedFiles.set(canonicalFilePath(document.filePath), generation);
    }
  }
}

export function parseLcovProfile(content: string, baseDirectory: string): CoverageProfile {
  const hitsByFile = new Map<string, Map<number, number>>();
  let currentFile: string | undefined;

  for (const rawLine of content.split(/\r?\n/)) {
    if (rawLine.startsWith('SF:')) {
      const filePath = rawLine.slice(3).trim();
      currentFile = filePath ? canonicalFilePath(filePath, baseDirectory) : undefined;
      if (currentFile && !hitsByFile.has(currentFile)) {
        hitsByFile.set(currentFile, new Map());
      }
      continue;
    }
    if (!currentFile || !rawLine.startsWith('DA:')) {
      continue;
    }

    const fields = rawLine.slice(3).split(',');
    const line = Number.parseInt(fields[0] || '', 10);
    const hits = Number.parseInt(fields[1] || '', 10);
    if (!Number.isSafeInteger(line) || line < 1 || !Number.isSafeInteger(hits) || hits < 0) {
      continue;
    }
    const fileHits = hitsByFile.get(currentFile)!;
    fileHits.set(line, (fileHits.get(line) || 0) + hits);
  }

  const profile: CoverageProfile = new Map();
  for (const [filePath, lineHits] of hitsByFile) {
    const covered: number[] = [];
    const uncovered: number[] = [];
    for (const [line, hits] of lineHits) {
      (hits > 0 ? covered : uncovered).push(line);
    }
    covered.sort((left, right) => left - right);
    uncovered.sort((left, right) => left - right);
    profile.set(filePath, { covered, uncovered });
  }
  return profile;
}
