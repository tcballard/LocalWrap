'use strict';

const js = require('@eslint/js');
const globals = require('globals');
const prettier = require('eslint-config-prettier');

module.exports = [
  { ignores: ['node_modules/**', 'dist/**', 'build/**'] },

  js.configs.recommended,

  // Don't flag intentionally-unused catch bindings / `_`-prefixed args.
  {
    rules: {
      'no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_', caughtErrors: 'none' },
      ],
    },
  },

  // Electron main + shared libs (Node, CommonJS).
  {
    files: [
      'main.js',
      'lib/**/*.js',
      'scripts/**/*.js',
      'examples/**/*.js',
      'jest.config.js',
      'eslint.config.js',
    ],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'commonjs',
      globals: { ...globals.node },
    },
  },

  // Preload runs in the renderer but with Node/CommonJS available.
  {
    files: ['preload.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'commonjs',
      globals: { ...globals.node, ...globals.browser },
    },
  },

  // Renderer code (browser).
  {
    files: ['public/**/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'script',
      globals: { ...globals.browser },
    },
  },

  // Tests (Jest + Node).
  {
    files: ['__tests__/**/*.js', 'jest.setup.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'commonjs',
      globals: { ...globals.node, ...globals.jest },
    },
  },

  // Turn off stylistic rules that conflict with Prettier.
  prettier,
];
