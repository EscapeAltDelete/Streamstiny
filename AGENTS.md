# Repository policy

- This is the source-only `EscapeAltDelete/Streamstiny` repository. Keep only `main` unless the owner requests another branch.
- Do not add or enable GitHub Actions workflows or spend Actions credits on this account. The historical build configuration is preserved as `docs/build.yml.disabled`, outside GitHub's executable workflow directory. Do not reactivate it unless the owner explicitly requests it.
- Do not restore old repository tags, releases, build artifacts, or Git history. Only current source, assets, tests, documentation, and local build scripts belong in this repository.
- Use `EscapeAltDelete` as Git author and committer, with `96600150+EscapeAltDelete@users.noreply.github.com` as the email. Do not use a personal display name.
- Use the existing checkout, inspect its status, and preserve user changes. Do not create worktrees unless requested.
- Follow `docs/building.md` for local build and regression commands. Native builds use optimized ARM64 Release products; preserve checksum verification of pinned playback patches and package validation.
- Report device behavior separately from build, package, or Foundation regression checks.
