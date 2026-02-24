# List available recipes
default:
    @just --list

ansible_dir := justfile_directory() / "ansible"

[group('setup')]
phase1:
    "{{ ansible_dir }}/run-playbook.sh" --tags phase1

[group('setup')]
phase2:
    "{{ ansible_dir }}/run-playbook.sh" --tags phase2

[group('setup')]
setup *args:
    "{{ ansible_dir }}/run-playbook.sh" {{ args }}

import? 'test.just'
