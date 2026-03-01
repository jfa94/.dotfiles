# Frontend Guidelines

## Preferred Tech Stack

- **Frontend:** TypeScript, React, Next.js (App Router), Tailwind CSS
- **Analytics:** PostHog
- **Payments:** Stripe
- **Icons:** Lucide

## Frontend Coding Standards

- Use `globals.css` for global styles only, not component/page-specific styles.
- Next.js Server functions return `[data, error]` tuples:
  ```ts
  Promise<[string | null, object | null]>
  ```

## Tailwind Guidelines

- Reuse existing `globals.css` classes instead of duplicating.
- Class order: layout, box model, background, borders, typography, effects, filters, transitions/animations, transforms, interactivity, SVG.
- Responsive classes start with base class and follow increasing screen sizes (e.g., `w-full md:w-1/2 lg:w-1/3`).

## React Guidelines

- Function-based React components with arrow functions for callbacks.
- Define prop types as a separate interface above the component:
  ```tsx
  interface ButtonProps {
    text: string
  }
  const Button = ({ text }: ButtonProps) => {
    // component code
  }
  ```
