import * as vscode from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient/node';

let client: LanguageClient;

function isInlayHintsEnabled(): boolean {
  return vscode.workspace.getConfiguration('vls').get<boolean>('inlayHints.enabled', true);
}

export async function activate(context: vscode.ExtensionContext) {
  // Get the configuration for our server.
  const config = vscode.workspace.getConfiguration('vls');
  const vlsPath = config.get<string>('command');

  // Check if the path to the VLS executable is configured.
  if (!vlsPath) {
    vscode.window.showErrorMessage(
      'The path to the V language server binary is not set. Please set "vls.command" in your settings.'
    );
    return;
  }

  // ServerOptions tells the client how to launch our server.
  // We are launching it as a normal process and communicating via stdio.
  const serverOptions: ServerOptions = {
    run: { command: vlsPath },
    debug: { command: vlsPath }, // You can specify different flags for debugging
  };

  // ClientOptions controls the client-side of the connection.
  const clientOptions: LanguageClientOptions = {
    // Register the server for `v` documents.
    documentSelector: [{ scheme: 'file', language: 'v' }],
    // Synchronize the 'files' section of settings between client and server.
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/*.v'),
    },
    middleware: {
      provideInlayHints: async (document, range, token, next) => {
        if (!isInlayHintsEnabled()) {
          return [];
        }
        return next(document, range, token);
      },
    },
  };

  // Create the language client.
  client = new LanguageClient(
    'vls',
    'V Language Server',
    serverOptions,
    clientOptions
  );

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
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('vls.inlayHints.enabled')) {
        inlayHintsEmitter.fire();
      }
    })
  );

  // Start the client. This will also launch the server.
  vscode.window.showInformationMessage('V Language Server is starting.');
  await client.start();
  vscode.window.showInformationMessage('V Language Server is now active.');
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  // Stop the client. This will also terminate the server process.
  return client.stop();
}
