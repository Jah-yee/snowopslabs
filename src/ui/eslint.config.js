// SPDX-License-Identifier: Apache-2.0
//
// The UI's lint gate: TypeScript's recommended rules, the rules of hooks, and
// the static accessibility rules jsx-a11y can check without rendering.
import js from '@eslint/js'
import globals from 'globals'
import tseslint from 'typescript-eslint'
import reactHooks from 'eslint-plugin-react-hooks'
import jsxA11y from 'eslint-plugin-jsx-a11y'

export default tseslint.config(
  { ignores: ['dist', 'coverage', 'playwright-report', 'test-results'] },
  {
    files: ['**/*.{ts,tsx}'],
    extends: [js.configs.recommended, ...tseslint.configs.recommended, jsxA11y.flatConfigs.recommended],
    languageOptions: {
      ecmaVersion: 2022,
      globals: { ...globals.browser, ...globals.node },
    },
    plugins: { 'react-hooks': reactHooks },
    rules: {
      ...reactHooks.configs.recommended.rules,
      // The command output is a scrollable log region; axe requires a
      // keyboard user to be able to focus it to scroll.
      'jsx-a11y/no-noninteractive-tabindex': ['error', { roles: ['tabpanel', 'log'] }],
      // A name that starts with an underscore is unused on purpose.
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_' }],
    },
  },
)
