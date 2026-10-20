# GE-Proton updater

Installs the latest [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) into Steam. The first run asks which Steam folder to use and can add an update alias for bash or zsh. Later runs only check for a new version.

The installer runs in bash. If your shell is zsh, the alias is still added to your zsh config.

Restart Steam after it finishes. The new version is under a game's Properties → Compatibility.

## Command

```bash
curl -fsSL https://raw.githubusercontent.com/ivansrbulov/ge-proton-script/main/ge-proton-updater.sh | bash
```

Press Enter to accept a suggested answer. If the detected Steam folder is wrong, the arrow keys move through the other install methods, including a custom path.

The installer can add this alias:

```bash
alias update-ge-proton='curl -fsSL https://raw.githubusercontent.com/ivansrbulov/ge-proton-script/main/ge-proton-updater.sh | bash -s --'
```

`update-ge-proton` checks for a new version. `update-ge-proton --setup` changes the Steam folder or the alias. `update-ge-proton --show-steam` prints detected Steam folders and does not download anything.
