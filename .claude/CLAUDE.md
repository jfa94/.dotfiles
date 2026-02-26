- In all interactions and commit messages, be concise and sacrifice grammar for the sake of concision.

## Plans

- At the end of each plan, give me a list of unresolved questions to answer, if any. Make the questions extremely concise.

## Tech Stack

- **Frontend:** TypeScript, React, Next.js (App Router), Tailwind CSS
- **Analytics:** PostHog
- **Payments:** Stripe
- **Icons:** Lucide

## Coding Standards

- No semicolons unless necessary.
- Use standard naming conventions (e.g., camelCase for variables/functions, PascalCase for components).
- Single quotes for strings.
- Function-based React components with arrow functions for callbacks.
- async/await for asynchronous operations.
- `//` comments only (no block comments) in JS/TS files.
- Absolute imports with module path aliases (e.g., `@/components/Button`).
- API keys in `.env` files only, never in code.
- Use `config.ts` for constants.
- Use `globals.css` for global styles only, not component/page-specific styles.
- Next.js Server functions return `[data, error]` tuples:
  ```ts
  Promise<[string | null, object | null]>
  ```

## Tailwind Guidelines

- Single-use styles: inline Tailwind classes on the component.
- Multi-component styles scoped to one page: Tailwind child selectors on closest parent.
- Reuse existing `globals.css` classes instead of duplicating.
- Class order: layout, box model, background, borders, typography, effects, filters, transitions/animations, transforms, interactivity, SVG.
- Responsive classes follow their base class (e.g., `w-full md:w-1/2 lg:w-1/3`).

## React Component Conventions

- Define prop types as a separate interface above the component:
  ```tsx
  interface ButtonProps {
    text: string
  }
  const Button = ({ text }: ButtonProps) => {
    // component code
  }
  ```

## UI Guidelines

- Consistent colour scheme and typography throughout the application.