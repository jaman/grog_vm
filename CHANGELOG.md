# Changelog

## [Unreleased]

### Changed

* Hex package metadata: the GitHub link and the packaged files.

### Added

* SCUMM v5 bytecode decoded into instructions (`GrogVM.Decode`), compiled to Elixir
  modules cached on disk (`GrogVM.Compiler`), and run in script slots with pausing,
  delays, nested starts, chaining, freezing, cutscenes and their overrides
  (`GrogVM`), against a host the game supplies (`GrogVM.Host`).
