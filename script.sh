#!/bin/bash
set -e

# ================================
# SCRIPT COMPLETO DEBIAN + RAID1 + LUKS + LVM
# Para uso no Rescue Mode da OVH
# ================================

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurações principais
DISK1="/dev/nvme0n1"
DISK2="/dev/nvme1n1"
RAID_DEVICE="/dev/md0"
CRYPT_NAME="cryptroot"
VG_NAME="pve"
LV_ROOT_SIZE="120G"
LV_SWAP_SIZE="64G"

# Configurações do sistema
HOSTNAME="pve01-us"
TIMEZONE="America/New_York"
DEBIAN_SUITE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"

# Função para log colorido
log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Verificação inicial
log "🔍 VERIFICANDO AMBIENTE RESCUE MODE"
if [ ! -f /etc/rescue ]; then
    warning "Este script foi feito para o rescue mode da OVH"
    read -p "Continuar mesmo assim? (s/N): " continue_anyway
    if [ "$continue_anyway" != "s" ]; then
        exit 1
    fi
fi

# Verificar discos
log "📀 VERIFICANDO DISCOS DISPONÍVEIS"
lsblk
if [ ! -b "$DISK1" ] || [ ! -b "$DISK2" ]; then
    error "Discos $DISK1 ou $DISK2 não encontrados!"
fi

echo ""
echo -e "${RED}⚠️  ATENÇÃO: Este script irá APAGAR TODOS OS DADOS dos discos:${NC}"
echo "    $DISK1 e $DISK2"
echo ""
read -p "Digite 'CONFIRMO' para continuar: " confirm
if [ "$confirm" != "CONFIRMO" ]; then
    echo "Operação cancelada."
    exit 1
fi

# Atualizar sistema rescue
log "📦 ATUALIZANDO SISTEMA RESCUE"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y mdadm cryptsetup lvm2 debootstrap parted gdisk

# Configurar PATH
export PATH=$PATH:/usr/sbin:/sbin

log "🗑️ LIMPANDO DISCOS"
for DISK in "$DISK1" "$DISK2"; do
    info "Limpando $DISK..."
    wipefs -a "$DISK" || true
    dd if=/dev/zero of="$DISK" bs=1M count=100 || true
    partprobe "$DISK" || true
done

log "📝 CRIANDO PARTIÇÕES"
for DISK in "$DISK1" "$DISK2"; do
    info "Particionando $DISK..."
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary ext4 1MiB 1000MiB        # /boot
    parted -s "$DISK" mkpart primary fat32 1000MiB 2024MiB    # /boot/efi (1024MB)
    parted -s "$DISK" mkpart primary ext4 2024MiB 100%        # RAID
    
    # Marcar EFI como bootable
    parted -s "$DISK" set 2 esp on
    partprobe "$DISK"
done

log "🔄 CRIANDO RAID1"
mdadm --create --verbose "$RAID_DEVICE" --level=1 --raid-devices=2 "${DISK1}p3" "${DISK2}p3"

# Aguardar RAID estabilizar
sleep 5

# Salvar configuração RAID
mkdir -p /etc/mdadm
mdadm --detail --scan > /etc/mdadm/mdadm.conf

log "🔐 CONFIGURANDO LUKS"
# Gerar senha aleatória ou usar uma fixa para automação
LUKS_PASSWORD="$(openssl rand -base64 32)"
echo "=== SENHA LUKS GERADA ==="
echo "ANOTE ESTA SENHA: $LUKS_PASSWORD"
echo "========================="
read -p "Pressione Enter para continuar..."

echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat "$RAID_DEVICE" -
echo -n "$LUKS_PASSWORD" | cryptsetup open "$RAID_DEVICE" "$CRYPT_NAME" -

log "📦 CONFIGURANDO LVM"
pvcreate "/dev/mapper/$CRYPT_NAME"
vgcreate "$VG_NAME" "/dev/mapper/$CRYPT_NAME"
lvcreate -L "$LV_ROOT_SIZE" -n root "$VG_NAME"
lvcreate -L "$LV_SWAP_SIZE" -n swap "$VG_NAME"

log "💾 FORMATANDO SISTEMAS DE ARQUIVOS"
# Formatar volumes LVM
mkfs.ext4 -L "root" "/dev/$VG_NAME/root"
mkswap -L "swap" "/dev/$VG_NAME/swap"

# Formatar partições de boot
mkfs.ext4 -L "boot" "${DISK1}p1"
mkfs.vfat -F32 -n "EFI" "${DISK1}p2"

# Boot redundante
mkfs.ext4 -L "boot2" "${DISK2}p1"
mkfs.vfat -F32 -n "EFI2" "${DISK2}p2"

log "🗂️ MONTANDO SISTEMA"
mount "/dev/$VG_NAME/root" /mnt
mkdir -p /mnt/boot /mnt/boot/efi
mount "${DISK1}p1" /mnt/boot
mount "${DISK1}p2" /mnt/boot/efi
swapon "/dev/$VG_NAME/swap"

log "🚀 INSTALANDO DEBIAN BASE"
debootstrap --arch=amd64 --include=openssh-server,sudo,vim,curl,wget,htop,locales "$DEBIAN_SUITE" /mnt "$DEBIAN_MIRROR"

