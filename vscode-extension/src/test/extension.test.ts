import * as assert from 'assert';
import * as fs from 'fs';
import * as path from 'path';
import { codeLensTaskSpec, workspaceTaskSpec } from '../taskSpec';

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
});
