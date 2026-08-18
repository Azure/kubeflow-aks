---
categories: ["prerequisites"]
tags: ["docs"]
title: "Prerequisites"
linkTitle: "Prerequisites"
date: 2025-08-19
weight: 1
description: >
  Set up your environment for deploying Kubeflow for AKS
---

# Kubeflow on AKS Prerequisites

For all Kubeflow on AKS deployment options, you will need the following

- An **Azure Subscription** (e.g. [Free](https://aka.ms/azure-free-account) or [Student](https://aka.ms/azure-student-account) account)
  {{< alert color="warning" >}}⚠️ Warning: In order to complete the deployments, you will need to have either  `User Access Admin` **and** `Contributor` or `Owner` access to the subscription you are deploying into.{{< /alert >}}
- The [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli)
- A [GitHub Account](https://github.com)
- Bash shell (e.g. macOS, Linux, [Windows Subsystem for Linux (WSL)](https://docs.microsoft.com/windows/wsl/about), [Multipass](https://multipass.run/), or [Azure Cloud Shell](https://docs.microsoft.com/azure/cloud-shell/quickstart))
- The following installed in your Bash shell
    - [Kustomize](https://github.com/kubernetes-sigs/kustomize/releases) v5.8.1 or greater
      - Install Kustomize
      ```bash
      curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
      sudo mv ./kustomize /usr/local/bin/kustomize
      ```
      Verify the installation:
      ```bash
      kustomize version
      ```
    - [Kubelogin](https://github.com/Azure/kubelogin), the exec plugin that signs you in to the cluster. The Azure CLI ships and updates `kubectl` and `kubelogin` for you; install them explicitly only if you are not using it:
        ```bash
        az aks install-cli
        ```
    - git
    - [just](https://just.systems/man/en/packages.html), which runs every deployment step in this repository
    - [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install)
    - [Kubectl](https://kubernetes.io/docs/tasks/tools/), within one minor version of the cluster's Kubernetes version
    - [Go](https://go.dev/doc/install) 1.26.6 or greater
    - [sed](https://gnuwin32.sourceforge.net/packages/sed.htm), used to render the Dex configuration
