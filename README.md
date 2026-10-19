# GE-Proton updater

Installs the latest [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) into Steam. It finds a native package, Flatpak, or Snap install, follows symlinks so the same Steam is only updated once, and creates `compatibilitytools.d` if it does not exist yet.

Restart Steam after it finishes. The new version is under a game's Properties → Compatibility.

## Command

```bash
curl -fsSL https://raw.githubusercontent.com/ivansrbulov/ge-proton-script/main/ge-proton-updater.sh | bash
```

To run it again later, put this alias in `~/.bashrc` or `~/.zshrc` and open a new terminal:

```bash
alias update-ge-proton='curl -fsSL https://raw.githubusercontent.com/ivansrbulov/ge-proton-script/main/ge-proton-updater.sh | bash -s --'
```

`update-ge-proton` installs the latest version. `update-ge-proton --show-steam` prints the Steam folders it found and does not download anything.
