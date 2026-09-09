import * as fs from 'fs';
import * as path from 'path';

export type VTaskAction = 'build' | 'run' | 'test';

export interface VTaskSpec {
  action: VTaskAction;
  args: string[];
  name: string;
}

export interface TaskDocumentSpec {
  filePath: string;
  languageId: string;
  isDirty: boolean;
}

export function standaloneTaskScope(
  targetFilePath: string,
  exists: (filePath: string) => boolean = fs.existsSync
): string {
  const targetDirectory = path.dirname(path.resolve(targetFilePath));
  let directory = targetDirectory;
  while (true) {
    if (exists(path.join(directory, 'v.mod'))) {
      return directory;
    }
    const parent = path.dirname(directory);
    if (parent === directory) {
      return targetDirectory;
    }
    directory = parent;
  }
}

export function shouldSaveTaskDocument(
  targetFilePath: string,
  workspaceFolderPath: string | undefined,
  document: TaskDocumentSpec
): boolean {
  if (!document.isDirty) {
    return false;
  }
  const extension = path.extname(document.filePath).toLowerCase();
  if (document.languageId !== 'v' && extension !== '.v' && extension !== '.vsh') {
    return false;
  }
  const scopeRoot = path.resolve(workspaceFolderPath || path.dirname(targetFilePath));
  const relativePath = path.relative(scopeRoot, path.resolve(document.filePath));
  return (
    relativePath === '' ||
    (relativePath !== '..' &&
      !relativePath.startsWith(`..${path.sep}`) &&
      !path.isAbsolute(relativePath))
  );
}

export function taskActionTitle(action: VTaskAction): string {
  return action[0]!.toUpperCase() + action.slice(1);
}

export function workspaceTaskSpec(action: VTaskAction): VTaskSpec {
  const args = (() => {
    switch (action) {
      case 'build':
        return ['-nocolor', '.'];
      case 'run':
        return ['-nocolor', 'run', '.'];
      case 'test':
        return ['-nocolor', 'test', '.'];
    }
  })();
  return { action, args, name: taskActionTitle(action) };
}

export function codeLensTaskSpec(
  command: string,
  filePath: string,
  testName: string
): VTaskSpec {
  if (command === 'vls.runFile') {
    return {
      action: 'run',
      args: ['-nocolor', 'run', '.'],
      name: 'Run Main',
    };
  }
  const args = ['-nocolor', 'test', filePath];
  if (testName) {
    args.push('-run-only', testName);
  }
  return {
    action: 'test',
    args,
    name: testName ? `Run Test: ${testName}` : 'Run Test File',
  };
}
