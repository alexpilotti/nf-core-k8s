# A Kubernetes nf-core PoC

This repository includes a guide for setting up a
[Kubernetes](https://kubernetes.io/) (k8s) proof of concept (PoC) for the
purpose of running [nf-core](https://nf-co.re/) pipelines with the Nextflow
k8s executor.

## Prerequisites

One Linux host (bare-metal, even just a laptop, or a virtual machine) with a
recommended minimum of at least 16GB of RAM and 100GB of disk, plus a
statically assigned network address. A single shared network interface is
enough. It is recommended, but not required, to have one or more NVIDIA GPUs
with CUDA capabilities (e.g., RTX 4000, H100, etc.).

This guide does not provide details on how to configure a Kubernetes cluster
for production purposes (e.g., high availability, fault tolerance) as that is
out of the current scope.

**Docker** needs to be [installed](https://docs.docker.com/engine/install/).

Clone this repository:

```bash
git clone https://github.com/alexpilotti/nf-core-k8s
cd nf-core-k8s
```

## Kubernetes deployment

We will use [k3s](https://github.com/k3s-io/k3s) for simplicity:

```bash
curl -sfL https://get.k3s.io | sh -
mkdir -p ~/.kube/ && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && \
  sudo chown $USER:$USER ~/.kube/config

echo "export KUBECONFIG=~/.kube/config" >> ~/.bashrc
echo "alias k=kubectl" >> ~/.bashrc

. ~/.bashrc
```

Create a Kubernetes namespace named *nf-core* and set it as default:

```bash
kubectl create namespace nf-core
kubectl config set-context --current --namespace=nf-core
```

## NFS configuration

nf-core is based on [Nextflow](https://github.com/nextflow-io/nextflow), which
in turn provides a Kubernetes executor that can be used with a shared storage
to share data within the k8s cluster. This requires a Kubernetes Container
Storage Interfca (CSI) driver that supports **ReadWriteMany** persistent volumes
(PV). A list of such drivers is available
[here](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).

Among the possible options, for a PoC, a single **NFS** instance is just about
right, while for production purposes on-prem, **CephFS** provides a very
reliable option.

Note: the following instructions refer to **Ubuntu 24.04**, but can be easily
adapted to other Linux distributions.

Install the relevant NFS kernel modules and userspace tools:

```bash
sudo apt install nfs-common

sudo tee /etc/modules-load.d/nfs.conf << EOF
# Added for Docker nfs-server
nfs
nfsd
EOF

sudo modprobe nfs
sudo modprobe nfsd
```

Configure and start an NFSv4 service in a Docker container:

```bash
mkdir nfs
echo "/exports/data *(rw,fsid=0,sync,no_subtree_check)" > nfs/exports

sudo mkdir -p /data/nfs/nf-core
sudo chown nobody:nogroup /data/nfs/nf-core

./docker_nfs_run.sh
```

Edit *nf-core-pv-pvc.yaml* and replace YOUR_IP_ADDRESS with your local IP,
then apply it to create one shared NFS PV and a persistent volume claim (PVC)
that will be used by our nf-core pipelines:

```bash
kubectl apply -f nf-core-pv-pvc.yaml
```

## Docker registry

For simplicity, we are going to create a local container registry to store our
images and deploy them within the cluster. This step is optional and can be
replaced with a remoted registry if preferred.

To begin with, we need to add credentials to access the registry:

```bash
mkdir -p registry

REGISTRY_PASSWORD=$(openssl rand -hex 21)
# Save this password for later!
echo $REGISTRY_PASSWORD

# Mind the -B parameter, this is required
docker run --entrypoint htpasswd httpd:2 -Bbn nf-core $REGISTRY_PASSWORD > \
registry/registry.htpasswd
```

Start the Docker registry in a container. Please note that being this a PoC we
are using plain HTTP, but it is recommended to add HTTPS encryption for other
use cases.

```bash
./docker_registry_run.sh
```

Add an entry in the */etc/hosts* file, setting your local IP accordingly:
```bash
echo "<YOUR_IP_ADDRESS> registry.nf-core-k8s" | sudo tee -a /etc/hosts
```

B efore we login on the registry using Docker, in order to use HTTP and not
HTTPS, edit */etc/docker/daemon.json* and add **registry.nf-core-k8s:5000** to
**insecure-registries**, e.g.:

```
{
    "insecure-registries":["registry.nf-core-k8s:5000"]
}
```

Verify if everything works by logging in with Docker:

```bash
docker login registry.nf-core-k8s:5000 -u "nf-core" -p $REGISTRY_PASSWORD
```

Last, let's configure K3s to use the registry:

```bash
sudo tee /etc/rancher/k3s/registries.yaml << EOF
mirrors:
  "registry.nf-core-k8s:5000":
    endpoint:
      - "http://registry.nf-core-k8s:5000"

configs:
  "registry.nf-core-k8s:5000":
    auth:
      username: nf-core
      password: $REGISTRY_PASSWORD
    tls:
      insecure_skip_verify: true
EOF

# Restart K3s to load the registry settings:
sudo systemctl restart k3s
```

## Kubernetes service account

The Nextflow k8s executor needs a service account to be able to create
resources on the cluster on our behalf (e.g., pods):

```bash
kubectl apply -f nf-core-sa.yaml

# Verify, the following command shoud result in "yes":
kubectl auth can-i create pods \
--as=system:serviceaccount:nf-core:nf-core-sa -n nf-core
```

## Nextflow

There are various ways of using Kubeflow with Kubernetes. The
[documentation](https://nextflow.io/docs/latest/kubernetes.html) includes a
deprecated method (kuberun) some proprietary ones and a practical one
(running in a pod), although no detailed information is included for this last
option. A
[separate repository](https://github.com/seqeralabs/nf-k8s-best-practices)
includes a useful script named *kuberun.sh* that we modified for this PoC, to
create a pod within the k8s cluster that will run the pipeline and in turn
will spin up the required k8s resources (e.g., a pod/job for each task).

The Nextflow k8s executor needs a configuration file that has to be stored in
a location shared by all the pods (our shared NFS PV). The configuration file
includes, among other settings, instructions to mount the PV in the
*/workspace* path. Failing to do so, results in the tasks not being able to
access their data, typically signalled by the dreaded *".command.run: No such
file or directory"* error.

```bash
sudo mkdir -p /data/nfs/nf-core/$USER/
copy nextflow.config /data/nfs/nf-core/$USER/
```

We can now test if everything works as expected by running the
[nf-core/demo](https://github.com/nf-core/demo) pipeline:

```bash
# Copy a sample input file to the shared path:
sudo cp samplesheet.csv /data/nfs/nf-core/$USER/samplesheet.csv

# Run the pipeline
./kuberun.sh nf-core-data-pvc nf-core/demo \
  --input /workspace/$USER/samplesheet.csv \
  --outdir /workspace/$USER/results
```

If all goes well, the command's output will include:
**Pipeline completed successfully**

## NVIDIA GPU configuration

The following settings can be applied to share the GPU(s) available on the host
with the K8s cluster, allowing us to run nf-core pipeline tasks with GPU
acceleration.

### NVIDIA drivers

To begin with, the NVIDIA kernel drivers and utils specific to your GPU need to
be installed.

Note: the following instructions refer to **Ubuntu 24.04**, but can be easily
adapted to other Linux distributions.

```bash
# Get a list of supported drivers for your GPUs:
ubuntu-drivers devices
# Based on the output, decide which series to install, e.g. 535, 580, etc:
sudo apt-get install nvidia-headless-535-server nvidia-utils-535-server
# Reboot if needed
```

Check if everything is ok by running *nvidia-smi*:

```bash
# The output includes the driver version, CUDA version, GPU details and more
nvidia-smi
```

### NVIDIA Container Toolkit

Install the NVIDIA Container Toolkit:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# If after installing the NVIDIA container toolkit, nvidia-smi fails with:
# "Nvidia NVML Driver/library version mismatch", do a reboot

# Configure Docker and Containerd to use the NVIDIA Container Toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo nvidia-ctk runtime configure --runtime=containerd

# Test containerd with the NVIDIA Container Toolkit to make sure everything works
sudo ctr image pull docker.io/nvidia/cuda:12.1.1-base-ubuntu22.04
sudo ctr run --rm -t \
--runc-binary=/usr/bin/nvidia-container-runtime \
--env NVIDIA_VISIBLE_DEVICES=all \
docker.io/nvidia/cuda:12.1.1-base-ubuntu22.04 \
test nvidia-smi
```

### MVIDIA Kubernetes settings

Configure k3s's containerd with the NVIDIA Container Toolkit:

```bash
sudo nvidia-ctk runtime configure --runtime=containerd --config /var/lib/rancher/k3s/agent/etc/containerd/config.toml
# Restart k3s to apply the settings
sudo systemctl restart k3s
```

Add the NVIDIA RuntimeClass:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
    name: nvidia
handler: nvidia
EOF
```

### NVIDIA K8s Device Plugin

The k8s Device Plugin is used to share GPU resources within a K8s cluster.

First we need the [Helm](https://github.com/helm/helm) binaries:

```bash
wget https://get.helm.sh/helm-v4.0.0-linux-amd64.tar.gz
tar zxvf helm-v4.0.0-linux-amd64.tar.gz
mv linux-amd64/helm .
rm -rf linux-amd64 && rm helm-v4.0.0-linux-amd64.tar.gz
```

Install the Device Plugin using Helm:

```bash
./helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
./helm repo update
```

There are various strategies to share NVIDIA GPUs among K8s pods or jobs,
including
[time-slicing](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-sharing.html),
[MPS](https://docs.nvidia.com/deploy/mps/index.html) and
[MIG](https://www.nvidia.com/en-us/technologies/multi-instance-gpu/).
Covering the differences is outside of the current scope, we will use
time-slicing in our PoC.

In a nutshell, the time-slicing settings define how many shares of a GPU we
want to set. Setting the right number is a fine balance between how many tasks
we want to run concurrently and the available memory. To do so, adjust the
*replicas* setting in the *time_slicing_values.yaml* file accordingly or just
leave the current value for an initial evaluation.

We can now configure the Device Plugin:

```bash
helm upgrade -i \
nvidia-device-plugin \
nvdp/nvidia-device-plugin \
--version=0.17.0 \
--namespace nvdp \
--create-namespace \
--set runtimeClassName=nvidia \
--set migStrategy=none \
--set gfd.enabled=true \
--set-file config.map.config=time_slicing_values.yaml
```

This will take a few minutes, you can verify the progress by cheking the
status of the Device Plugin pods:

```bash
# Wait until the status of all pods is "Running"
kubectl get pods -n nvdp
```

Last, we need to wait until the node configuration is complete:

```bash
# When done, the ouput includes "nvidia.com/gpu.sharing-strategy=time-slicing"
kubectl describe node $(hostname) | grep nvidia.com/gpu.sharing-strategy
```

### Verify GPU access from within a K8s job

```bash
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: nvidia-smi
  namespace: nf-core
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      runtimeClassName: nvidia
      containers:
      - name: nvidia-smi
        image: nvidia/cuda:12.6.3-devel-ubuntu24.04
        command: ["/usr/bin/nvidia-smi"]
        resources:
          limits:
            nvidia.com/gpu: 1
EOF

kubectl apply -f nvidia-smi-job.yaml
kubectl wait --for=condition=complete job/nvidia-smi
# If all went well, the logs include the nvidia-smi output
kubectl logs job/nvidia-smi
kubectl delete job/nvidia-smi
```
