# List available recipes
default:
    @just --list

ansible_dir := justfile_directory() / "ansible"
hostname    := `hostnamectl hostname`

[group('setup')]
phase1:
    "{{ ansible_dir }}/run-playbook.sh" -l {{ hostname }} --tags phase1

[group('setup')]
phase2:
    "{{ ansible_dir }}/run-playbook.sh" -l {{ hostname }} --tags phase2

[group('setup')]
setup *args:
    "{{ ansible_dir }}/run-playbook.sh" -l {{ hostname }} {{ args }}

import? 'test.just'
