import * as assert from 'assert';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import {
  activeRunTaskSpec,
  codeLensTaskSpec,
  shouldSaveTaskDocument,
  standaloneTaskScope,
  taskCoverageRoot,
  taskWorkingDirectory,
  workspaceTaskSpec,
} from '../taskSpec';
import { serverCommand } from '../vCommand';
import {
  canonicalFilePath,
  fileModificationStateMatches,
  instrumentCoverageArgs,
  parseLcovProfile,
  readFileModificationState,
  seedDirtyFileInvalidations,
  snapshotVSourceFiles,
} from '../coverageProfile';

describe('VLS VS Code extension', () => {
  it('contributes build, run, and test commands and tasks', () => {
    const packagePath = path.resolve(__dirname, '..', '..', 'package.json');
    const manifest = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
    const commands = manifest.contributes.commands.map((entry: { command: string }) => {
      return entry.command;
    });
    assert.deepStrictEqual(commands, [
      'vls.build',
      'vls.run',
      'vls.test',
      'vls.coverage.clear',
    ]);

    const taskDefinition = manifest.contributes.taskDefinitions[0];
    assert.strictEqual(taskDefinition.type, 'v');
    assert.deepStrictEqual(taskDefinition.properties.action.enum, ['build', 'run', 'test']);
    assert.ok(manifest.contributes.configuration.properties['vls.vCommand']);
    assert.strictEqual(
      manifest.contributes.configuration.properties['vls.coverage.enabled'].default,
      true
    );
  });

  it('instruments V test arguments with an isolated coverage directory', () => {
    assert.deepStrictEqual(
      instrumentCoverageArgs(['-nocolor', 'test', '.'], '/tmp/vls-coverage/run'),
      [
        '-no-skip-unused',
        '-coverage',
        '/tmp/vls-coverage/run',
        '-nocolor',
        'test',
        '.',
      ]
    );
  });

  it('parses and merges covered and uncovered LCOV lines', () => {
    const profile = parseLcovProfile(
      [
        'TN:',
        'SF:src/example.v',
        'DA:8,0',
        'DA:3,2',
        'end_of_record',
        'SF:src/example.v',
        'DA:8,1',
        'DA:12,0',
        'end_of_record',
      ].join('\n'),
      '/workspace'
    );

    assert.deepStrictEqual(profile.get(path.normalize('/workspace/src/example.v')), {
      covered: [3, 8],
      uncovered: [12],
    });
  });

  it('canonicalizes relative LCOV paths through workspace symlinks', () => {
    const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'vls-coverage-profile-'));
    const realWorkspace = path.join(temporaryRoot, 'real-workspace');
    const linkedWorkspace = path.join(temporaryRoot, 'linked-workspace');
    const sourceDirectory = path.join(realWorkspace, 'src');
    const sourceFile = path.join(sourceDirectory, 'example.v');
    try {
      fs.mkdirSync(sourceDirectory, { recursive: true });
      fs.writeFileSync(sourceFile, 'module example\n');
      fs.symlinkSync(
        realWorkspace,
        linkedWorkspace,
        process.platform === 'win32' ? 'junction' : 'dir'
      );

      const profile = parseLcovProfile('SF:src/example.v\nDA:1,1\nend_of_record', linkedWorkspace);

      assert.ok(profile.has(canonicalFilePath(sourceFile)));
      assert.ok(!profile.has(path.join(linkedWorkspace, 'src', 'example.v')));
    } finally {
      fs.rmSync(temporaryRoot, { recursive: true, force: true });
    }
  });

  it('carries dirty document invalidations into a new test generation', () => {
    const changedFiles = new Map<string, number>([
      [canonicalFilePath('/workspace/previous.v'), 2],
    ]);

    seedDirtyFileInvalidations(
      changedFiles,
      [
        { filePath: '/workspace/dirty.v', isDirty: true },
        { filePath: '/workspace/clean.v', isDirty: false },
      ],
      3
    );

    assert.deepStrictEqual([...changedFiles], [[canonicalFilePath('/workspace/dirty.v'), 3]]);
  });

  it('detects external filesystem modifications to covered files', () => {
    const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'vls-coverage-state-'));
    const sourceFile = path.join(temporaryRoot, 'example.v');
    try {
      fs.writeFileSync(sourceFile, 'module example\n');
      const state = readFileModificationState(sourceFile);
      assert.ok(state);
      assert.ok(fileModificationStateMatches(sourceFile, state));

      fs.writeFileSync(sourceFile, 'module example\n\nfn changed() {}\n');
      assert.ok(!fileModificationStateMatches(sourceFile, state));
    } finally {
      fs.rmSync(temporaryRoot, { recursive: true, force: true });
    }
  });

  it('rejects source files changed after the coverage run begins', () => {
    const temporaryRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'vls-coverage-start-state-'));
    const sourceDirectory = path.join(temporaryRoot, 'src');
    const sourceFile = path.join(sourceDirectory, 'example.v');
    try {
      fs.mkdirSync(sourceDirectory, { recursive: true });
      fs.writeFileSync(sourceFile, 'module example\n');
      const startStates = snapshotVSourceFiles(temporaryRoot);
      const startState = startStates.get(canonicalFilePath(sourceFile));
      assert.ok(startState);

      fs.writeFileSync(sourceFile, 'module example\n\nfn changed_during_test() {}\n');
      assert.ok(!fileModificationStateMatches(sourceFile, startState));
    } finally {
      fs.rmSync(temporaryRoot, { recursive: true, force: true });
    }
  });

  it('defines the preconfigured workspace task arguments', () => {
    assert.deepStrictEqual(workspaceTaskSpec('build'), {
      action: 'build',
      args: ['-nocolor', '.'],
      name: 'Build',
    });
    assert.deepStrictEqual(workspaceTaskSpec('run'), {
      action: 'run',
      args: ['-nocolor', 'run', '.'],
      name: 'Run',
    });
    assert.deepStrictEqual(workspaceTaskSpec('test'), {
      action: 'test',
      args: ['-nocolor', 'test', '.'],
      name: 'Test',
    });
  });

  it('maps CodeLens actions to V task arguments', () => {
    assert.deepStrictEqual(codeLensTaskSpec('vls.runFile', '/tmp/main.v', ''), {
      action: 'run',
      args: ['-nocolor', 'run', '.'],
      name: 'Run Main',
    });
    assert.deepStrictEqual(codeLensTaskSpec('vls.runTests', '/tmp/main_test.v', ''), {
      action: 'test',
      args: ['-nocolor', 'test', '/tmp/main_test.v'],
      name: 'Run Test File',
    });
    assert.deepStrictEqual(codeLensTaskSpec('vls.runTests', '/tmp/main_test.v', 'test_one'), {
      action: 'test',
      args: ['-nocolor', 'test', '/tmp/main_test.v', '-run-only', 'test_one'],
      name: 'Run Test: test_one',
    });
  });

  it('saves dirty V buffers in the CodeLens workspace before running', () => {
    const target = '/workspace/app/main.v';
    const workspace = '/workspace';
    const document = (filePath: string, languageId = 'v', isDirty = true) => ({
      filePath,
      languageId,
      isDirty,
    });

    assert.ok(shouldSaveTaskDocument(target, workspace, document(target)));
    assert.ok(shouldSaveTaskDocument(target, workspace, document('/workspace/app/sibling.v')));
    assert.ok(shouldSaveTaskDocument(target, workspace, document('/workspace/lib/imported.v')));
    assert.ok(shouldSaveTaskDocument(target, workspace, document('/workspace/tool.vsh', 'shellscript')));
    assert.ok(!shouldSaveTaskDocument(target, workspace, document('/workspace/app/clean.v', 'v', false)));
    assert.ok(!shouldSaveTaskDocument(target, workspace, document('/workspace/notes.txt', 'plaintext')));
    assert.ok(!shouldSaveTaskDocument(target, workspace, document('/other/workspace/dirty.v')));
  });

  it('limits standalone CodeLens saves to the target module tree', () => {
    const target = '/project/module/main.v';
    const dirtyVDocument = (filePath: string) => ({ filePath, languageId: 'v', isDirty: true });

    assert.ok(
      shouldSaveTaskDocument(target, undefined, dirtyVDocument('/project/module/sibling.v'))
    );
    assert.ok(
      shouldSaveTaskDocument(target, undefined, dirtyVDocument('/project/module/lib/imported.v'))
    );
    assert.ok(
      !shouldSaveTaskDocument(target, undefined, dirtyVDocument('/project/other/dirty.v'))
    );
  });

  it('uses the nearest V project root for standalone saves and coverage', () => {
    const target = '/project/cmd/app/main.v';
    const vmodExists = (filePath: string) => {
      return filePath === path.normalize('/project/v.mod');
    };
    const projectRoot = standaloneTaskScope(target, vmodExists);
    const dirtyImport = {
      filePath: '/project/lib/foo/foo.v',
      languageId: 'v',
      isDirty: true,
    };

    assert.strictEqual(projectRoot, path.normalize('/project'));
    assert.strictEqual(taskCoverageRoot(target, undefined, vmodExists), projectRoot);
    assert.strictEqual(taskWorkingDirectory(target), path.normalize('/project/cmd/app'));
    assert.ok(shouldSaveTaskDocument(target, projectRoot, dirtyImport));
    assert.strictEqual(
      standaloneTaskScope(target, () => false),
      path.normalize('/project/cmd/app')
    );
  });

  it('runs active V scripts directly', () => {
    assert.deepStrictEqual(activeRunTaskSpec('/workspace/tools/deploy.vsh', '/workspace'), {
      action: 'run',
      args: ['-nocolor', 'run', path.join('tools', 'deploy.vsh')],
      name: 'Run Active Script',
    });
    assert.deepStrictEqual(activeRunTaskSpec('/workspace/app/main.v', '/workspace'), {
      action: 'run',
      args: ['-nocolor', 'run', 'app'],
      name: 'Run Active Module',
    });
  });

  it('runs nested modules from the problem matcher base', () => {
    const filePath = path.join('/workspace', 'cmd', 'app', 'main.v');
    const workingDirectory = taskWorkingDirectory(filePath, '/workspace');
    assert.strictEqual(workingDirectory, '/workspace');
    assert.deepStrictEqual(codeLensTaskSpec('vls.runFile', filePath, '', workingDirectory), {
      action: 'run',
      args: ['-nocolor', 'run', path.join('cmd', 'app')],
      name: 'Run Main',
    });
  });

  it('scopes and preserves the configured server compiler', () => {
    const configured = path.join('${workspaceFolder}', 'bin', 'v');
    assert.strictEqual(
      serverCommand(configured, '/workspace'),
      path.join('/workspace', 'bin', 'v')
    );
    const missing = path.join('/missing', 'custom-v');
    assert.strictEqual(serverCommand(missing, '/workspace'), missing);
  });
});
