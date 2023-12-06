# Using a Private Registry for Kubeflow

The images used in the Kubeflow deployment are publicly available on Docker Hub. You can use the public images as is. In environments where you cannot access the public internet, you can use a private registry to host the images.

The [script](./privateRegistry.sh) scans the manifests folder for any Kustomization.yaml files, imports the images from each YAML file (if they are in a GitHub or Docker Hub registry) to your private ACR, and then updates the manifests to use the imported image in your ACR.
