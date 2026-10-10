# Changelog

All notable changes to this project will be documented in this file.

## [0.12.0] - 2026-10-10

### Added
- `:checkhealth notebook_style` reports the ipykernel version of the local `.venv` Python and of the kernelspec's Python when the kernelspec runs ipykernel directly (`python -m ipykernel_launcher`; wrappers such as `conda run` are not run), and warns about ipykernel 7.0 to 7.3: those versions can stop handling requests when cells are run in quick succession, and the cells then stay busy until the kernel is restarted (fixed in ipykernel 7.4; with a Python older than 3.11, which 7.4 needs, ipykernel 6 does not have the problem). It also warns when the program a kernelspec runs cannot be found (a bare name is looked up in the PATH the kernelspec's env sets, if it sets one, as the backend does). README and help recommend ipykernel 7.4 or newer.

### Fixed
- `tests/run_all.sh` now fails when a Lua smoke test fails, the Lua suite raises an error, an error message is recorded while a test runs (for example by an exception in an asynchronous callback; the limits are listed at the top of `tests/lua_smoke.lua`), or the suite exits before reporting its results. Previously the headless Neovim step always exited 0, so failures only showed up in the log. The runner uses `nvim -l`.
- If the execution backend exits unexpectedly (crash or kill), buffers no longer stay stuck with `no session` errors: requests in flight fail instead of waiting forever, without an error message per request; the kernel state is reset and the exit is reported once (lines the backend wrote to stderr are still shown, as before); replies that arrive from the exited backend no longer change a buffer's session (a kernel list that arrives late can still be used to pick a kernel); and the next run starts a new backend and kernel. Existing outputs stay visible.
- Runs issued while a kernel starts or restarts no longer open a second session and kernel or fail with `kernel not started`; they wait for the kernel and execute once each, in the order issued. Quick successive runs also reach the kernel in order; requests sent together could previously be reordered.
- A kernel that fails to start (for example a kernelspec whose Python cannot import ipykernel) is now reported with the kernel's error output instead of hanging silently; a kernel that does not open its ports within 60 seconds is reported too. The error output shown includes a last line that does not end with a newline. Kernel stdout and stderr are written to the backend log.
- Wrapping very long output lines is no longer quadratic: a long line is split into rows only up to `output_max_lines` instead of being wrapped whole on every redraw (a 64,000-character line took about 1.9 s per redraw, now about 2.4 ms). The remaining work per redraw grows linearly with the length of the output: a single line of 5 million characters still takes about 0.15 s (ASCII) to 0.4 s (CJK).
- On Linux, macOS and other Unix systems the backend now passes its process id to the kernels it starts in `JPY_PARENT_PID`, as jupyter_client does, so that a kernel that honours it, such as ipykernel, can exit when the backend dies abnormally (crash or kill) instead of being left running. ipykernel 7 notices this once its parent poller has started, early in kernel startup; older ipykernel, and ipykernel 7 when the backend died before that, only notice when the kernel is re-parented to PID 1, which a subreaper (for example `systemd --user`) prevents. A kernel started through a wrapper that keeps running (for example `conda run`) is still left running, and on Windows nothing changes.
- A failed or interrupted backend download (the plugin-manager build hook or `:NotebookStyleDownloadBackend`) no longer overwrites an installed backend with a partial file: the binary is downloaded next to it and moved into place once complete and executable. If it cannot be made executable, the install fails and the installed backend is kept.
- Output that contains a NUL byte (for example `print('\0')`) is shown with `^@`, as Neovim shows NUL in a buffer. Before, rendering such a buffer failed with `E976: Using a Blob as a String` on every redraw and its outputs were not shown.
- `:checkhealth notebook_style` looks for kernelspecs in the same per-user data directory as the backend. On macOS it checked `~/.local/share/jupyter/kernels`, which the backend does not search there, and missed `~/Library/Application Support/jupyter/kernels`, which it does.
- If the kernel process exits by itself (a crash, an out-of-memory kill, `os._exit`), this is now reported with its exit status and its last error output, if any, running cells are no longer shown as busy, and the next run starts a new kernel (with `auto_start_kernel = false` the message points to `:NotebookStyleKernelStart` instead). Before, the cells stayed busy, later runs never finished, and nothing was reported.
- Kernel connection files, which hold the key that signs messages to a kernel, are now readable only by their owner, in a new directory per kernel that only the owner can enter, and are removed with the kernel. They used to be readable by everyone in a shared temporary directory and were never deleted: where the temporary directory is shared (typically `/tmp` on Linux), another local user could read the key and run code in your kernel. Files left by older versions in `notebook_style/` under the temporary directory can be deleted.

