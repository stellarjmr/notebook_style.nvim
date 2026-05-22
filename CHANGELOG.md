# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- Fixed the first cell's top border being clipped when the file is scrolled to the very top.

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
