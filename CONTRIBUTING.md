# Contributing to VoxSign

Thank you for contributing! VoxSign is fully open source under the
[Apache License 2.0](LICENSE) — personal and commercial use are both welcome.

## Ways to contribute

- **Report a bug or request a feature** — open an Issue. Describe what you
  expected and what actually happened, include steps to reproduce and, for
  bugs, the app version and device.
- **Submit code** — follow the Pull Request flow below.
- **Improve localization** — VoxSign ships English (default) and zh-Hans.
  Keep all user-facing strings in `Localizable.strings` (en as source of
  truth) and add the matching translation.

## Pull Request flow

1. Fork the repository and create a feature branch:
   `git checkout -b feat/your-change`
2. Make your changes, following the [Code style](#code-style) section.
3. Add tests for new behavior in `VoxSignTests` (or `VoxSignUITests` for UI).
4. Commit **with the DCO sign-off (mandatory)**:
   `git commit -s -m "feat: describe your change"`
   This adds `Signed-off-by: Your Name <your@email>` to the commit — it
   certifies you are legally entitled to contribute this code.
5. Push and open a Pull Request against `main`.
6. CI must pass (build + tests + sensitive-info scan). A maintainer reviews
   the PR; **only maintainers can merge**.

## Review process — three gates

1. **Automated CI** — build, unit tests, and a scan for secrets / personal
   identifiers. Must be green before merge.
2. **Code review** — a maintainer (with AI-assisted review) checks logic,
   quality, and scope. Expect questions and requested changes.
3. **Maintainer merge** — the project owner gives final approval and merges.

## Code style

- Swift, consistent with the existing codebase; keep lines readable and
  methods small.
- **No personal names, real emails, credentials, or internal host details
  in code, comments, or docs** — the CI scan rejects them.
- Keep user-facing strings localized; English is the default language.
- New features must include unit tests; tests must pass locally before
  pushing.

## Protected paths

Paths listed in `CODEOWNERS` (core implementation) require explicit approval
from the project owner. Changes touching them are flagged in review and
cannot be merged without owner approval.

## Code of conduct

Be respectful and constructive. Harassment, trolling, or spam will result in
removal from the project. No exceptions.

## Questions

Open a discussion in Issues, or comment on an existing Issue/PR. We reply in
English.