### Changed
- Kernels that run ipykernel directly (`python -m ipykernel_launcher`, as `ipykernel install` writes them, and the auto_venv kernels) now choose their own ports: the backend writes ports 0 into the connection file, ipykernel binds free ports and writes them back, and the backend connects to those. Before, the backend picked free ports and released them for the kernel, and something else could take one of them in between, which failed the start. Other kernels, and kernelspecs that start ipykernel through a wrapper (`sh -c`, `conda run`, tools that forward the ports to another machine), are still given ports picked by the backend. Such an ipykernel kernel now rewrites its connection file at every start, and jupyter_client then checks that only the owner can read and write it: where the temporary directory is on a mount that reports group or other permissions for every file (some FAT and network mounts do), the kernel exits during startup with that error, and setting `JUPYTER_ALLOW_INSECURE_WRITES=1` lets it start.
- The test suite now runs on GitHub Actions for every push and pull request (Linux and macOS, with ipykernel so that the kernel tests run), and the release workflow builds the backend binaries only after it passes.
- The backend log (`core.log` in the `notebook_style` folder of the user cache directory, for example `~/Library/Caches/notebook_style` on macOS or `~/.cache/notebook_style` on Linux) no longer grows without limit: when it reaches 10 MB it is renamed to `core.log.1`, replacing the previous one, and a new `core.log` is started. Several Neovim instances share the log: a backend notices when another one has rotated the file and writes to the new one, a lock file next to the log (`core.log.lock`) keeps two backends from rotating it at the same time, and the limit holds for all of them together.
- The documented minimum Neovim version is now 0.10 (it was 0.8). Rendering has needed 0.10 for some time: it uses the `virt_text_repeat_linebreak` extmark option, which older versions reject. `:checkhealth notebook_style` now reports an older Neovim as an error instead of saying core rendering still works.
- A run uses the cell's source at the moment it was issued, even if the buffer is edited while the kernel starts. `:NotebookStyleKernelStop` discards runs that have not reached the kernel yet (while a kernel is still starting or restarting, that is all it does).
- A buffer's kernel is now shut down when the buffer leaves the buffer list (`:bdelete`, `:bwipeout`) or is wiped out, which also covers unlisted scratch buffers, and when `:NotebookStyleDisable` is run (or the plugin is toggled off) for it. Previously the kernel kept running, unreachable, until Neovim exited. A buffer that is only unloaded keeps its kernel; note that `:bdelete` only unloads an unlisted buffer, unless its `'bufhidden'` is `wipe`.
- Starting a kernel is faster: the backend now notices as soon as the kernel's ports are open instead of waiting out ZeroMQ's reconnect back-off, which retried after about 1.4 s and then at growing intervals. How much is saved depends on when the kernel opens its ports: with ipykernel on the maintainer's machine, which opens them after about 0.2 s, a start went from 1.4 s to 0.2 s.

## [0.11.0] - 2026-09-22

### Added
- Run Python buffers without cell delimiters through the existing Jupyter kernel with `RunCell` or `RunFile`. The entire buffer, including unsaved changes, shares the kernel namespace and displays text, errors, and automatic Matplotlib plots at EOF without code borders or implicit expression results. Runs without output stay visually silent; existing output viewing, clearing, and kernel controls also work for whole-file output.

## [0.10.0] - 2026-08-10

