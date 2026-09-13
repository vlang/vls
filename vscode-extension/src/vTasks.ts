import * as vscode from 'vscode';
import {
  activeRunTaskSpec,
  codeLensTaskSpec,
  shouldSaveTaskDocument,
  standaloneTaskScope,
  taskWorkingDirectory,
  taskActionTitle,
  VTaskAction,
  workspaceTaskSpec,
} from './taskSpec';
import { configuredCommand, resolvedCommand, serverCommand } from './vCommand';

interface VTaskDefinition extends vscode.TaskDefinition {
  type: 'v';
  action: VTaskAction;
}

interface VTaskTarget {
  cwd: string;
  scope: vscode.WorkspaceFolder | vscode.TaskScope;
}

function vCommandSetting(folder?: vscode.WorkspaceFolder): string {
  return vscode.workspace
    .getConfiguration('vls', folder?.uri)
    .get<string>('vCommand', '');
}

function configuredVCommand(folder?: vscode.WorkspaceFolder): string {
  return configuredCommand(vCommandSetting(folder), folder?.uri.fsPath);
}

function resolvedVCommand(folder?: vscode.WorkspaceFolder): string | undefined {
  return resolvedCommand(vCommandSetting(folder), folder?.uri.fsPath);
}

export function vCommandForServer(folder?: vscode.WorkspaceFolder): string | undefined {
  return serverCommand(vCommandSetting(folder), folder?.uri.fsPath);
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
    cwd: taskWorkingDirectory(uri.fsPath, folder?.uri.fsPath),
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
  const scopeRoot = folder?.uri.fsPath || standaloneTaskScope(targetFilePath);
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

function taskFolder(task: vscode.Task): vscode.WorkspaceFolder | undefined {
  return workspaceFolderForScope(task.scope);
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

async function runPaletteTask(action: VTaskAction, manager: VTaskManager): Promise<void> {
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
    const runSpec = activeRunTaskSpec(uri.fsPath, target.cwd);
    args = runSpec.args;
    name = runSpec.name;
  } else if (action === 'test' && uri?.fsPath.endsWith('_test.v')) {
    target = targetForUri(uri);
    args = ['-nocolor', 'test', uri.fsPath];
    name = 'Test Active File';
  }

  const task = createVTask(action, target, args, name);
  const key = `${action}:${target.cwd}:${args.join('\0')}`;
  await manager.executeVTask(task, taskFolder(task), key);
}

export async function runCodeLensCommand(
  command: string,
  args: unknown[],
  manager: VTaskManager
): Promise<void> {
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
  const spec = codeLensTaskSpec(command, uri.fsPath, testName, target.cwd);
  const task = createVTask(spec.action, target, spec.args, spec.name);
  const key = `${command}:${uri.fsPath}:${args[1] || ''}`;
  await manager.executeVTask(task, taskFolder(task), key);
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

export class VTaskManager implements vscode.Disposable {
  private readonly activeExecutions = new Map<string, vscode.TaskExecution>();

  async executeVTask(
    task: vscode.Task,
    folder: vscode.WorkspaceFolder | undefined,
    executionKey: string
  ): Promise<vscode.TaskExecution | undefined> {
    if (!resolvedVCommand(folder)) {
      await showMissingVCompiler(folder);
      return undefined;
    }
    this.activeExecutions.get(executionKey)?.terminate();
    const execution = await vscode.tasks.executeTask(task);
    this.activeExecutions.set(executionKey, execution);
    return execution;
  }

  endExecution(execution: vscode.TaskExecution): void {
    for (const [key, activeExecution] of this.activeExecutions) {
      if (activeExecution === execution) {
        this.activeExecutions.delete(key);
      }
    }
  }

  dispose(): void {
    for (const execution of this.activeExecutions.values()) {
      execution.terminate();
    }
    this.activeExecutions.clear();
  }
}

export function registerVTasks(context: vscode.ExtensionContext): VTaskManager {
  const manager = new VTaskManager();
  context.subscriptions.push(vscode.tasks.registerTaskProvider('v', new VTaskProvider()));
  context.subscriptions.push(
    vscode.commands.registerCommand('vls.build', () => runPaletteTask('build', manager)),
    vscode.commands.registerCommand('vls.run', () => runPaletteTask('run', manager)),
    vscode.commands.registerCommand('vls.test', () => runPaletteTask('test', manager)),
    vscode.tasks.onDidEndTask((event) => {
      manager.endExecution(event.execution);
    }),
    manager
  );
  return manager;
}
