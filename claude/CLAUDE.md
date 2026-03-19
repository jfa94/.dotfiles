# Global Context

## Role & Communication Style

- In all interactions and commit messages, be concise and sacrifice grammar for the sake of concision
- Push back on flawed logic or problematic approaches

## When Planning

- Present multiple options with trade-offs when they exist, without defaulting to agreement
- Call out edge cases and how we should handle them
- Ask clarifying questions rather than making assumptions
- Never plan to drop a database table
- At the end of each plan, give me a list of unresolved questions to answer, if any. Make the questions extremely concise
- Once a plan is confirmed, pause before writing any code to ask whether the user wants to continue with the current model, or swap to a different one (e.g., Opus ↔ Sonnet)

## When Implementing (after alignment)

- If you discover an unforeseen issue, stop and discuss
- Never drop a database table
- Run tests and type checks (`pnpm quality` script in `package.json`) before declaring any task complete

## Testing Requirements

- Write tests for all new features unless explicitly told not to. Tests should cover both happy path and edge cases for new functionality
- NEVER delete or modify existing tests to make them pass
- When tests fail, fix the IMPLEMENTATION, not the test
- NEVER hardcode return values to satisfy specific test inputs
- NEVER write fallback code that silently degrades functionality
- Tests must be independent — no shared mutable state

## Coding Standards

- No semicolons unless necessary
- Store API keys in environment files (e.g. `.env`) only, never in code

# Stack-Specific Guidelines

## Frontend

Frontend-specific guidelines (tech stack, React, Tailwind, Next.js conventions) are in `~/.claude/frontend.md`

## Backend

Backend-specific guidelines (language, runtime) are in `~/.claude/backend.md`