log "⚙️ CONFIGURANDO CHROOT"
# Montar sistemas virtuais
mount --bind /dev /mnt/dev
mount --bind /dev/pts /mnt/dev/pts
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

# Copiar configurações de rede e DNS
cp /etc/resolv.conf /mnt/etc/

log "🔧 CONFIGURANDO SISTEMA NO CHROOT"

# Criar script para executar no chroot
cat > /mnt/setup_system.sh << 'CHROOT_EOF'
#!/bin/bash
set -e

# Configurar timezone
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Configurar locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "pt_PT.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/default/locale

# Configurar hostname
echo "pve01-us" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   pve01-us.localdomain pve01-us
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# Atualizar repositórios
cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb-src http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
EOF

apt update

# Instalar kernel e ferramentas essenciais
DEBIAN_FRONTEND=noninteractive apt install -y \
    linux-image-amd64 \
    linux-headers-amd64 \
    firmware-linux \
    grub-efi-amd64 \
    grub-efi-amd64-signed \
    shim-signed \
    mdadm \
    cryptsetup \
    lvm2 \
    initramfs-tools \
    openssh-server \
    sudo \
    vim \
    curl \
    wget \
    htop \
    net-tools \
    iputils-ping \
    dnsutils \
    rsync \
    screen \
    tmux

# Configurar MDADM
mkdir -p /etc/mdadm
echo 'ARRAY /dev/md0 metadata=1.2 name=pve01-us:0 UUID=AUTO devices=/dev/nvme0n1p3,/dev/nvme1n1p3' > /etc/mdadm/mdadm.conf

# Configurar crypttab
CRYPT_UUID=$(cryptsetup luksUUID /dev/md0)
echo "cryptroot UUID=$CRYPT_UUID none luks,discard" > /etc/crypttab

# Configurar fstab
ROOT_UUID=$(blkid -s UUID -o value /dev/pve/root)
BOOT_UUID=$(blkid -s UUID -o value /dev/nvme0n1p1)
EFI_UUID=$(blkid -s UUID -o value /dev/nvme0n1p2)
SWAP_UUID=$(blkid -s UUID -o value /dev/pve/swap)

cat > /etc/fstab << EOF
# /etc/fstab: static file system information.
UUID=$ROOT_UUID    /               ext4    defaults                        0 1
UUID=$BOOT_UUID    /boot           ext4    defaults                        0 2
UUID=$EFI_UUID     /boot/efi       vfat    umask=0077                      0 1
UUID=$SWAP_UUID    none            swap    sw                              0 0
proc               /proc           proc    defaults                        0 0
sysfs              /sys            sysfs   defaults                        0 0
devpts             /dev/pts        devpts  defaults                        0 0
tmpfs              /dev/shm        tmpfs   defaults                        0 0
EOF

# Configurar GRUB
echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX=""/GRUB_CMDLINE_LINUX="cryptdevice=\/dev\/md0:cryptroot"/' /etc/default/grub

# Atualizar initramfs
update-initramfs -u -k all

# Instalar GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --recheck
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --removable
update-grub

# Configurar SSH
systemctl enable ssh
mkdir -p /root/.ssh
chmod 700 /root/.ssh

# Configurar usuário
useradd -m -s /bin/bash -G sudo opnova
echo "opnova:opnova123" | chpasswd
echo "root:root123" | chpasswd

# Configurar sudo sem senha para opnova
echo "opnova ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/opnova

echo "Sistema configurado com sucesso!"
CHROOT_EOF

chmod +x /mnt/setup_system.sh

log "🎯 EXECUTANDO CONFIGURAÇÃO NO CHROOT"
chroot /mnt /setup_system.sh

log "🧹 LIMPEZA FINAL"
# Limpar arquivos temporários
rm /mnt/setup_system.sh
rm /mnt/etc/resolv.conf

# Desmontar sistemas
umount /mnt/boot/efi
umount /mnt/boot
swapoff "/dev/$VG_NAME/swap"
umount /mnt/sys
umount /mnt/proc
umount /mnt/dev/pts
umount /mnt/dev
umount /mnt

# Fechar LUKS
cryptsetup close "$CRYPT_NAME"

log "✅ INSTALAÇÃO COMPLETADA COM SUCESSO!"
echo ""
echo "📋 RESUMO DA INSTALAÇÃO:"
echo "   🔄 RAID1: $RAID_DEVICE"
echo "   🔐 LUKS: $CRYPT_NAME"
echo "   📦 VG: $VG_NAME"
echo "   💾 Root: $LV_ROOT_SIZE"
echo "   🔄 Swap: $LV_SWAP_SIZE"
echo "   🖥️  Hostname: $HOSTNAME"
echo ""
echo "👤 CREDENCIAIS:"
echo "   root: root123"
echo "   opnova: opnova123"
echo ""
echo "🔑 SENHA LUKS: $LUKS_PASSWORD"
echo ""
echo "🚀 PRÓXIMO PASSO:"
echo "   1. Anote a senha LUKS!"
echo "   2. Reinicie o servidor (saia do rescue mode)"
echo "   3. O sistema pedirá a senha LUKS no boot"
echo ""
warning "⚠️  ANOTE A SENHA LUKS ANTES DE REINICIAR!"
