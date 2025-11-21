#!/bin/bash
docker run -d \
  -p 5000:5000 \
  --restart=unless-stopped \
  --name registry \
  -e REGISTRY_AUTH=htpasswd \
  -e REGISTRY_AUTH_HTPASSWD_REALM=Registry-Realm \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/registry.htpasswd \
  -e REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY=/data \
  -v $(pwd)/registry/data:/data \
  -v $(pwd)/registry/registry.htpasswd:/auth/registry.htpasswd \
  registry:2.8.3