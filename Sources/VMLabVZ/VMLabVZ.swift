/// Virtualization.framework backend, seen from the server: the `vmlab-vz` runner's control-socket
/// protocol and client, launching runners detached and reattaching to them, and (later) the Tart
/// image integration. This module never imports Virtualization; only `vmlab-vz` does.
public enum VMLabVZ {}
