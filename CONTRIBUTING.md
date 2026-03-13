# Contributing to PerlGigachess

Thanks for contributing.

## Branch Model

- `main`: stable branch.
- `develop`: integration branch for active work.
- Open pull requests to `develop` unless a maintainer asks otherwise.
- Direct updates to protected branches are restricted by repository rules.

## Preferred Contribution Flow (Fork + PR)

1. Fork this repository on GitHub.
2. Clone your fork locally:
   ```bash
   git clone https://github.com/<your-username>/PerlGigachess.git
   cd PerlGigachess
   ```
3. Add the upstream remote:
   ```bash
   git remote add upstream https://github.com/Lolretrorat/PerlGigachess.git
   ```
4. Create a feature branch from `develop`:
   ```bash
   git fetch upstream
   git checkout -b feat/<short-description> upstream/develop
   ```
5. Make your changes and run checks:
   ```bash
   perl -c Chess/State.pm
   perl tests/perft.pl 4
   tests/run_regressions.sh
   ```
6. Commit using a short, imperative message:
   ```bash
   git commit -m "tune capture ordering"
   ```
7. Push your branch to your fork:
   ```bash
   git push -u origin feat/<short-description>
   ```
8. Open a pull request from your branch into `develop` on the upstream repo.

## Keep Your Fork Current

Before opening or updating a PR, rebase your branch on latest `upstream/develop`:

```bash
git fetch upstream
git checkout feat/<short-description>
git rebase upstream/develop
git push --force-with-lease
```

## Pull Request Expectations

- Target branch: `develop`.
- Keep PRs focused and small when possible.
- Include a clear summary of behavior changes.
- Include exact test commands you ran and their outcomes.
- If move generation/search behavior changed, include `perft` depth and FEN details.
- If CLI/UCI behavior changed, include a short transcript of:
  - `uci`
  - `isready`
  - `position startpos`
  - `go`
  - `quit`

## Coding Notes

- Use Perl with `use strict;` and `use warnings;`.
- Follow current style: two-space indentation and existing module naming.
- Keep package/file mapping consistent (`Chess::State` -> `Chess/State.pm`).
- Prefer adding focused regression tests under `tests/` for bug fixes.

## Security

Do not open public issues for sensitive security problems. Contact maintainers privately if security contact details are provided in repository settings.
