# Streamstiny

A native Destiny.gg chat and video app for iPhone and iPad running iOS 17 or later.

Streamstiny is licensed under the [GNU General Public License, version 3 only](LICENSE) (`GPL-3.0-only`). Copyright and license notices are included in LICENSE. The license permits use, modification, and redistribution, including commercial use, subject to its terms. When distributing the application, provide its corresponding source code and preserve the required license and copyright notices.

The current build links KSPlayer 2.3.4 and FFmpegKit 6.1.3, which ship GPLv3 license terms. Third-party components retain their respective licenses and notices. See [third-party notices](Streamstiny/ThirdPartyNotices/Sources.txt) for dependency source links and license texts.

The **Update native playback dependencies** Actions workflow checks for stable updates within each pinned major version every Monday at 05:00 UTC, or on manual dispatch. It opens a PR and dispatches a native build; checksum-verified playback patches remain enforced, and merging is manual. GitHub's **Allow GitHub Actions to create and approve pull requests** setting must be enabled for PR creation; the workflow does not approve PRs.
