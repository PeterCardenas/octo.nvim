# Agents Guide

`octo.nvim` is a Neovim plugin for working with GitHub issues, pull requests,
discussions, reviews, and workflow runs from inside Neovim.

## Reasoning Preference

Prefer retrieval-led reasoning over memory. Read the relevant files before
making project-specific decisions.

## Gather Context First

Before implementing, suggesting changes, or answering project-specific
questions:

1. Read the relevant files.
2. Search for existing patterns and nearby tests.
3. Verify public config fields and types in `lua/octo/config.lua` and related
   modules.
4. Check the user-facing docs if the change affects commands, config, or
   behavior.

Do not guess field names, APIs, or review flow behavior.

## Project Rules

- Do not call `vim.notify` directly inside `lua/octo/`; use the existing
  `octo.notify` helpers instead. The pre-commit hooks enforce this.
- Follow existing patterns in `lua/octo/` and keep changes localized.
- If you change public configuration, commands, or user-visible behavior, update
  both `README.md` and `doc/octo.txt`.
- If you change or add tests, keep them under the existing `lua/tests/`
  structure and follow the surrounding plenary patterns.

## Validation

After changing Lua or Vimscript files, run:

```bash
just validate
```

This runs:

- `just format`
- `just lint`
- `just typecheck`
- `just test`

Verbose output is written to:

- `.local/octo_format_output.log`
- `.local/octo_lint_output.log`
- `.local/octo_typecheck_output.log`
- `.local/octo_test_output.log`

`just validate` keeps stdout short. If a step fails, read the matching log
file.

## Commands

- `just setup-deps` bootstraps local dependencies in `deps/`, reusing sibling
  plugin checkouts when available.
- `just format` formats the repo with StyLua.
- `just lint` runs the configured pre-commit hooks.
- `just typecheck` runs LuaLS with `.github/workflows/.luarc.json` at
  `CHECKLEVEL=Error` by default so local validation stays actionable. Use
  `CHECKLEVEL=Information just typecheck` to match the stricter CI workflow.
- `just test` runs the plenary suite in `lua/tests/plenary/`.

## Environment

- Neovim >= 0.10.0
- LuaJIT / Lua 5.1 runtime
- GitHub CLI for runtime plugin behavior
