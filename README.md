# ansible-workstations-arch

Hosts:

- apollo (KDE, Hyprland, DMS)
- artemis (KDE, Hyprland, DMS)
- hephaestus (KDE, Hyprland, DMS)

## New install

After `arch-install.sh` + first boot:

```bash
just phase1   # base + storage, no vault
just phase2   # desktop + 1Password, no vault
```

Then: log into desktop → sign into 1Password app → run chezmoi bootstrap [dotfiles](https://github.com/gorschu/dotfiles)

```bash
just setup    # full playbook, vault via 1Password
```

Approve Tailscale machine at <https://login.tailscale.com/admin/machines>
