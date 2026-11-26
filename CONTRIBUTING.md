# Contributing

Issues and pull requests are welcome.

- **Set up:** follow Get started in the [README](README.md). Copy `.env.example` to `.env` and use your own bundle identifier and Apple team. Never commit `.env`.
- **Test:** run `npm test` and `cd mac && swift run StageChecks` before you open a pull request. CI runs both.
- **Keep it local:** the Companion talks only to `127.0.0.1` and to paired iPhones on the local network. Pull requests that add network calls elsewhere, telemetry or new auto-approval paths need a clear reason in the description.
- **Security bugs** go through [SECURITY.md](SECURITY.md), not a public issue.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
