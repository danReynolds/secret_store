# Changelog

## 0.1.0

- Initial five-command CLI: `run`, `set`, `rm`, `list`, and `doctor`.
- Strict mixed manifests with literal values and qualified `kb://` references.
- Run-scoped POSIX `execve` injection with no shell or resident wrapper. The
  parent environment passes through byte-exact from raw `environ` (variables
  Dart cannot represent are preserved, not dropped), and the child starts with
  shell-default signal state (SIGPIPE disposition and the thread signal mask
  are reset at the exec boundary).
- Hidden TTY input and strict `--stdin` handling: the modes never cross
  (`--stdin` refuses a terminal so a typed secret is never echoed), and empty
  input is rejected rather than stored.
- macOS login-Keychain and Linux Secret Service-backed storage through
  `package:keybay`.
