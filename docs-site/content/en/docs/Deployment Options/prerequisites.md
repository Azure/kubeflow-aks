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
- - A [GitHub Account](https://github.com)
- Bash shell (e.g. macOS, Linux, [Windows Subsystem for Linux (WSL)](https://docs.microsoft.com/windows/wsl/about), [Multipass](https://multipass.run/), [Azure Cloud Shell](https://docs.microsoft.com/azure/cloud-shell/quickstart), [GitHub Codespaces](https://github.com/features/codespaces), [devcontainers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers), etc). This repository comes with a .devcontainer folder that allows you to configure your Codespaces or devcontainers environment so that it has all the required Bash tools like kubelogin and the **correct** version of kustomize
- The following installed in your Bash shell if you are not going with the codespaces or devcontainers option
    - [Kustomize](https://github.com/kubernetes-sigs/kustomize/releases/tag/kustomize%2Fv5.7.1)
    - [Kubelogin](https://github.com/Azure/kubelogin/releases/tag/v0.2.10)
    - git
    - [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install)
    - [Kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/)
    - [sed](https://gnuwin32.sourceforge.net/packages/sed.htm) (optional)

{{< alert color="primary">}}If you have access to [GitHub Codespaces](https://docs.github.com/en/codespaces/overview) or [Docker Desktop](https://www.docker.com/products/docker-desktop/) on your local machine, it is highly recommended that you deploy this using a [devcontainer](https://code.visualstudio.com/docs/devcontainers/containers) as it includes all the tools you need. The configuration for the devcontainer can be found [here](https://github.com/azure/kubeflow-aks/tree/main/.devcontainer).{{< /alert >}}
