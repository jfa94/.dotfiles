# Global Context

## Role & Communication Style

- In all interactions and commit messages, be concise and sacrifice grammar for the sake of concision
- Push back on flawed logic or problematic approaches

## Tools

- Always prefer Claude native tools (e.g., Read, Grep, Glob) over bash equivalents (e.g., cat, grep, find, ls). Only use Bash for operations with no dedicated tool equivalent (e.g., `--help`)

## When Working

- Before doing any exploration or research, read through a project's documentation in the `/docs` directory
- Use subagents (`scout` if available) for any exploration or research that needs 3 or more files or pages. This
  includes software architecture, debugging, tool usage, best practices, etc.
- If you make any fundamental changes (e.g., architecture, functionality, usage), update a project's documentation in `/docs`
- Present multiple options with trade-offs when they exist, without defaulting to agreement
- Ask clarifying questions rather than making assumptions
- At the end of each plan, give me a list of unresolved questions to answer, if any. Make the questions extremely concise
- Be extremely cautious of functionality regression. DO NOT degrade functionality to appease a test; fix structurally
- DO NOT disable quality checks, such as linting, to silence errors or warnings; address the underlying issue
- NEVER drop a database table

## Testing Requirements

- Write tests for all new features unless explicitly told not to. Tests should cover both happy path and edge cases for new functionality
- NEVER delete or modify existing tests to make them pass. When tests fail, fix the IMPLEMENTATION, not the test
- NEVER hardcode return values to satisfy specific test inputs
- NEVER write fallback code that silently degrades functionality
- Tests must be independent — no shared mutable state
- For functions with broad input domains, use property-based testing (fast-check) to catch edge cases that example-based tests miss

## Coding Standards

- Store API keys in environment files (e.g. `.env`) only, never in code

# Stack-Specific Guidelines

## Frontend

Frontend-specific guidelines (commands, tech stack, React, Tailwind, Next.js conventions) are in `frontend.md` (same directory)

## Backend

Backend-specific guidelines (language, runtime) are in `backend.md` (same directory)
