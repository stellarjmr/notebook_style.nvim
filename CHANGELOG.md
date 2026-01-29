# Changelog

All notable changes to this project will be documented in this file.

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
