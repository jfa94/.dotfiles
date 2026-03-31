import eslint from '@eslint/js'
import {defineConfig, globalIgnores} from 'eslint/config'
import tseslint from 'typescript-eslint'
import prettierRecommended from 'eslint-plugin-prettier/recommended'
import pluginSecurity from 'eslint-plugin-security'
import boundaries from 'eslint-plugin-boundaries'
import noRelativeImportPaths from 'eslint-plugin-no-relative-import-paths'
import globals from 'globals'

export default defineConfig(
    globalIgnores(['node_modules/', '.next/', 'out/', 'dist/', 'coverage/', '**/*.d.ts', '.dependency-cruiser.*', '.claude/']),

    eslint.configs.recommended,
    prettierRecommended,

    // TypeScript: strictest type-checked linting
    {
        files: ['**/*.ts', '**/*.tsx'],
        extends: [tseslint.configs.strictTypeChecked, tseslint.configs.stylisticTypeChecked],
        plugins: {
            '@typescript-eslint': tseslint.plugin,
            'no-relative-import-paths': noRelativeImportPaths,
        },
        languageOptions: {
            parser: tseslint.parser,
            parserOptions: {
                projectService: true,
                tsconfigRootDir: import.meta.dirname,
            },
            globals: {...globals.node, ...globals.browser},
        },
        rules: {
            // Type safety — zero tolerance for unsafe operations
            '@typescript-eslint/no-explicit-any': 'error',
            '@typescript-eslint/no-unsafe-assignment': 'error',
            '@typescript-eslint/no-unsafe-call': 'error',
            '@typescript-eslint/no-unsafe-member-access': 'error',
            '@typescript-eslint/no-unsafe-return': 'error',
            '@typescript-eslint/no-floating-promises': 'error',
            '@typescript-eslint/no-misused-promises': 'error',
            '@typescript-eslint/require-await': 'error',
            '@typescript-eslint/no-unnecessary-condition': 'error',
            '@typescript-eslint/strict-boolean-expressions': 'error',
            '@typescript-eslint/switch-exhaustiveness-check': 'error',
            '@typescript-eslint/no-non-null-assertion': 'error',
            '@typescript-eslint/consistent-type-imports': [
                'error',
                {
                    prefer: 'type-imports',
                    fixStyle: 'inline-type-imports',
                },
            ],

            // Naming conventions (camelCase vars, PascalCase components)
            '@typescript-eslint/naming-convention': [
                'error',
                {selector: 'default', format: ['camelCase']},
                {selector: 'variable', format: ['camelCase', 'UPPER_CASE', 'PascalCase']},
                {selector: 'parameter', format: ['camelCase'], leadingUnderscore: 'allow'},
                {selector: 'typeLike', format: ['PascalCase']},
                {selector: 'enumMember', format: ['PascalCase']},
                {selector: 'property', format: null}, // allow flexible object keys
                {
                    selector: 'function',
                    format: ['camelCase', 'PascalCase'], // PascalCase for React components
                },
                {
                    selector: 'import',
                    format: ['camelCase', 'PascalCase'], // allow both for imports
                },
            ],

            // Slash comments only (no block comments)
            'multiline-comment-style': ['error', 'separate-lines'],

            // Absolute imports only
            'no-relative-import-paths/no-relative-import-paths': [
                'error',
                {allowSameFolder: true, rootDir: 'src', prefix: '@'},
            ],

            // General quality
            'no-console': ['error', {allow: ['warn', 'error']}],
            eqeqeq: ['error', 'always'],
            curly: ['error', 'all'],
        },
    },

    // Security rules
    {
        plugins: {security: pluginSecurity},
        rules: {
            'security/detect-eval-with-expression': 'error',
            'security/detect-child-process': 'error',
            'security/detect-non-literal-fs-filename': 'warn',
            'security/detect-non-literal-require': 'warn',
            'security/detect-possible-timing-attacks': 'warn',
            'security/detect-unsafe-regex': 'error',
            'security/detect-buffer-noassert': 'error',
            'security/detect-pseudoRandomBytes': 'error',
            'security/detect-bidi-characters': 'error',
        },
    },

    // Architectural boundaries
    {
        files: ['src/**/*.ts', 'src/**/*.tsx'],
        plugins: {boundaries},
        settings: {
            'boundaries/elements': [
                {type: 'app', pattern: 'src/app/*', mode: 'folder'},
                {type: 'components', pattern: 'src/components/*', mode: 'folder'},
                {type: 'services', pattern: 'src/services/*', mode: 'folder'},
                {type: 'domain', pattern: 'src/domain/*', mode: 'folder'},
                {type: 'lib', pattern: 'src/lib/*', mode: 'folder'},
                {type: 'types', pattern: 'src/types/*', mode: 'folder'},
                {type: 'utils', pattern: 'src/utils/*', mode: 'folder'},
                {type: 'config', pattern: 'src/config/*', mode: 'folder'},
            ],
            'boundaries/ignore': ['**/*.test.ts', '**/*.test.tsx', '**/*.spec.ts'],
        },
        rules: {
            'boundaries/dependencies': [
                2,
                {
                    default: 'disallow',
                    rules: [
                        // App layer can import everything except domain internals
                        {from: {type: 'app'}, allow: [{to: {type: ['components', 'lib', 'services', 'domain', 'types', 'utils', 'config']}}]},
                        // Components: NO services (use hooks or server actions instead)
                        {from: {type: 'components'}, allow: [{to: {type: ['components', 'lib', 'domain', 'types', 'utils']}}]},
                        // Services: orchestration layer
                        {from: {type: 'services'}, allow: [{to: {type: ['domain', 'lib', 'types', 'utils', 'config']}}]},
                        // Domain: pure business logic, minimal deps
                        {from: {type: 'domain'}, allow: [{to: {type: ['types', 'utils']}}]},
                        // Infrastructure
                        {from: {type: 'lib'}, allow: [{to: {type: ['types', 'utils', 'config']}}]},
                        // Leaf nodes
                        {from: {type: 'types'}, allow: []},
                        {from: {type: 'utils'}, allow: [{to: {type: ['types']}}]},
                        {from: {type: 'config'}, allow: [{to: {type: ['types']}}]},
                    ],
                },
            ],
            'boundaries/no-unknown': 'error',
        },
    },

    // Disable type-checked for JS config files
    {
        files: ['**/*.js', '**/*.mjs', '**/*.cjs'],
        extends: [tseslint.configs.disableTypeChecked],
    }
)
