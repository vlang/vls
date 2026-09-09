import * as vscode from 'vscode';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import {
  codeLensTaskSpec,
  shouldSaveTaskDocument,
  taskActionTitle,
  VTaskAction,
  workspaceTaskSpec,
} from './taskSpec';

interface VTaskDefinition extends vscode.TaskDefinition {
  type: 'v';
  action: VTaskAction;
}

interface VTaskTarget {
  cwd: string;
  scope: vscode.WorkspaceFolder | vscode.TaskScope;
}

const activeExecutions = new Map<string, vscode.TaskExecution>();

function isExecutable(filePath: string): boolean {
  try {
    if (!fs.statSync(filePath).isFile()) {
      return false;
    }
    if (process.platform !== 'win32') {
      fs.accessSync(filePath, fs.constants.X_OK);
    }
    return true;
  } catch {
    return false;
  }
}

function executableNames(bin: string): string[] {
  if (process.platform !== 'win32' || path.extname(bin) !== '') {
    return [bin];
  }
  const extensions = (process.env.PATHEXT || '.EXE;.CMD;.BAT;.COM')
    .split(';')
    .filter(Boolean);
  return [bin, ...extensions.map((extension) => `${bin}${extension.toLowerCase()}`)];
}

export function findInPath(bin: string): string | undefined {
  const envPath = process.env.PATH || '';
  for (const rawDirectory of envPath.split(path.delimiter)) {
    const directory = rawDirectory.replace(/^"|"$/g, '');
    if (!directory) {
      continue;
    }
    for (const name of executableNames(bin)) {
      const fullPath = path.join(directory, name);
      if (isExecutable(fullPath)) {
        return fullPath;
      }
    }
  }
  return undefined;
}

function expandConfiguredPath(value: string, folder?: vscode.WorkspaceFolder): string {
  let expanded = value.replace(/^~(?=$|[\\/])/, os.homedir());
  expanded = expanded.replace(/\$\{env:([^}]+)\}/g, (_match, name: string) => {
    return process.env[name] || '';
  });
  if (folder) {
    expanded = expanded.replace(/\$\{workspaceFolder\}/g, folder.uri.fsPath);
  }
  return expanded;
}

function configuredVCommand(folder?: vscode.WorkspaceFolder): string {
  const config = vscode.workspace.getConfiguration('vls', folder?.uri);
  const configured = config.get<string>('vCommand', '').trim();
  if (!configured) {
    return findInPath('v') || 'v';
  }
  return expandConfiguredPath(configured, folder);
}

function resolvedVCommand(folder?: vscode.WorkspaceFolder): string | undefined {
  const command = configuredVCommand(folder);
  const isPath = path.isAbsolute(command) || command.includes('/') || command.includes('\\');
  if (isPath) {
    const fullPath = path.isAbsolute(command)
      ? command
      : path.resolve(folder?.uri.fsPath || process.cwd(), command);
    return isExecutable(fullPath) ? fullPath : undefined;
  }
  return findInPath(command);
}

export function vCommandForServer(): string | undefined {
  return resolvedVCommand();
}

async function showMissingVCompiler(folder?: vscode.WorkspaceFolder): Promise<void> {
  const configured = vscode.workspace
    .getConfiguration('vls', folder?.uri)
    .get<string>('vCommand', '')
    .trim();
  const message = configured
    ? `The configured V compiler was not found or is not executable: ${configured}`
    : 'V compiler not found. Set "vls.vCommand" or add "v" to PATH.';
  const selection = await vscode.window.showErrorMessage(message, 'Open Settings');
  if (selection === 'Open Settings') {
    await vscode.commands.executeCommand('workbench.action.openSettings', 'vls.vCommand');
  }
}

function workspaceFolderForScope(
  scope: vscode.WorkspaceFolder | vscode.TaskScope | undefined
): vscode.WorkspaceFolder | undefined {
  return scope !== undefined && typeof scope !== 'number' ? scope : undefined;
}

function createVTask(
  action: VTaskAction,
  target: VTaskTarget,
  args = workspaceTaskSpec(action).args,
  name = workspaceTaskSpec(action).name
): vscode.Task {
  const folder = workspaceFolderForScope(target.scope);
  const command = resolvedVCommand(folder) || configuredVCommand(folder);
  const definition: VTaskDefinition = { type: 'v', action };
  const task = new vscode.Task(
    definition,
    target.scope,
    name,
    'V',
    new vscode.ProcessExecution(command, args, { cwd: target.cwd }),
    ['$vls']
  );
  task.detail = `${command} ${args.join(' ')}`;
  task.presentationOptions = {
    clear: true,
    echo: true,
    focus: false,
    panel: vscode.TaskPanelKind.Dedicated,
    reveal: vscode.TaskRevealKind.Always,
    showReuseMessage: true,
  };
  if (action === 'build') {
    task.group = vscode.TaskGroup.Build;
  } else if (action === 'test') {
    task.group = vscode.TaskGroup.Test;
  }
  return task;
}

function folderTarget(folder: vscode.WorkspaceFolder): VTaskTarget {
  return { cwd: folder.uri.fsPath, scope: folder };
}

function activeFileUri(): vscode.Uri | undefined {
  const document = vscode.window.activeTextEditor?.document;
  if (!document || document.uri.scheme !== 'file') {
    return undefined;
  }
  if (document.languageId !== 'v' && !document.fileName.endsWith('.vsh')) {
    return undefined;
  }
  return document.uri;
}

function targetForUri(uri: vscode.Uri): VTaskTarget {
  const folder = vscode.workspace.getWorkspaceFolder(uri);
  return {
    cwd: path.dirname(uri.fsPath),
    scope: folder || vscode.TaskScope.Global,
  };
}

