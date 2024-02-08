#!/usr/bin/env bash
set -euo pipefail

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="DEBUG"

log() {
    local log_message=$1
    local log_priority=$2

    #check if level exists
    [[ ${levels[$log_priority]} ]] || return 1

    #check if level is enough
    (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return 2

    #log here
    d=$(date '+%Y-%m-%dT%H:%M:%S')
    echo -e "${d}\t${log_priority}\t${log_message}"
}

log "Starting installer script" "INFO"
log "Downloading from ${SHIM_LOCATION}..." "DEBUG"
log "RUNTIMECLASS_NAME: ${RUNTIMECLASS_NAME}" "DEBUG"
log "RUNTIMECLASS_HANDLER: ${RUNTIMECLASS_HANDLER}" "DEBUG"

mkdir -p /assets

curl -sL "${SHIM_LOCATION}"  | tar -xzf - -C /assets
log "Download successful" "INFO"

ls -lah /assets

log "Checking Kubernetes distribution..." "INFO"

KWASM_DIR=/opt/kwasm

CONTAINERD_CONF=/etc/containerd/config.toml
IS_MICROK8S=false
IS_K3S=false
IS_RKE2_AGENT=false
if ps aux | grep kubelet | grep -q snap/microk8s; then
    CONTAINERD_CONF=/var/snap/microk8s/current/args/containerd-template.toml
    IS_MICROK8S=true
    log "Detected MicroK8s..." "INFO"
    if nsenter -m/"${NODE_ROOT}"/proc/1/ns/mnt -- ls /var/snap/microk8s/current/args/containerd-template.toml > /dev/null 2>&1 ;then
        KWASM_DIR=/var/snap/microk8s/common/kwasm
    else
        log "Installer seems to run on microk8s but 'containerd-template.toml' not found." "ERROR"
        exit 1
    fi
elif ls "${NODE_ROOT}/var/lib/rancher/rke2/agent/etc/containerd/config.toml" > /dev/null 2>&1 ; then
    IS_RKE2_AGENT=true
    log "Detected RKE2..." "INFO"
    cp "${NODE_ROOT}/var/lib/rancher/rke2/agent/etc/containerd/config.toml" "${NODE_ROOT}/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl"
    CONTAINERD_CONF=/var/lib/rancher/rke2/agent/etc/containerd/config.toml.tmpl
elif ls "${NODE_ROOT}/var/lib/rancher/k3s/agent/etc/containerd/config.toml" > /dev/null 2>&1 ; then
    IS_K3S=true
    log "Detected K3S..." "INFO"
    cp "${NODE_ROOT}/var/lib/rancher/k3s/agent/etc/containerd/config.toml" "${NODE_ROOT}/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl"
    CONTAINERD_CONF=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
fi

log "Moving shim to ${NODE_ROOT}${KWASM_DIR}/bin/" "INFO"
mkdir -p "${NODE_ROOT}${KWASM_DIR}/bin/"
cp /assets/containerd-shim-* "${NODE_ROOT}${KWASM_DIR}/bin/"

# TODO check if runtime config is already present
if ! grep -q wasmtime "${NODE_ROOT}${CONTAINERD_CONF}"; then
    echo '
###START:'"${RUNTIMECLASS_NAME}"'###
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.'"${RUNTIMECLASS_HANDLER}"']
    runtime_type = "'${KWASM_DIR}'/bin/'"${RUNTIMECLASS_NAME}"'"
###END:'"${RUNTIMECLASS_NAME}"'###
' >> "${NODE_ROOT}${CONTAINERD_CONF}"
    rm -Rf "${NODE_ROOT}${KWASM_DIR}/active"
fi

log "Restarting systemd..." "INFO"
if [ ! -f "${NODE_ROOT}${KWASM_DIR}/active" ]; then
    touch "${NODE_ROOT}${KWASM_DIR}/active"
    if $IS_MICROK8S; then
        nsenter -m/"${NODE_ROOT}"/proc/1/ns/mnt -- systemctl restart snap.microk8s.daemon-containerd
    elif ls "${NODE_ROOT}/etc/init.d/containerd" > /dev/null 2>&1 ; then
        nsenter --target 1 --mount --uts --ipc --net -- /etc/init.d/containerd restart
    elif ls "${NODE_ROOT}/etc/init.d/k3s" > /dev/null 2>&1 ; then
        nsenter --target 1 --mount --uts --ipc --net -- /etc/init.d/k3s restart
    elif $IS_RKE2_AGENT; then
        nsenter --target 1 --mount --uts --ipc --net -- /bin/systemctl restart rke2-agent
    else
        nsenter -m/"${NODE_ROOT}"/proc/1/ns/mnt -- /bin/systemctl restart containerd
    fi
else
    log "No change in containerd/config.toml" "INFO"
fi

log "Fin." "INFO"