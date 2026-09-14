import { execFile } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import * as vscode from 'vscode';
import {
  canonicalFilePath,
  CoverageProfile,
  fileModificationStateMatches,
  FileModificationState,
  parseLcovProfile,
  readFileModificationState,
  seedDirtyFileInvalidations,
} from './coverageProfile';

interface CoverageTaskDefinition extends vscode.TaskDefinition {
  coverageCommand?: string;
  coverageDirectory?: string;
  coverageRoot?: string;
}

const coverageTempRoot = path.join(os.tmpdir(), 'vls-coverage');

function isPathInside(filePath: string, root: string): boolean {
  const relativePath = path.relative(canonicalFilePath(root), canonicalFilePath(filePath));
  return (
    relativePath === '' ||
    (relativePath !== '..' &&
      !relativePath.startsWith(`..${path.sep}`) &&
      !path.isAbsolute(relativePath))
  );
}

function hasCounterFile(directory: string): boolean {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(directory, { withFileTypes: true });
  } catch {
    return false;
  }
  for (const entry of entries) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory() && hasCounterFile(entryPath)) {
      return true;
    }
    if (entry.isFile() && entry.name.startsWith('vcounters_') && entry.name.endsWith('.csv')) {
      return true;
    }
  }
  return false;
}

function runCoverageConverter(
  command: string,
  coverageDirectory: string,
  reportPath: string,
  workingDirectory: string
): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile(
      command,
      ['cover', coverageDirectory, '--lcov', reportPath, '-P', 'false'],
      { cwd: workingDirectory, maxBuffer: 4 * 1024 * 1024 },
      (error) => (error ? reject(error) : resolve())
    );
  });
}

