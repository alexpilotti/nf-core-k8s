#!/bin/bash
docker run \
  --name=nfs-server \
  -d \
  -v /data/nfs/nf-core:/exports/data \
  -v $(pwd)/nfs/exports:/etc/exports:ro \
  -e NFS_DISABLE_VERSION_3=1 \
  --privileged \
  -p 2049:2049 \
  --restart=unless-stopped \
  erichough/nfs-server
