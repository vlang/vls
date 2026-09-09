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
