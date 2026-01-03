# gha-pin.nvim

[![GitHub Release](https://img.shields.io/github/release/mhiro2/gha-pin.nvim?style=flat)](https://github.com/mhiro2/gha-pin.nvim/releases/latest)
[![CI](https://github.com/mhiro2/gha-pin.nvim/actions/workflows/ci.yaml/badge.svg)](https://github.com/mhiro2/gha-pin.nvim/actions/workflows/ci.yaml)

Inspect and update **pinned SHAs** in GitHub Actions workflows (`uses: owner/repo@<full-commit-sha>`) directly from Neovim.

This plugin is lightweight and practical for day-to-day use.
It parses workflow/action files line-by-line (not a full YAML parser) and is not intended to replace Dependabot/Renovate.

## Motivation

Pinning GitHub Actions to full commit SHAs is the safest, most reliable approach. Tags can change over time, which can undermine reproducibility and open the door to supply-chain risks. This plugin helps you keep SHA pins up to date.
See: [Security hardening for GitHub Actions - GitHub Docs](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#using-third-party-actions)

## Features

- **Diagnostics**: warns when a pinned SHA is not the latest (default policy: latest release)
- **Virtual text**: shows `# Latest: <tag> <sh>` at end of line (default ON)
- **Fix**: updates outdated pins to the latest SHA (whole buffer or range)
- **Explain**: shows what the plugin resolved for the `uses:` under cursor
- **Cache**: TTL-based cache (default: 6 hours)
- **Auth / transport**: uses [GitHub CLI (`gh`)](https://cli.github.com/) via `gh api` when available; falls back to `curl` + `GITHUB_TOKEN`
- **Auto check targets**: workflows and composite action metadata files (`.github/actions/**/action.yml|yaml`)

![movie](https://github.com/user-attachments/assets/74f12504-96e6-41c3-8ff6-339af2f5aab7)


## Requirements

- Neovim >= 0.9
- [GitHub CLI (`gh`)](https://cli.github.com/) (recommended)
- `curl`

## Installation (lazy.nvim)

```lua
{
  "mhiro2/gha-pin.nvim",
  config = function()
    require("gha-pin").setup({
      auto_check = { enabled = true },
    })
  end,
}
```

## Health Check

Check plugin status and dependencies:

```vim
:checkhealth gha-pin
```

This will verify:
- Neovim version compatibility
- Availability of GitHub CLI (`gh`) and `curl` executables
- Authentication status (`gh` auth or `GITHUB_TOKEN`)
  - Set the `GITHUB_TOKEN` environment variable to a GitHub access token (typically a PAT; see [managing personal access tokens](https://docs.github.com/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)).

## Usage

### Commands

| Command | Description |
| --- | --- |
| `:GhaPinCheck` | Parse current buffer and update diagnostics/virtual text |
| `:GhaPinFix` | Update outdated pins to latest SHA (whole buffer) |
| `:GhaPinExplain` | Show resolution details for `uses:` under cursor |
| `:GhaPinCacheClear` | Clear cache |

### What is "Latest"?

By default, this plugin resolves "latest" as the **latest release** when available:

1. `GET /repos/{owner}/{repo}/releases/latest` -> `tag_name`
2. Resolve tag -> commit SHA via `GET /repos/{owner}/{repo}/git/ref/tags/{tag}`
   (and `GET /repos/.../git/tags/{sha}` for annotated tags)
3. If the repo has no releases (404), fallback to `GET /repos/{owner}/{repo}/tags?per_page=1`

> [!NOTE]
> Depending on the repo's release/tag conventions, the resolved SHA may not match your expectation.

### Failure behavior

- If resolution fails (network/auth/rate limit/etc.), the plugin will **not** add "outdated" diagnostics for that `uses:`.
- Virtual text may show `# Latest: (resolve failed)`. Use `:GhaPinExplain` to see the error.

### Supported patterns

- Included:
  - `uses: owner/repo@<full-commit-sha>`
  - `uses: owner/repo/path@<full-commit-sha>`
- Ignored:
  - `uses: ./path`
  - `uses: docker://...`
  - any `uses:` containing `${{ }}` (dynamic expressions)
  - tag refs like `@v4` (not supported yet)

## Configuration

```lua
require("gha-pin").setup({
  virtual_text = true,
  ttl_seconds = 6 * 60 * 60,
  github = {
    api_base_url = "https://api.github.com",
    prefer_gh = true,
    token_env = "GITHUB_TOKEN",
  },
  auto_check = {
    enabled = false,
    debounce_ms = 700,
  },
})
```

### auto_check notes

- `auto_check` runs only for workflow files under `.github/workflows/*.yml|yaml` and action metadata files under `.github/actions/**/action.yml|yaml`.
- If you feel this is too noisy/heavy, keep it disabled and run `:GhaPinCheck` manually, or increase `ttl_seconds`.

## Cache

The cache is stored at:

- `stdpath("cache")/gha-pin.nvim/cache.json`

No tokens are written to disk.

## License

MIT License. See [LICENSE](./LICENSE).
