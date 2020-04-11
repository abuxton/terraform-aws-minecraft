#!/bin/bash
#
# Install, configure and start a new Minecraft server
# This supports Ubuntu and Amazon Linux 2 flavors of Linux (maybe/probably others but not tested).

set -e

# Determine linux distro
if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS=Debian
    VER=$(cat /etc/debian_version)
elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    ...
elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    ...
else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    VER=$(uname -r)
fi

# Update OS and install start script
ubuntu_linux_setup() {
  export SSH_USER="ubuntu"
  export DEBIAN_FRONTEND=noninteractive
  /usr/bin/apt-get update
  /usr/bin/apt-get -yq install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" default-jre wget awscli openjdk-8-jre-headless curl screen nano bash grep tree git 
  /bin/cat <<"__UPG__" > /etc/apt/apt.conf.d/10periodic
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
__UPG__

adduser --system --shell /bin/bash --home /opt/minecraft --group minecraft

# Init script for starting, stopping https://minecraft.gamepedia.com/Tutorials/Server_startup_script#Systemd_Script
  cat <<SYSTEM > /etc/systemd/system/minecraft@.service
# Source: https://github.com/agowa338/MinecraftSystemdUnit/
# License: MIT
[Unit]
Description=Minecraft Server %i
After=network.target

[Service]
WorkingDirectory=/opt/minecraft/%i
PrivateUsers=true 
# Users Database is not available for within the unit, only root and minecraft is available, everybody else is nobody
User=minecraft
Group=minecraft
ProtectSystem=full 
# Read only mapping of /usr /boot and /etc
ProtectHome=true 
# /home, /root and /run/user seem to be empty from within the unit. It is recommended to enable this setting for all long-running services (in particular network-facing ones).
ProtectKernelTunables=true 
# /proc/sys, /sys, /proc/sysrq-trigger, /proc/latency_stats, /proc/acpi, /proc/timer_stats, /proc/fs and /proc/irq will be read-only within the unit. It is recommended to turn this on for most services.
# Implies MountFlags=slave
ProtectKernelModules=true 
# Block module system calls, also /usr/lib/modules. It is recommended to turn this on for most services that do not need special file systems or extra kernel modules to work
# Implies NoNewPrivileges=yes
ProtectControlGroups=true 
# It is hence recommended to turn this on for most services.
# Implies MountAPIVFS=yes

ExecStart=/bin/sh -c '/usr/bin/screen -DmS mc-%i /usr/bin/java -server -Xms512M -Xmx2048M -XX:+UseG1GC -XX:+CMSIncrementalPacing -XX:+CMSClassUnloadingEnabled -XX:ParallelGCThreads=2 -XX:MinHeapFreeRatio=5 -XX:MaxHeapFreeRatio=10 -jar $(ls -v | grep -i "FTBServer.*jar\|minecraft_server.*jar" | head -n 1) nogui'

ExecReload=/usr/bin/screen -p 0 -S mc-%i -X eval 'stuff "reload"\\015'

ExecStop=/usr/bin/screen -p 0 -S mc-%i -X eval 'stuff "say SERVER SHUTTING DOWN. Saving map..."\\015'
ExecStop=/usr/bin/screen -p 0 -S mc-%i -X eval 'stuff "save-all"\\015'
ExecStop=/usr/bin/screen -p 0 -S mc-%i -X eval 'stuff "stop"\\015'
ExecStop=/bin/sleep 10

Restart=on-failure
RestartSec=60s

[Install]
WantedBy=multi-user.target

#########
# HowTo
#########
#
# Create a directory in /opt/minecraft/XX where XX is a name like 'survival'
# Add minecraft_server.jar into dir with other conf files for minecraft server
#
# Enable/Start systemd service
#    systemctl enable minecraft@survival
#    systemctl start minecraft@survival
#
# To run multiple servers simply create a new dir structure and enable/start it
#    systemctl enable minecraft@creative
# systemctl start minecraft@creative
SYSTEM

}


MINECRAFT_JAR="minecraft_server.${mc_version}.jar"

# Create mc dir, sync S3 to it and download mc if not already there (from S3)
/bin/mkdir -p ${mc_root}
/usr/bin/aws s3 sync s3://${mc_bucket} ${mc_root} --region `hostname -f | cut -d'.' -f2`
[[ -e "${mc_root}/$MINECRAFT_JAR" ]] || /usr/bin/wget -O ${mc_root}/$MINECRAFT_JAR https://launcher.mojang.com/v1/objects/bb2b6b1aefcd70dfd1892149ac3a215f6c636b07/server.jar

case $OS in
  Ubuntu*)
    ubuntu_linux_setup
    ;;
  Amazon*)
    amazon_linux_setup
    ;;
  *)
    echo "$PROG: unsupported OS $OS"
    exit 1
esac

# Cron job to sync data to S3 every five mins
/bin/cat <<CRON > /etc/cron.d/minecraft
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:${mc_root}
*/${mc_backup_freq} * * * *  $SSH_USER  /usr/bin/aws s3 sync ${mc_root}  s3://${mc_bucket} --region `hostname -f | cut -d'.' -f2`
CRON

# Update minecraft EULA
/bin/cat >${mc_root}/eula.txt<<EULA
#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://account.mojang.com/documents/minecraft_eula).
#Tue Jan 27 21:40:00 UTC 2015
eula=true
EULA


# Not root
#/bin/chown -R $SSH_USER ${mc_root}
sudo usermod -a -G minecraft $SSH_USER
sudo chown -R minecraft:minecraft ${mc_root}




# Start the server
case $OS in
  Ubuntu*)
    /usr/bin/systemctl start minecraft
    ;;
  Amazon*)
    /usr/bin/systemctl start minecraft
    ;;
esac

exit 0

