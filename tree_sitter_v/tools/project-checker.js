const Parser = require('tree-sitter');
const V = require('../bindings/node');
const glob = require('glob');
const path = require('path');
const fs = require('fs');
const { promisify } = require('util');
const chalk = require('chalk');
const argv = require('minimist')(process.argv.slice(2));

const vProject = argv._[0] || null;
const hideRanges = argv.hideRanges || false; 
const shouldExportJson = argv.json || false;
const parser = new Parser();
parser.setLanguage(V);

if (!vProject) {
  throw Error('V project not found!');
}

// skip test files for now
const filesToParse = glob.sync(path.join('**', '!(*_test|*_bare|*.js).v'), {
  ignore: ['+(tests|js)'],
  cwd: vProject,
  absolute: true
}).filter(filePath => !filePath.includes('tests') && !filePath.includes('js'));
const longestLen =  Math.max(...filesToParse.map(f => path.relative(vProject, f).length));

function walkAndReportErrors(node, file) {
  let errors = [];
  const cursor = node.walk();

  do {
    const currentNode = cursor.currentNode;
    if (currentNode.hasError() && (currentNode.type == 'ERROR' || currentNode.isMissing())) {
      errors.push({ 
        file: file, 
        range: [
          currentNode.startPosition, 
          currentNode.endPosition
        ]
      });
    }
    if (currentNode.childCount != 0) {
      for (const childNode of node.children) {
        errors.push(...walkAndReportErrors(childNode, file));
      }
    }
  } while (cursor.gotoNextSibling());
  return errors;
}

async function parseAndReportErrors(file) {
  const content = await promisify(fs.readFile)(file, { encoding: 'utf-8' });
  const tree = parser.parse(content);
  const rootNode = tree.rootNode;
  return walkAndReportErrors(rootNode, path.relative(vProject, file));
}

console.log('==============================================');
console.log(`V project: ${vProject}`);
console.log('==============================================');

Promise.all(filesToParse.map(parseAndReportErrors))
  .then((collection) => {
    let errorCount = 0;
    collection.forEach((errors, i) => {
      if (errors.length != 0) {
        errorCount++;
      }
      if (hideRanges) {
        const outcome = errors.length == 0 ? chalk.green`[Pass ]` : chalk.red`[Error]`;
        const filepath = errors.length == 0 ? path.relative(vProject, filesToParse[i]) : errors[0].file;
        process.stderr.write(`${outcome} file: ${filepath.padEnd(longestLen)} | errors: ${errors.length}\n`);
      } else {
        const toText = (pos) => `:${pos.row + 1}:${pos.column + 1}`;
        errors.forEach((e) => {
          process.stderr.write(`[Error] file: ${e.file + toText(e.range[0])} - ${toText(e.range[1])}\n`);
        });
        if (errors.length != 0) {
          process.stderr.write('\n');
        }
      }
    });
    console.log('==============================================\n\nSummary:')
    console.log(`${errorCount} files were not parsed properly by the Tree-sitter parser.`);
    return {
      dir: vProject,
      totalFiles: collection.length,
      totalPassed: collection.length - errorCount,
      totalFail: errorCount
    };
  }).then((report) => {
    const reportJson = JSON.stringify(report);
    const hasErrors = report.totalFail != 0;
    return Promise.all([
      shouldExportJson ? promisify(fs.writeFile)(path.join(process.cwd(), 'report.json'), reportJson) : Promise.resolve(),
      Promise.resolve(hasErrors)
    ]);
  }).then(([_, hasErrors]) => process.exit(+hasErrors));