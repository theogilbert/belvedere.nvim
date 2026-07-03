---
name: test
description: Run belvedere.nvim's plenary.nvim spec files headlessly from the CLI, without needing to open Neovim and run :PlenaryBustedFile by hand. Use when asked to run tests, run the test suite, run a spec file, or verify a change against the tests.
---

Run the plenary specs in `spec/` headlessly.

1. Find plenary.nvim's install directory. Try, in order, until one exists:
   - `$HOME/.local/share/nvim/lazy/plenary.nvim`
   - `$HOME/.local/share/knvim/lazy/plenary.nvim`
   - `find $HOME/.local/share -maxdepth 6 -type d -iname plenary.nvim`

2. Run the suite, substituting the discovered path for `<plenary_path>`:

   All specs:
   ```
   nvim --headless -u NONE \
     -c "set rtp+=. rtp+=<plenary_path>" \
     -c "runtime! plugin/plenary.vim" \
     -c "PlenaryBustedDirectory spec/" \
     -c "qa!"
   ```

   A single file (when an argument names a spec, e.g. `$ARGUMENTS` = `spec/connections_spec.lua`):
   ```
   nvim --headless -u NONE \
     -c "set rtp+=. rtp+=<plenary_path>" \
     -c "runtime! plugin/plenary.vim" \
     -c "PlenaryBustedFile $ARGUMENTS" \
     -c "qa!"
   ```

3. `-u NONE` skips the user's vimrc and plugin manager entirely, so `runtime! plugin/plenary.vim` must be sourced explicitly to register the `Plenary*` commands.

4. Report results from plenary's own output: list failing test names with their `file:line`, and quote the "Passed in / Expected" diff plenary prints — don't just say "tests failed." Exit code is 1 if any test failed.
