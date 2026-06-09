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

  test('is bundled into packaged apps as an extra resource', () => {
    const packageJson = JSON.parse(
      fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8')
    );

    expect(packageJson.build.extraResources).toContainEqual({
      from: 'examples/sample-project',
      to: 'sample-project',
    });
  });
});
