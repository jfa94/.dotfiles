import eslint from '@eslint/js'
import {defineConfig, globalIgnores} from 'eslint/config'
import tseslint from 'typescript-eslint'
import prettierRecommended from 'eslint-plugin-prettier/recommended'
import pluginSecurity from 'eslint-plugin-security'
import globals from 'globals'

export default defineConfig(
    globalIgnores(['node_modules/', 'dist/', 'coverage/', '**/*.d.ts', '.dependency-cruiser.*', '.claude/']),

    eslint.configs.recommended,
    prettierRecommended,

    // TypeScript: strictest type-checked linting
    {
        files: ['**/*.ts'],
        extends: [tseslint.configs.strictTypeChecked, tseslint.configs.stylisticTypeChecked],
        plugins: {
            '@typescript-eslint': tseslint.plugin,
        },
        languageOptions: {
            parser: tseslint.parser,
            parserOptions: {
                projectService: true,
                tsconfigRootDir: import.meta.dirname,
            },
            globals: {...globals.node},
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

            // Naming conventions (camelCase vars, PascalCase types)
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
                    format: ['camelCase', 'PascalCase'],
                },
                {
                    selector: 'import',
                    format: ['camelCase', 'PascalCase'], // allow both for imports
                },
            ],

            // Slash comments only (no block comments)
            'multiline-comment-style': ['error', 'separate-lines'],

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

    // Disable type-checked for JS config files
    {
        files: ['**/*.js', '**/*.mjs', '**/*.cjs'],
        extends: [tseslint.configs.disableTypeChecked],
    }
)
