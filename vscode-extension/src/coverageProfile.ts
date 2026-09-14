import * as path from 'path';

export interface LineCoverage {
  covered: number[];
  uncovered: number[];
}

export type CoverageProfile = Map<string, LineCoverage>;

function normalizedFilePath(filePath: string, baseDirectory: string): string {
  const absolutePath = path.isAbsolute(filePath)
    ? path.normalize(filePath)
    : path.resolve(baseDirectory, filePath);
  return process.platform === 'win32' ? absolutePath.toLowerCase() : absolutePath;
}

export function instrumentCoverageArgs(args: string[], coverageDirectory: string): string[] {
  return ['-no-skip-unused', '-coverage', coverageDirectory, ...args];
}

export function parseLcovProfile(content: string, baseDirectory: string): CoverageProfile {
  const hitsByFile = new Map<string, Map<number, number>>();
  let currentFile: string | undefined;

  for (const rawLine of content.split(/\r?\n/)) {
    if (rawLine.startsWith('SF:')) {
      const filePath = rawLine.slice(3).trim();
      currentFile = filePath ? normalizedFilePath(filePath, baseDirectory) : undefined;
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