### Changed
- Cell identity is now anchored with extmarks on delimiter lines instead of delimiter text + ordinal. Inline outputs, execution counts, and busy indicators follow their cell when cells are inserted, moved, or their delimiter is renamed; outputs of deleted cells are garbage-collected (including transmitted images) instead of re-attaching to unrelated cells, and late kernel events for garbage-collected cells are ignored. Garbage collection is deferred while in insert mode so retyping a delimiter (e.g. `cc`) keeps the cell's outputs. Known limitation: undoing a cell deletion restores the text but not the cell's previous outputs.

## [0.9.1] - 2026-07-23

### Added
- Added `markdown.cell_marker` for using a distinct marker in Markdown cell borders; when unset, Markdown cells continue to use the top-level `cell_marker`.

## [0.9.0] - 2026-07-23

### Added
- Added built-in rendering for Jupytext `# %% [markdown]` and `# %% [md]` cells. Markdown remains unchanged in the Python buffer and is styled in normal/visual modes using source-aligned conceal and highlight extmarks.
- Added support for headings, emphasis, strikethrough, inline code, links, lists, task items, quotes, thematic breaks, fenced code, and basic table styling in Markdown cells.

### Changed
- Inline execution now skips Markdown cells, and running a Markdown-only file reports that there are no runnable cells.

## [0.8.1] - 2026-06-27

### Fixed
- Fixed a crash (`attempt to index local 'chars' (a nil value)`) when `border_style` referenced a custom style. Custom styles now resolve from either `border_chars` or a top-level config key, missing border characters fall back to the `solid` defaults, and an unknown `border_style` warns and falls back to `solid` instead of erroring.

## [0.8.0] - 2026-06-17

### Added
- Added `:NotebookStyleSelectKernel` to choose an installed Jupyter kernelspec for the current buffer.
- Added `:NotebookStyleClearOutput` / `:NotebookStyleClearCellOutput` and `:NotebookStyleClearAllOutputs` to clear current-cell or buffer-wide inline outputs.

### Changed
- Changed default keymaps to buffer-local mappings installed only for enabled buffers, avoiding collisions in other filetypes.
- Reapply configured highlight groups after `ColorScheme` changes.

## [0.7.0] - 2026-06-12

### Added
- Added `:NotebookStyleKernelInterrupt` (default `<leader>ri`) to stop a long-running cell and `:NotebookStyleKernelRestart` to restart the kernel with a clean state.
- Added a running indicator for executing cells: the output divider shows `Out[*]` and a `running…` line until the first output arrives.
- Added `:checkhealth notebook_style` reporting backend binary presence, Jupyter kernel availability (`auto_venv` and `kernel_name`), and Kitty graphics / tmux passthrough support.

## [0.6.1] - 2026-05-26

### Changed
- Changed the default output viewer size to half of the editor (`output_view.width = 0.5`, `output_view.height = 0.5`).

### Fixed
- Made the output viewer float use the normal editor background instead of the themed gray floating-window background.

## [0.6.0] - 2026-05-26

### Added
- Added `:NotebookStyleOpenOutput` to open the current cell output in a focusable readonly floating buffer for navigation, search, visual selection, yank, and long-output scrolling.
- Added configurable output viewer keymap (`keymaps.open_output`) and floating window size (`output_view.width` / `output_view.height`).

## [0.5.1] - 2026-05-22

### Fixed
- Fixed the first cell's top border being clipped when the file is scrolled to the very top.

### Changed
- Moved hidden cell delimiter labels into each cell's top border.

## [0.5.0] - 2026-05-22

### Added
- Added `auto_venv` inline execution startup: project-local `.venv` Python interpreters with `ipykernel` are preferred over the configured kernelspec by default.
- Added `tests/run_all.sh` with Rust checks, release backend build, and headless Neovim Lua smoke tests.

## [0.4.2] - 2026-05-13

### Fixed
- Restored Kitty/Ghostty virtual image placement creation and fit placement width to PNG aspect ratio so plot outputs align to the left edge instead of being centered inside an over-wide placeholder box.

