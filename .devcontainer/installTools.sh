#!/bin/bash

# ensure submodules are also cloned
git submodule update --init --recursive

# install kustomize version 3.2.0
wget -O kustomize https://github.com/kubernetes-sigs/kustomize/releases/download/v3.2.0/kustomize_3.2.0_linux_amd64
chmod +x kustomize
sudo mv kustomize /usr/bin/

# install kubelogin
wget https://github.com/Azure/kubelogin/releases/download/v0.0.26/kubelogin-linux-amd64.zip
unzip kubelogin-linux-amd64.zip
sudo mv bin/linux_amd64/kubelogin /usr/bin/
rm -rf ./bin
rm kubelogin-linux-amd64.zip