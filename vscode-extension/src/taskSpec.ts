import * as path from 'path';

export type VTaskAction = 'build' | 'run' | 'test';

export interface VTaskSpec {
  action: VTaskAction;
  args: string[];
  name: string;
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

export function taskWorkingDirectory(filePath: string, workspaceFolder?: string): string {
  return workspaceFolder || path.dirname(filePath);
}

function taskPath(targetPath: string, workingDirectory: string): string {
  const relativePath = path.relative(workingDirectory, targetPath);
  if (relativePath === '') {
    return '.';
  }
  if (
    relativePath === '..' ||
    relativePath.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relativePath)
  ) {
    return targetPath;
  }
  return relativePath;
}

export function activeRunTaskSpec(filePath: string, workingDirectory: string): VTaskSpec {
  const isScript = filePath.endsWith('.vsh');
  const targetPath = isScript ? filePath : path.dirname(filePath);
  return {
    action: 'run',
    args: ['-nocolor', 'run', taskPath(targetPath, workingDirectory)],
    name: isScript ? 'Run Active Script' : 'Run Active Module',
  };
}

export function codeLensTaskSpec(
  command: string,
  filePath: string,
  testName: string,
  workingDirectory = path.dirname(filePath)
): VTaskSpec {
  if (command === 'vls.runFile') {
    return {
      action: 'run',
      args: ['-nocolor', 'run', taskPath(path.dirname(filePath), workingDirectory)],
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