function activeWorkspaceTarget(): VTaskTarget | undefined {
  const uri = activeFileUri();
  if (uri) {
    const folder = vscode.workspace.getWorkspaceFolder(uri);
    if (folder) {
      return folderTarget(folder);
    }
    return targetForUri(uri);
  }
  const folder = vscode.workspace.workspaceFolders?.[0];
  return folder ? folderTarget(folder) : undefined;
}

async function saveTaskDocuments(
  target: VTaskTarget,
  targetFilePath = target.cwd
): Promise<boolean> {
  const folder = workspaceFolderForScope(target.scope);
  const scopeRoot = folder?.uri.fsPath || target.cwd;
  const documents = vscode.workspace.textDocuments.filter((document) => {
    return (
      document.uri.scheme === 'file' &&
      shouldSaveTaskDocument(targetFilePath, scopeRoot, {
        filePath: document.uri.fsPath,
        languageId: document.languageId,
        isDirty: document.isDirty,
      })
    );
  });
  for (const document of documents) {
    if (!(await document.save())) {
      return false;
    }
  }
  return true;
}

async function executeVTask(
  task: vscode.Task,
  folder: vscode.WorkspaceFolder | undefined,
  executionKey: string
): Promise<vscode.TaskExecution | undefined> {
  if (!resolvedVCommand(folder)) {
    await showMissingVCompiler(folder);
    return undefined;
  }
  activeExecutions.get(executionKey)?.terminate();
  const execution = await vscode.tasks.executeTask(task);
  activeExecutions.set(executionKey, execution);
  return execution;
}

function taskFolder(task: vscode.Task): vscode.WorkspaceFolder | undefined {
  return workspaceFolderForScope(task.scope);
}

async function runPaletteTask(action: VTaskAction): Promise<void> {
  const workspaceTarget = activeWorkspaceTarget();
  if (!workspaceTarget) {
    vscode.window.showErrorMessage(
      `V: ${taskActionTitle(action)} requires an open workspace or V file.`
    );
    return;
  }
  const uri = activeFileUri();
  if (!(await saveTaskDocuments(workspaceTarget, uri?.fsPath))) {
    vscode.window.showErrorMessage(
      `V: ${taskActionTitle(action)} was cancelled because one or more V files were not saved.`
    );
    return;
  }

  const workspaceSpec = workspaceTaskSpec(action);
  let target = workspaceTarget;
  let args = workspaceSpec.args;
  let name = workspaceSpec.name;
  if (action === 'run' && uri) {
    target = targetForUri(uri);
    name = 'Run Active Module';
  } else if (action === 'test' && uri?.fsPath.endsWith('_test.v')) {
    target = targetForUri(uri);
    args = ['-nocolor', 'test', uri.fsPath];
    name = 'Test Active File';
  }

  const task = createVTask(action, target, args, name);
  const key = `${action}:${target.cwd}:${args.join('\0')}`;
  await executeVTask(task, taskFolder(task), key);
}

function codeLensUri(argument: unknown): vscode.Uri | undefined {
  if (typeof argument !== 'string' || argument.trim() === '') {
    return undefined;
  }
  try {
    const uri = argument.includes('://') || argument.startsWith('file:')
      ? vscode.Uri.parse(argument, true)
      : vscode.Uri.file(argument);
    return uri.scheme === 'file' ? uri : undefined;
  } catch {
    return undefined;
  }
}

export async function runCodeLensCommand(command: string, args: unknown[]): Promise<void> {
  const uri = codeLensUri(args[0]);
  if (!uri) {
    vscode.window.showErrorMessage('V: This command requires a local V source file.');
    return;
  }
  const target = targetForUri(uri);
  if (!(await saveTaskDocuments(target, uri.fsPath))) {
    vscode.window.showErrorMessage(
      'V: The command was cancelled because one or more V files were not saved.'
    );
    return;
  }

  const testName = typeof args[1] === 'string' ? args[1].trim() : '';
  const spec = codeLensTaskSpec(command, uri.fsPath, testName);
  const task = createVTask(spec.action, target, spec.args, spec.name);
  const key = `${command}:${uri.fsPath}:${args[1] || ''}`;
  await executeVTask(task, taskFolder(task), key);
}

class VTaskProvider implements vscode.TaskProvider {
  provideTasks(): vscode.Task[] {
    const tasks: vscode.Task[] = [];
    for (const folder of vscode.workspace.workspaceFolders || []) {
      for (const action of ['build', 'run', 'test'] as const) {
        tasks.push(createVTask(action, folderTarget(folder)));
      }
    }
    return tasks;
  }

  resolveTask(task: vscode.Task): vscode.Task | undefined {
    const action = task.definition.action;
    if (action !== 'build' && action !== 'run' && action !== 'test') {
      return undefined;
    }
    const folder = workspaceFolderForScope(task.scope) || vscode.workspace.workspaceFolders?.[0];
    if (!folder) {
      return undefined;
    }
    return createVTask(action, folderTarget(folder));
  }
}

export function registerVTasks(context: vscode.ExtensionContext): void {
  context.subscriptions.push(vscode.tasks.registerTaskProvider('v', new VTaskProvider()));
  context.subscriptions.push(
    vscode.commands.registerCommand('vls.build', () => runPaletteTask('build')),
    vscode.commands.registerCommand('vls.run', () => runPaletteTask('run')),
    vscode.commands.registerCommand('vls.test', () => runPaletteTask('test')),
    vscode.tasks.onDidEndTask((event) => {
      for (const [key, execution] of activeExecutions) {
        if (execution === event.execution) {
          activeExecutions.delete(key);
        }
      }
    }),
    new vscode.Disposable(() => {
      for (const execution of activeExecutions.values()) {
        execution.terminate();
      }
      activeExecutions.clear();
    })
  );
}
