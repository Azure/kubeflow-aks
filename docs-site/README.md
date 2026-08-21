# Kubeflow on AKS documentation site

The [Hugo](https://gohugo.io) source for the Kubeflow on AKS documentation,
using the [Docsy](https://www.docsy.dev) theme.

## Where the site publishes

`.github/workflows/gh-pages.yml` is the only publishing path. On a push to
`main` that touches `docs-site/**`, it builds the site and hands the output to
GitHub Pages as a deployment artifact:

<https://azure.github.io/kubeflow-aks/>

Pages is configured with GitHub Actions as its source rather than deploying from
a branch, so there is no `gh-pages` branch holding built output. The deployment
uses GitHub's own `configure-pages`, `upload-pages-artifact` and `deploy-pages`
actions, which is also why the workflow needs the `pages` and `id-token`
permissions.

`configure-pages` reports the URL Pages serves the site from, and the build
passes that to Hugo as `--baseURL`, so the value never has to be reconstructed
from the repository owner and branch. The `baseURL` in `config.toml` is a
fallback used for local builds only.

Netlify and Docker configurations were previously committed alongside this
workflow without either being wired up to anything. Both have been removed:
GitHub Actions is authoritative, and `npm run serve` covers local previews with
the same pinned Hugo the workflow uses.

## The /main/ aliases

The site used to publish under `https://azure.github.io/kubeflow-aks/main/`,
because the previous workflow deployed to a directory named after the source
branch. Each content page therefore carries an `aliases` entry for its old path,
which Hugo renders as a stub carrying `rel=canonical` and a meta refresh to the
current URL. That keeps links published against the old scheme working, and
lets search engines treat the move as a redirect rather than as a dead page.

These can be dropped once the old URLs no longer show up in traffic. They cover
content pages only; taxonomy listings under `/main/tags/` and `/main/categories/`
were never linked and are not aliased.

## Building locally

Requires Node (the version in `.nvmrc`) and a Go toolchain, which Hugo uses to
resolve the theme as a Hugo module. Hugo itself arrives as an npm dependency,
so there is no separate Hugo installation to keep in step.

```bash
cd docs-site
npm ci
npm run serve    # http://localhost:1313
npm run build    # writes ./public
```

## Pinned versions

Everything that affects the rendered output is pinned to an exact version, so a
clean checkout builds the same site every time:

| Component | Pinned in | Version |
| --- | --- | --- |
| Docsy theme | `go.mod`, `config.toml` | `github.com/google/docsy/theme` v0.16.0 |
| Hugo (extended) | `package.json` | 0.164.0 |
| Node | `.nvmrc` | 22 |
| Bootstrap | `package.json` | 5.3.8 |
| Font Awesome | `package.json` | 6.7.2 |
| PostCSS CLI, autoprefixer | `package.json` | 11.0.1, 10.5.4 |

The runner image, the Go toolchain and the Node patch release are deliberately
not pinned to an exact version. Go only resolves the theme as a Hugo module, and
`go.sum` verifies that by checksum, so the Go release cannot change the output.
Node only runs npm and the pinned `hugo-extended` binary. Pinning these further
would buy reproducibility the build does not depend on, at the cost of routine
version bumps.

Docsy v0.16.0 mounts Bootstrap and Font Awesome from `node_modules` rather than
shipping them as Hugo modules, which is why they are npm dependencies here.
Their versions have to match the ones in the theme's own `package.json` at the
pinned Docsy version.

The `overrides` entry pinning `adm-zip` to 0.6.0 exists because `hugo-extended`
depends on an older release that carries GHSA-xcpc-8h2w-3j85. The advisory is
build-time only, since `adm-zip` is used to unpack the Hugo archive at install
time, but `npm audit` reports it as high. The fix npm proposes is to downgrade
`hugo-extended` to 0.152.2, which is below the 0.160.1 floor Docsy v0.16.0
requires and would break the build. Overriding the transitive dependency instead
clears the advisory and keeps Hugo current. Drop the override once
`hugo-extended` ships a release that depends on adm-zip 0.6.0 or later.

To move to a newer Docsy release:

```bash
npm run update:docsy
```

Then re-pin `bootstrap` and `@fortawesome/fontawesome-free` in `package.json` to
match the new theme's `package.json`, and update `module.hugoVersion.min` in
`config.toml` to the floor the new theme declares.

`packages/hugoautogen/` is where Hugo records the npm dependencies contributed
by Hugo modules. `package.json` there is committed, because `package-lock.json`
declares it as a workspace. Its sibling `hugo_packagemeta.json` holds a checksum
specific to the checkout it was generated in, so that one is not committed; the
`build` and `serve` scripts regenerate it first.

## Layout

| Path | Contents |
| --- | --- |
| `content/en/` | Page content. `config.toml` sets `contentDir` here. |
| `layouts/` | Template overrides on top of the theme. |
| `assets/scss/_variables_project.scss` | Style overrides and Bootstrap variable overrides. |
| `config.toml` | Site configuration, including the repository links used by the "Edit this page" controls. |
