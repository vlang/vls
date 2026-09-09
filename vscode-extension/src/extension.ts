import * as vscode from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient/node';
import * as fs from 'fs';
import {
  findInPath,
  registerVTasks,
  runCodeLensCommand,
  vCommandForServer,
} from './vTasks';

let client: LanguageClient | undefined;

function isInlayHintsEnabled(): boolean {
  return vscode.workspace.getConfiguration('vls').get<boolean>('inlayHints.enabled', true);
}

function isExecutable(filePath: string): boolean {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

export async function activate(context: vscode.ExtensionContext) {
  registerVTasks(context);

  // Get the configuration for our server.
  const config = vscode.workspace.getConfiguration('vls');
  let vlsPath = config.get<string>('command');
  const vlsArgs = config.get<string[]>('args', []);

  // If not set, try to find 'vls' in PATH.
  if (!vlsPath) {
    const found = findInPath('vls');
    if (!found) {
      vscode.window.showErrorMessage(
        'VLS binary not found. Set "vls.command" in your settings or ensure "vls" is in your PATH.'
      );
      return;
    }
    vlsPath = found;
  }

  // Check if the path to the VLS executable exists and is executable.
  if (!fs.existsSync(vlsPath)) {
    vscode.window.showErrorMessage(
      `VLS binary not found at path: ${vlsPath}. Set "vls.command" in your settings.`
    );
    return;
  }
  if (!isExecutable(vlsPath)) {
    vscode.window.showErrorMessage(
      `VLS binary at path: ${vlsPath} is not executable. Fix permissions or set "vls.command".`
    );
    return;
  }

  const serverEnvironment = { ...process.env };
  const vCommand = vCommandForServer();
  if (vCommand) {
    serverEnvironment.VLS_V_COMMAND = vCommand;
  }
  const serverOptions: ServerOptions = {
    run: { command: vlsPath, args: vlsArgs, options: { env: serverEnvironment } },
    debug: { command: vlsPath, args: vlsArgs, options: { env: serverEnvironment } },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: 'file', language: 'v' }],
    synchronize: {
      configurationSection: 'vls',
      fileEvents: vscode.workspace.createFileSystemWatcher('**/*.v'),
    },
    middleware: {
      provideInlayHints: async (document, range, token, next) => {
        if (!isInlayHintsEnabled()) {
          return [];
        }
        return next(document, range, token);
      },
      executeCommand: async (command, args, next) => {
        if (command === 'vls.runFile' || command === 'vls.runTests') {
          await runCodeLensCommand(command, args);
          return;
        }
        return next(command, args);
      },
    },
  };

  client = new LanguageClient('vls', 'V Language Server', serverOptions, clientOptions);

  // A standalone provider whose sole purpose is to fire onDidChangeInlayHints so
  // that VS Code immediately re-requests hints from all providers (including the
  // LSP one above) whenever the toggle setting changes.
  const inlayHintsEmitter = new vscode.EventEmitter<void>();
  context.subscriptions.push(inlayHintsEmitter);
  context.subscriptions.push(
    vscode.languages.registerInlayHintsProvider(
      { scheme: 'file', language: 'v' },
      {
        onDidChangeInlayHints: inlayHintsEmitter.event,
        provideInlayHints: () => [],
      }
    )
  );

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration('vls.inlayHints.enabled')) {
        inlayHintsEmitter.fire();
      }
    })
  );

  vscode.window.showInformationMessage('V Language Server is starting.');
  await client.start();
  vscode.window.showInformationMessage('V Language Server is now active.');
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
