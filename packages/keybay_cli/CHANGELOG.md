# Changelog

## 0.1.0

- Initial five-command CLI: `run`, `set`, `rm`, `list`, and `doctor`.
- Strict mixed manifests with literal values and qualified `kb://` references.
- Run-scoped POSIX `execve` injection with no shell or resident wrapper.
- Hidden TTY input and strict `--stdin` handling.
- macOS login-Keychain and Linux Secret Service-backed storage through
  `package:keybay`.
