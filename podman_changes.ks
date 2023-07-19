# This file is used as part of microshift VM creation
# to have podman specific configuration in place which
# we do using ignition for podman bundle

# Make podman rootless available
mkdir -p /home/core/.config/systemd/user/default.target.wants
ln -s /usr/lib/systemd/user/podman.socket /home/core/.config/systemd/user/default.target.wants/podman.socket
chown -R core:core /home/core/.config

mkdir -p /home/core/.config/containers
tee /home/core/.config/containers/containers.conf <<EOF
[containers]
netns="bridge"
rootless_networking="cni"
EOF
chown -R core:core /home/core/.config/containers

touch /etc/containers/podman-machine

tee /etc/containers/registries.conf.d/999-podman-machine.conf <<EOF
unqualified-search-registries=["docker.io"]
EOF

# Enable linger for core user to make sure podman socket work when user not logged in
mkdir -p /var/lib/systemd/linger/
touch /var/lib/systemd/linger/core
