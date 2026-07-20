#!/bin/bash
set -e

echo "============================================="
echo "🚀 CRÉATION D'UN ISO SLOWDNS + SSH + IP FIXE"
echo "============================================="

# 1. Installation des outils hôte
sudo apt-get update >/dev/null 2>&1
sudo apt-get install -y squashfs-tools xorriso debootstrap syslinux isolinux >/dev/null 2>&1

# 2. Répertoire de travail
WORK_DIR="/tmp/iso_build"
ROOTFS="$WORK_DIR/rootfs"
MINI_ISO="$WORK_DIR/mini_iso"

sudo rm -rf "$WORK_DIR"
mkdir -p "$MINI_ISO/casper" "$ROOTFS"

# 3. Extraction de la base minimale
echo "📦 1/5 : Installation de la base Linux minimale..."
sudo debootstrap --variant=minbase noble "$ROOTFS" http://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1

# 4. Configuration Utilisateur & Réseau Fixe
echo "⚙️ 2/5 : Injection de l'IP Fixe et de la configuration SSH..."
echo "root:toor" | sudo chroot "$ROOTFS" chpasswd

sudo mkdir -p "$ROOTFS/etc/netplan"
cat <<EOF | sudo tee "$ROOTFS/etc/netplan/00-minimal.yaml" >/dev/null
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: no
      addresses: [192.168.1.200/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
EOF

sudo mkdir -p "$ROOTFS/usr/local/bin"
cat <<'EOF' | sudo tee "$ROOTFS/usr/local/bin/start-slowdns.sh" >/dev/null
#!/bin/bash
echo "Démarrage du coeur SlowDNS..."
EOF
sudo chmod +x "$ROOTFS/usr/local/bin/start-slowdns.sh"

cat <<EOF | sudo tee "$ROOTFS/etc/systemd/system/slowdns.service" >/dev/null
[Unit]
Description=Service personnalisé SlowDNS
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/start-slowdns.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 5. Installation du noyau et d'OpenSSH
echo "📥 3/5 : Installation du Noyau, OpenSSH et paquets réseaux..."
sudo mount -t proc proc "$ROOTFS/proc" || true
sudo mount -t sysfs sys "$ROOTFS/sys" || true
sudo mount --bind /dev "$ROOTFS/dev" || true
sudo mkdir -p "$ROOTFS/dev/pts"
sudo mount -t devpts devpts "$ROOTFS/dev/pts" || true

sudo chroot "$ROOTFS" dpkg-divert --local --rename --add /sbin/initctl >/dev/null 2>&1 || true
sudo ln -sf /bin/true "$ROOTFS/sbin/initctl" || true
cat <<EOF | sudo tee "$ROOTFS/usr/sbin/policy-rc.d" >/dev/null
#!/bin/sh
exit 101
EOF
sudo chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

sudo chroot "$ROOTFS" apt-get update >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive sudo chroot "$ROOTFS" apt-get install -y --no-install-recommends \
    linux-image-virtual initramfs-tools casper systemd-sysv openssh-server netplan.io >/dev/null 2>&1

# Autoriser la connexion SSH en root
sudo sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' "$ROOTFS/etc/ssh/sshd_config" || true
sudo sed -i 's/PermitRootLogin.*/PermitRootLogin yes/' "$ROOTFS/etc/ssh/sshd_config" || true

# Activation des services
sudo chroot "$ROOTFS" systemctl enable slowdns.service >/dev/null 2>&1
sudo chroot "$ROOTFS" systemctl enable ssh >/dev/null 2>&1

# Détection de la version avec sudo
KERNEL_VER=$(sudo ls "$ROOTFS/lib/modules" | head -n 1)
sudo chroot "$ROOTFS" update-initramfs -c -k "$KERNEL_VER" >/dev/null 2>&1

sudo rm -f "$ROOTFS/usr/sbin/policy-rc.d"
sudo umount "$ROOTFS/dev/pts" || true
sudo umount "$ROOTFS/proc" || true
sudo umount "$ROOTFS/sys" || true
sudo umount "$ROOTFS/dev" || true

# 6. Extraction des fichiers de boot
echo "📂 4/5 : Préparation du chargeur de démarrage..."
KERNEL_FILE=$(sudo find "$ROOTFS/boot" -name "vmlinuz-*" | head -n 1)
INITRD_FILE=$(sudo find "$ROOTFS/boot" -name "initrd.img-*" | head -n 1)

sudo cp "$KERNEL_FILE" "$MINI_ISO/casper/vmlinuz"
sudo cp "$INITRD_FILE" "$MINI_ISO/casper/initrd"

# Nettoyage
sudo chroot "$ROOTFS" apt-get clean >/dev/null 2>&1
sudo rm -rf "$ROOTFS/var/lib/apt/lists/*"
sudo rm -rf "$ROOTFS/usr/share/doc/*"
sudo rm -rf "$ROOTFS/usr/share/man/*"

# 7. Compression et création ISO
echo "🗜️ 5/5 : Compression SquashFS & Génération ISO..."
sudo mksquashfs "$ROOTFS" "$MINI_ISO/casper/filesystem.squashfs" -comp xz -b 1M -no-xattrs >/dev/null 2>&1
sudo rm -rf "$ROOTFS"

mkdir -p "$MINI_ISO/isolinux"
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$MINI_ISO/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$MINI_ISO/isolinux/"

cat <<EOF | sudo tee "$MINI_ISO/isolinux/isolinux.cfg" >/dev/null
default linux
label linux
  kernel /casper/vmlinuz
  append initrd=/casper/initrd boot=casper quiet splash ---
EOF

sudo chmod -R 755 "$WORK_DIR"

cd "$MINI_ISO"
sudo xorriso -as mkisofs \
  -r -V "MINI_LINUX" \
  -o /workspaces/VPS/custom-slowdns.iso \
  -J -joliet-long \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  . >/dev/null 2>&1

sudo chown $(whoami):$(whoami) /workspaces/VPS/custom-slowdns.iso

echo "============================================="
echo "🎉 ISO COMPLÈTE PRÊTE : /workspaces/VPS/custom-slowdns.iso"
echo "============================================="