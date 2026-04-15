# Contributing to claude-brain

Thanks for your interest in contributing! claude-brain is an open-source Claude Code plugin and we welcome contributions of all kinds.

## Ways to contribute

- **Bug reports** — found something broken? [Open an issue](https://github.com/toroleapinc/claude-brain/issues)
- **Feature requests** — have an idea? Start a [discussion](https://github.com/toroleapinc/claude-brain/discussions)
- **Code contributions** — fix bugs, add features, improve docs
- **Share your experience** — blog posts, tweets, and word-of-mouth help the project grow

## Getting started

1. Fork the repository
2. Clone your fork
3. Create a feature branch: `git checkout -b my-feature`
4. Make your changes
5. Run the tests: `bash tests/run-tests.sh`
6. Commit and push
7. Open a pull request

## Development setup

```bash
# Clone the repo
git clone https://github.com/toroleapinc/claude-brain.git
cd claude-brain

# Run locally with Claude Code
claude --plugin-dir .

# Run tests
bash tests/run-tests.sh
```

## Project structure

```
scripts/          # Core logic (Shell scripts)
skills/           # User-facing commands (/brain-*)
agents/           # Merge specialist agent
hooks/            # Hook definitions (currently empty — sync is manual)
templates/        # LLM prompt templates
config/           # Default configuration
tests/            # Integration test suite
```

## Code style

- Shell scripts follow POSIX-compatible patterns where possible
- Use `jq` for all JSON processing
- Functions should have clear comments explaining their purpose
- Error handling: always check return codes, provide helpful error messages

## Pull request guidelines

- Keep PRs focused — one feature or fix per PR
- Include tests for new functionality
- Update README.md if adding user-facing features
- Follow the existing commit message style

## Code of Conduct

Be kind, be constructive, be helpful. That's it.

## Reporting security issues

If you discover a security vulnerability, please do NOT open a public issue. Instead, please use [GitHub's private vulnerability reporting](https://github.com/toroleapinc/claude-brain/security/advisories/new).

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
