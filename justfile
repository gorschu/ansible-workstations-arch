# List available recipes
default:
    @just --list

ansible_dir := justfile_directory() / "ansible"

# New install: Phase 1 - base + storage (vault-free, TTY)
phase1:
    "{{ ansible_dir }}/run-playbook.sh" --tags phase1

# New install: Phase 2 - desktop + 1Password (vault-free, needs phase1)
phase2:
    "{{ ansible_dir }}/run-playbook.sh" --tags phase2

# Full setup (requires 1Password signed in for vault)
setup *args:
    "{{ ansible_dir }}/run-playbook.sh" {{ args }}

import? 'test.just'