export class CoverageDecorationController implements vscode.Disposable {
  private readonly coveredDecoration = vscode.window.createTextEditorDecorationType({
    isWholeLine: true,
    backgroundColor: 'rgba(46, 160, 67, 0.20)',
    overviewRulerColor: 'rgba(46, 160, 67, 0.95)',
    overviewRulerLane: vscode.OverviewRulerLane.Left,
  });
  private readonly uncoveredDecoration = vscode.window.createTextEditorDecorationType({
    isWholeLine: true,
    backgroundColor: 'rgba(248, 81, 73, 0.20)',
    overviewRulerColor: 'rgba(248, 81, 73, 0.95)',
    overviewRulerLane: vscode.OverviewRulerLane.Left,
  });
  private readonly status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 10);
  private readonly allocatedDirectories = new Set<string>();
  private readonly executionGenerations = new Map<vscode.TaskExecution, number>();
  private readonly changedFiles = new Map<string, number>();
  private readonly profileFileStates = new Map<string, FileModificationState>();
  private readonly disposables: vscode.Disposable[];
  private profile: CoverageProfile = new Map();
  private nextGeneration = 0;
  private currentGeneration = 0;

  constructor() {
    this.status.name = 'V Test Coverage';
    this.status.command = 'vls.coverage.clear';
    this.disposables = [
      vscode.window.onDidChangeVisibleTextEditors(() => this.refreshVisibleEditors()),
      vscode.window.onDidChangeActiveTextEditor((editor) => {
        if (editor) {
          this.decorateEditor(editor);
        }
      }),
      vscode.workspace.onDidChangeTextDocument((event) => {
        if (event.document.uri.scheme !== 'file') {
          return;
        }
        const filePath = canonicalFilePath(event.document.uri.fsPath);
        this.changedFiles.set(filePath, this.currentGeneration);
        if (this.profile.delete(filePath)) {
          this.profileFileStates.delete(filePath);
          this.refreshVisibleEditors();
          this.updateStatus();
        }
      }),
      vscode.workspace.onDidChangeConfiguration((event) => {
        if (event.affectsConfiguration('vls.coverage.enabled')) {
          this.clear();
        }
      }),
    ];
  }

  createTaskDirectory(folder?: vscode.WorkspaceFolder): string | undefined {
    const enabled = vscode.workspace
      .getConfiguration('vls', folder?.uri)
      .get<boolean>('coverage.enabled', true);
    if (!enabled) {
      return undefined;
    }
    const directory = path.join(
      coverageTempRoot,
      `${process.pid}-${Date.now()}-${Math.random().toString(16).slice(2)}`
    );
    this.allocatedDirectories.add(directory);
    return directory;
  }

  beginTask(execution: vscode.TaskExecution): void {
    const directory = this.taskDirectory(execution.task);
    if (!directory) {
      return;
    }
    const generation = ++this.nextGeneration;
    this.currentGeneration = generation;
    this.executionGenerations.set(execution, generation);
    seedDirtyFileInvalidations(
      this.changedFiles,
      vscode.workspace.textDocuments
        .filter((document) => document.uri.scheme === 'file')
        .map((document) => ({ filePath: document.uri.fsPath, isDirty: document.isDirty })),
      generation
    );
    this.clearDecorations();
    try {
      fs.mkdirSync(directory, { recursive: true });
    } catch (error) {
      vscode.window.showWarningMessage(`VLS could not prepare test coverage: ${String(error)}`);
    }
  }

  async endTask(execution: vscode.TaskExecution): Promise<void> {
    const directory = this.taskDirectory(execution.task);
    const generation = this.executionGenerations.get(execution);
    this.executionGenerations.delete(execution);
    if (!directory || generation === undefined) {
      return;
    }

    try {
      if (!hasCounterFile(directory)) {
        return;
      }
      const definition = execution.task.definition as CoverageTaskDefinition;
      const command = definition.coverageCommand;
      const root = definition.coverageRoot;
      if (!command || !root) {
        return;
      }
      const reportPath = path.join(directory, 'coverage.lcov');
      await runCoverageConverter(command, directory, reportPath, root);
      const parsed = parseLcovProfile(fs.readFileSync(reportPath, 'utf8'), root);
      if (generation !== this.currentGeneration) {
        return;
      }
      this.profile = new Map(
        [...parsed].filter(
          ([filePath]) =>
            filePath.endsWith('.v') &&
            isPathInside(filePath, root) &&
            this.changedFiles.get(filePath) !== generation
        )
      );
      this.profileFileStates.clear();
      for (const filePath of [...this.profile.keys()]) {
        const state = readFileModificationState(filePath);
        if (state) {
          this.profileFileStates.set(filePath, state);
        } else {
          this.profile.delete(filePath);
        }
      }
      this.refreshVisibleEditors();
      this.updateStatus();
    } catch (error) {
      if (generation === this.currentGeneration) {
        vscode.window.showWarningMessage(`VLS could not load test coverage: ${String(error)}`);
      }
    } finally {
      try {
        fs.rmSync(directory, { recursive: true, force: true });
      } catch {
        // The system can clean up an abandoned temporary coverage directory.
      }
    }
  }

  clear(): void {
    this.currentGeneration = ++this.nextGeneration;
    this.changedFiles.clear();
    this.clearDecorations();
  }

  dispose(): void {
    this.currentGeneration = ++this.nextGeneration;
    for (const disposable of this.disposables) {
      disposable.dispose();
    }
    this.coveredDecoration.dispose();
    this.uncoveredDecoration.dispose();
    this.status.dispose();
    for (const directory of this.allocatedDirectories) {
      try {
        fs.rmSync(directory, { recursive: true, force: true });
      } catch {
        // The system can clean up an abandoned temporary coverage directory.
      }
    }
  }

  private taskDirectory(task: vscode.Task): string | undefined {
    const directory = (task.definition as CoverageTaskDefinition).coverageDirectory;
    return directory && this.allocatedDirectories.has(directory) ? directory : undefined;
  }

  private clearDecorations(): void {
    this.profile.clear();
    this.profileFileStates.clear();
    this.status.hide();
    this.refreshVisibleEditors();
  }

  private refreshVisibleEditors(): void {
    for (const editor of vscode.window.visibleTextEditors) {
      this.decorateEditor(editor);
    }
  }

  private decorateEditor(editor: vscode.TextEditor): void {
    if (editor.document.uri.scheme !== 'file' || editor.document.languageId !== 'v') {
      editor.setDecorations(this.coveredDecoration, []);
      editor.setDecorations(this.uncoveredDecoration, []);
      return;
    }
    const filePath = canonicalFilePath(editor.document.uri.fsPath);
    let coverage = this.profile.get(filePath);
    const fileState = this.profileFileStates.get(filePath);
    if (coverage && (!fileState || !fileModificationStateMatches(filePath, fileState))) {
      this.profile.delete(filePath);
      this.profileFileStates.delete(filePath);
      this.updateStatus();
      coverage = undefined;
    }
    editor.setDecorations(this.coveredDecoration, this.lineRanges(editor, coverage?.covered || []));
    editor.setDecorations(
      this.uncoveredDecoration,
      this.lineRanges(editor, coverage?.uncovered || [])
    );
  }

  private lineRanges(editor: vscode.TextEditor, oneBasedLines: number[]): vscode.Range[] {
    return oneBasedLines
      .filter((line) => line <= editor.document.lineCount)
      .map((line) => new vscode.Range(line - 1, 0, line - 1, 0));
  }

  private updateStatus(): void {
    let covered = 0;
    let uncovered = 0;
    for (const fileCoverage of this.profile.values()) {
      covered += fileCoverage.covered.length;
      uncovered += fileCoverage.uncovered.length;
    }
    const total = covered + uncovered;
    if (total === 0) {
      this.status.hide();
      return;
    }
    const percent = Math.round((100 * covered) / total);
    this.status.text = `$(beaker) Coverage ${percent}%`;
    this.status.tooltip = `${covered} covered and ${uncovered} uncovered executable lines. Click to clear.`;
    this.status.show();
  }
}
