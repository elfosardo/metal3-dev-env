#!/usr/bin/env bash
set -xe

# shellcheck disable=SC1091
source lib/logging.sh
# shellcheck disable=SC1091
source lib/common.sh

if [[ $OS == ubuntu ]]; then
  # shellcheck disable=SC1091
  source ubuntu_install_requirements.sh
else
  # shellcheck disable=SC1091
  source centos_install_requirements.sh
fi

if ! command -v minikube 2>/dev/null ; then
    curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    chmod +x minikube
    sudo mv minikube /usr/local/bin/.
fi

if ! command -v docker-machine-driver-kvm2 2>/dev/null ; then
    curl -LO https://storage.googleapis.com/minikube/releases/latest/docker-machine-driver-kvm2
    chmod +x docker-machine-driver-kvm2
    sudo mv docker-machine-driver-kvm2 /usr/local/bin/.
fi

if ! command -v kubectl 2>/dev/null ; then
    curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/.
fi

if ! command -v kustomize 2>/dev/null ; then
    curl -Lo kustomize "$(curl --silent -L https://github.com/kubernetes-sigs/kustomize/releases/latest 2>&1 | awk -F'"' '/linux_amd64/ { print "https://github.com"$2; exit }')"
    chmod +x kustomize
    sudo mv kustomize /usr/local/bin/.
fi

# Clean-up any old ironic containers
for name in ironic ironic-inspector dnsmasq httpd mariadb ipa-downloader; do
    sudo "${CONTAINER_RUNTIME}" ps | grep -w "$name$" && sudo "${CONTAINER_RUNTIME}" kill $name
    sudo "${CONTAINER_RUNTIME}" ps --all | grep -w "$name$" && sudo "${CONTAINER_RUNTIME}" rm $name -f
done

# Clean-up existing pod, if podman
case $CONTAINER_RUNTIME in
podman)
  if  sudo "${CONTAINER_RUNTIME}" pod exists ironic-pod ; then
      sudo "${CONTAINER_RUNTIME}" pod rm ironic-pod -f
  fi
  sudo "${CONTAINER_RUNTIME}" pod create -n ironic-pod
  ;;
esac

# Pull images we'll need
for IMAGE_VAR in IRONIC_IMAGE IPA_DOWNLOADER_IMAGE VBMC_IMAGE SUSHY_TOOLS_IMAGE; do
    IMAGE=${!IMAGE_VAR}
    sudo "${CONTAINER_RUNTIME}" pull "$IMAGE"
done

# Download IPA and CentOS 7 Images
mkdir -p "$IRONIC_IMAGE_DIR"
pushd "$IRONIC_IMAGE_DIR"

CENTOS_IMAGE=CentOS-7-x86_64-GenericCloud-1901.qcow2
if [ ! -f ${CENTOS_IMAGE} ] ; then
    curl --insecure --compressed -O -L http://cloud.centos.org/centos/7/images/${CENTOS_IMAGE}
    md5sum ${CENTOS_IMAGE} | awk '{print $1}' > ${CENTOS_IMAGE}.md5sum
fi
popd

ANSIBLE_FORCE_COLOR=true ansible-playbook \
  -e "working_dir=$WORKING_DIR" \
  -e "virthost=$HOSTNAME" \
  -i vm-setup/inventory.ini \
  -b -vvv vm-setup/install-package-playbook.yml

# Allow local non-root-user access to libvirt
# Restart libvirtd service to get the new group membership loaded
if ! id "$USER" | grep -q libvirt; then
  sudo usermod -a -G "libvirt" "$USER"
  sudo systemctl restart libvirtd
fi

function configure_minikube() {
    minikube config set vm-driver kvm2
}

function init_minikube() {
    #If the vm exists, it has already been initialized
    if [[ "$(sudo virsh list --all)" != *"minikube"* ]]; then
      sudo su -l -c "minikube start" "$USER"
      sudo su -l -c "minikube stop" "$USER"
    fi

    MINIKUBE_IFACES="$(sudo virsh domiflist minikube)"

    # The interface doesn't appear in the minikube VM with --live,
    # so just attach it before next boot. As long as the
    # 02_configure_host.sh script does not run, the provisioning network does
    # not exist. Attempting to start Minikube will fail until it is created.
    if ! echo "$MINIKUBE_IFACES" | grep -w provisioning  > /dev/null ; then
      sudo virsh attach-interface --domain minikube \
          --model virtio --source provisioning \
          --type network --config
    fi

    if ! echo "$MINIKUBE_IFACES" | grep -w baremetal  > /dev/null ; then
      sudo virsh attach-interface --domain minikube \
          --model virtio --source baremetal \
          --type network --config
    fi
}

configure_minikube
init_minikube
