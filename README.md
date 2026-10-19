# GE-Proton updater

Installs the latest [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) into Steam. It finds a native package, Flatpak, or Snap install, follows symlinks so the same Steam is only updated once, and creates `compatibilitytools.d` if it does not exist yet.

Restart Steam after it finishes. The new version is under a game's Properties → Compatibility.

## Command

This repository is private, so the download has to include a GitHub token. Collaborator access on its own does not let an anonymous `curl` read the file.

Create a personal access token with read access to this repository (fine-grained: Contents, read-only). Put this in `~/.bashrc` or `~/.zshrc`, then open a new terminal:

```bash
export GITHUB_TOKEN=github_pat_xxx
update-ge-proton() {
  set -o pipefail
  curl -fsSL \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.raw" \
    https://api.github.com/repos/ivansrbulov/ge-proton-script/contents/ge-proton-updater.sh \
    | bash -s -- "$@"
}
```

Run `update-ge-proton`. `update-ge-proton --show-steam` prints the Steam folders it found and does not download anything.

If the repository is public, the token and both `-H` headers can be removed, and the URL can be `https://raw.githubusercontent.com/ivansrbulov/ge-proton-script/main/ge-proton-updater.sh`.
