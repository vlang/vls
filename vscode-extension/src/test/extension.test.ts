import * as assert from 'assert';
import * as fs from 'fs';
import * as path from 'path';
import {
  codeLensTaskSpec,
  shouldSaveTaskDocument,
  workspaceTaskSpec,
} from '../taskSpec';

describe('VLS VS Code extension', () => {
  it('contributes build, run, and test commands and tasks', () => {
    const packagePath = path.resolve(__dirname, '..', '..', 'package.json');
    const manifest = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
    const commands = manifest.contributes.commands.map((entry: { command: string }) => {
      return entry.command;
    });
    assert.deepStrictEqual(commands, ['vls.build', 'vls.run', 'vls.test']);

    const taskDefinition = manifest.contributes.taskDefinitions[0];
    assert.strictEqual(taskDefinition.type, 'v');
    assert.deepStrictEqual(taskDefinition.properties.action.enum, ['build', 'run', 'test']);
    assert.ok(manifest.contributes.configuration.properties['vls.vCommand']);
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
});