## [0.4.1] - 2026-05-13

### Fixed
- Fixed Kitty/Ghostty image output placement by transmitting images without creating a cursor-position terminal placement.

### Changed
- Documented `.ipynb` notebook support through Jupytext-backed `# %%` Python buffers.

## [0.4.0] - 2026-05-12

### Added
- Added `:NotebookStyleRunFile`, `:NotebookStyleRunCellAndMove`, configurable execution keymaps, and configurable image output rows/columns.

### Fixed
- Wrapped Kitty graphics escapes for tmux passthrough and tightened inline output alignment with the cell border.

## [0.3.3] - 2026-05-08

### Changed
- Added Neovim 0.12 `vim.pack` installation instructions, including a `PackChanged` hook for the optional backend installer.
- Removed first-run backend auto-install from `:NotebookStyleRunCell`; use plugin-manager hooks or `:NotebookStyleDownloadBackend` explicitly.

## [0.3.2] - 2026-05-08

### Fixed
- Automatically installs the Rust backend on first `:NotebookStyleRunCell` / kernel start when plugin-manager build hooks did not run.

## [0.3.1] - 2026-05-08

### Fixed
- Improved backend spawn failures with actionable diagnostics that show the attempted command path and installer hints.
- Treat Intel macOS as a source-build platform until a prebuilt binary is published for it.

## [0.3.0] - 2026-05-08

### Changed
- Cells now render automatically by default, and `<leader>rs` / `:NotebookStyleToggleRender` toggles current-buffer render visibility off and back on. Manual render mode still starts hidden and renders on demand.
- Inline execution backend installation now prefers tagged-release prebuilt binaries via `lua/notebook_style/install.lua`, with Cargo used only as a fallback for development checkouts or unsupported platforms.

## [0.2.1] - 2026-02-10

### Fixed
- Fixed cursor position on empty lines inside cells: cursor now aligns with code lines instead of sitting on the border character (fixes #4)

## [0.2.0] - 2026-01-29

### Added
- **Cell Names**: Extract and display cell names from delimiter lines (e.g., `# %% My Cell Name`)
- New configuration options for cell name display:
  - `show_cell_name`: Toggle cell name display (default: true)
  - `show_cell_number`: Toggle cell number display (default: true)
  - `cell_name_pattern`: Lua pattern to extract cell names
  - `cell_name_max_length`: Maximum length for cell name display
  - `cell_label_format_named`: Format string for cells with names
  - `cell_label_format_unnamed`: Format string for cells without names
- Customizable label format with `{icon}`, `{number}`, and `{name}` placeholders

### Fixed
- Fixed extra 1-character gap between text and line beginning on empty lines
- Fixed conflict with snacks.nvim indent plugin (indentation shift issue)

### Changed
- Updated example.py to demonstrate cell names feature
- Improved documentation in README.md

## [0.1.0] - 2025-11-11

### Added
- Initial release of notebook_style.nvim
- Cell detection for Python files with `# %%` delimiters
- Customizable border rendering (solid, dashed, double styles)
- Mode-aware visibility:
  - Hide `# %%` delimiters in normal/visual modes
  - Hide borders in insert mode
- Color customization for borders and delimiters
- User commands: `:NotebookStyleEnable`, `:NotebookStyleDisable`, `:NotebookStyleToggle`
- Auto-enable for Python filetypes
- Three border styles with Unicode characters
- Percentage-based cell width configuration (default 80% of window width)
- Min/max cell width constraints
- All cells rendered with consistent width
- Customizable cell marker with Python nerd font icon by default
- Cell marker configuration option for personalization

### Fixed
- Compatibility with Neovim 0.11.5 by removing unsupported extmark parameters
- Proper delimiter concealing using correct `end_col` calculation
- Border placement using compatible virtual lines API

### Technical Details
- Uses Neovim's native extmarks API for efficient rendering
- Non-intrusive virtual text that doesn't modify buffer content
- Automatic updates on text changes, mode changes, and window resizes
