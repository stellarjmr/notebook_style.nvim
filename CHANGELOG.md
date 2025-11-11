# Changelog

All notable changes to this project will be documented in this file.

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

### Fixed
- Compatibility with Neovim 0.11.5 by removing unsupported extmark parameters
- Proper delimiter concealing using correct `end_col` calculation
- Border placement using compatible virtual lines API

### Technical Details
- Uses Neovim's native extmarks API for efficient rendering
- Non-intrusive virtual text that doesn't modify buffer content
- Automatic updates on text changes, mode changes, and window resizes
