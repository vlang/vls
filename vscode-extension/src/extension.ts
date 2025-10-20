import * as vscode from 'vscode';
import { LanguageClient, LanguageClientOptions, ServerOptions } from 'vscode-languageclient/node';

let client: LanguageClient;

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
  };

  // Create the language client.
  client = new LanguageClient(
    'vls',
    'V Language Server',
    serverOptions,
    clientOptions
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
