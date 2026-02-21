from ansible.errors import AnsibleFilterError


def device_for_mount(mountpoint, mounts, fstype=None):
    """Return the block device for a given mount point from ansible_facts['mounts'].
    Optionally filter by filesystem type."""
    for m in mounts:
        if m["mount"] == mountpoint and (fstype is None or m["fstype"] == fstype):
            return m["device"]
    raise AnsibleFilterError(f"No active mount found for '{mountpoint}'" +
                             (f" with fstype '{fstype}'" if fstype else ""))


def uuid_for_mount(mountpoint, mounts):
    """Return the filesystem UUID for a given mount point from ansible_facts['mounts']."""
    for m in mounts:
        if m["mount"] == mountpoint:
            return m["uuid"]
    raise AnsibleFilterError(f"No active mount found for '{mountpoint}'")


def to_systemd_mount_unit(path):
    """Convert a mount path to its systemd mount unit name (e.g. /mnt/foo -> mnt-foo.mount)."""
    return path.lstrip("/").replace("/", "-") + ".mount"


class FilterModule:
    def filters(self):
        return {
            "device_for_mount": device_for_mount,
            "uuid_for_mount": uuid_for_mount,
            "to_systemd_mount_unit": to_systemd_mount_unit,
        }
