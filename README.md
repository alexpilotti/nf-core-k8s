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
