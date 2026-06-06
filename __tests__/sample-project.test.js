const fs = require('fs');
const path = require('path');
const { discoverPackageScripts } = require('../lib/packageScripts');

describe('sample project', () => {
  const sampleDir = path.join(__dirname, '..', 'examples', 'sample-project');

  test('is dependency-free and discoverable by LocalWrap', () => {
    const packageJson = JSON.parse(fs.readFileSync(path.join(sampleDir, 'package.json'), 'utf8'));

    expect(packageJson.dependencies).toBeUndefined();
    expect(packageJson.devDependencies).toBeUndefined();
    expect(discoverPackageScripts(sampleDir).map((script) => script.command)).toEqual([
      'npm run dev',
      'npm start',
      'npm run preview',
    ]);
  });
});
