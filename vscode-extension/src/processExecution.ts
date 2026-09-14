export interface ProcessCommand {
  args: string[];
  command: string;
}

export function windowsCommandShell(
  command: string,
  platform = process.platform,
  commandInterpreter = process.env.ComSpec
): string | undefined {
  if (platform !== 'win32' || !/\.(?:cmd|bat)$/i.test(command)) {
    return undefined;
  }
  return commandInterpreter || 'cmd.exe';
}

export function processTreeKillCommand(
  processId: number,
  platform = process.platform
): ProcessCommand | undefined {
  if (platform !== 'win32') {
    return undefined;
  }
  return {
    command: 'taskkill.exe',
    args: ['/pid', String(processId), '/t', '/f'],
  };
}
