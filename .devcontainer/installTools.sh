#!/bin/bash

# ensure submodules are also cloned
git submodule update --init --recursive

# install kustomize version 3.2.0
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
chmod +x kustomize
sudo mv kustomize /usr/bin/

# install kubelogin
wget https://github.com/Azure/kubelogin/releases/download/v0.2.10/kubelogin-linux-amd64.zip
unzip kubelogin-linux-amd64.zip
sudo mv bin/linux_amd64/kubelogin /usr/bin/
rm -rf ./bin
rm kubelogin-linux-amd64.zip

# aks extension
az extension add --name aks-preview