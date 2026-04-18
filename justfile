set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

setup-deps:
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p deps

    repos=(
      "nvim-lua/plenary.nvim"
      "folke/snacks.nvim"
      "nvim-telescope/telescope.nvim"
      "ibhagwan/fzf-lua"
      "nvim-tree/nvim-web-devicons"
      "Bilal2453/luvit-meta"
    )

    for repo in "${repos[@]}"; do
      name="${repo##*/}"
      target="$PWD/deps/$name"
      sibling="$PWD/../$name"

      if [ -e "$target" ] || [ -L "$target" ]; then
        continue
      fi

      if [ -d "$sibling/.git" ] || [ -d "$sibling/lua" ]; then
        ln -s "$sibling" "$target"
      else
        git clone --depth 1 "https://github.com/${repo}.git" "$target"
      fi
    done

format:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -n "${STYLUA:-}" ]; then
      stylua_bin="$STYLUA"
    elif command -v stylua >/dev/null 2>&1; then
      stylua_bin="$(command -v stylua)"
    elif [ -x "$HOME/.local/share/nvim/mason/bin/stylua" ]; then
      stylua_bin="$HOME/.local/share/nvim/mason/bin/stylua"
    else
      echo "Could not find stylua. Set STYLUA or install stylua." >&2
      exit 1
    fi

    "$stylua_bin" .

format-check:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -n "${STYLUA:-}" ]; then
      stylua_bin="$STYLUA"
    elif command -v stylua >/dev/null 2>&1; then
      stylua_bin="$(command -v stylua)"
    elif [ -x "$HOME/.local/share/nvim/mason/bin/stylua" ]; then
      stylua_bin="$HOME/.local/share/nvim/mason/bin/stylua"
    else
      echo "Could not find stylua. Set STYLUA or install stylua." >&2
      exit 1
    fi

    "$stylua_bin" --check .

lint:
    pre-commit run --all-files

typecheck: setup-deps
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -n "${NVIM:-}" ]; then
      nvim_bin="$NVIM"
    elif command -v nvim >/dev/null 2>&1; then
      nvim_bin="$(command -v nvim)"
    else
      echo "Could not find nvim. Set NVIM or install Neovim." >&2
      exit 1
    fi

    if [ -n "${LUALS:-}" ]; then
      luals_bin="$LUALS"
    elif command -v lua-language-server >/dev/null 2>&1; then
      luals_bin="$(command -v lua-language-server)"
    elif command -v lua_ls >/dev/null 2>&1; then
      luals_bin="$(command -v lua_ls)"
    elif [ -x "$HOME/.local/share/nvim/mason/bin/lua-language-server" ]; then
      luals_bin="$HOME/.local/share/nvim/mason/bin/lua-language-server"
    elif [ -x "$HOME/.local/share/nvim/mason/bin/lua_ls" ]; then
      luals_bin="$HOME/.local/share/nvim/mason/bin/lua_ls"
    else
      echo "Could not find lua-language-server. Set LUALS or install LuaLS." >&2
      exit 1
    fi

    vimruntime="$("$nvim_bin" --clean --headless -u NONE +'lua io.write(vim.env.VIMRUNTIME)' +qa 2>/dev/null)"
    if [ -z "$vimruntime" ]; then
      echo "Could not determine VIMRUNTIME from $nvim_bin." >&2
      exit 1
    fi

    checklevel="${CHECKLEVEL:-Error}"

    env VIMRUNTIME="$vimruntime" \
      "$luals_bin" \
      --check="$PWD/lua" \
      --configpath="$PWD/.github/workflows/.luarc.json" \
      --checklevel="$checklevel"

test: setup-deps
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -n "${NVIM:-}" ]; then
      nvim_bin="$NVIM"
    elif command -v nvim >/dev/null 2>&1; then
      nvim_bin="$(command -v nvim)"
    else
      echo "Could not find nvim. Set NVIM or install Neovim." >&2
      exit 1
    fi

    mkdir -p .local
    tmp_init="$(mktemp "$PWD/.local/octo-minimal-init.XXXXXX.vim")"
    trap 'rm -f "$tmp_init"' EXIT

    printf '%s\n' \
      "execute 'set rtp+=' . fnameescape('$PWD')" \
      "execute 'set rtp+=' . fnameescape('$PWD/deps/plenary.nvim')" \
      "lua _G.__is_log = true" \
      "lua vim.fn.setenv(\"DEBUG_PLENARY\", true)" \
      "runtime! plugin/plenary.vim" \
      "runtime! plugin/octo.nvim" \
      "" \
      "lua << LUA" \
      "require(\"plenary/busted\")" \
      "require(\"tests/test_utils\")" \
      "require(\"octo\").setup()" \
      "LUA" \
      > "$tmp_init"

    "$nvim_bin" --headless -u "$tmp_init" -c "PlenaryBustedDirectory lua/tests/plenary/ { minimal_init = '$tmp_init' }"

validate:
    #!/usr/bin/env bash
    set -euo pipefail

    mkdir -p .local
    total_start="$(date +%s)"
    failed_steps=""

    append_failed_step() {
      if [ -z "$failed_steps" ]; then
        failed_steps="$1"
      else
        failed_steps="$failed_steps, $1"
      fi
    }

    start="$(date +%s)"
    just format > .local/octo_format_output.log 2>&1 || rc_format=$?
    rc_format="${rc_format:-0}"
    if [ "$rc_format" -ne 0 ]; then
      append_failed_step format
    fi
    echo "format: $rc_format (took $(($(date +%s) - start))s) - log: .local/octo_format_output.log"

    start="$(date +%s)"
    just lint > .local/octo_lint_output.log 2>&1 || rc_lint=$?
    rc_lint="${rc_lint:-0}"
    if [ "$rc_lint" -ne 0 ]; then
      append_failed_step lint
    fi
    echo "lint: $rc_lint (took $(($(date +%s) - start))s) - log: .local/octo_lint_output.log"

    start="$(date +%s)"
    just typecheck > .local/octo_typecheck_output.log 2>&1 || rc_typecheck=$?
    rc_typecheck="${rc_typecheck:-0}"
    if [ "$rc_typecheck" -ne 0 ]; then
      append_failed_step typecheck
    fi
    echo "typecheck: $rc_typecheck (took $(($(date +%s) - start))s) - log: .local/octo_typecheck_output.log"

    start="$(date +%s)"
    just test > .local/octo_test_output.log 2>&1 || rc_test=$?
    rc_test="${rc_test:-0}"
    if [ "$rc_test" -ne 0 ]; then
      append_failed_step test
    fi
    echo "test: $rc_test (took $(($(date +%s) - start))s) - log: .local/octo_test_output.log"

    echo "Total: $(($(date +%s) - total_start))s"
    if [ -n "$failed_steps" ]; then
      echo "Validation failed: $failed_steps. Check log files for details."
      exit 1
    fi
