---
categories: ["prerequisites"]
tags: ["docs"]
title: "Prerequisites"
linkTitle: "Prerequisites"
date: 2025-08-19
weight: 1
description: >
  Set up your environment for deploying Kubeflow for AKS
aliases: ["/main/docs/deployment-options/prerequisites/"]
---

# Kubeflow on AKS Prerequisites

For all Kubeflow on AKS deployment options, you will need the following

- An **Azure Subscription** (e.g. [Free](https://aka.ms/azure-free-account) or [Student](https://aka.ms/azure-student-account) account)
  {{< alert color="warning" >}}⚠️ The deployment identity needs the least-privilege custom role described below on the target resource group. `Owner`, or `Contributor` plus a constrained role-assignment permission, also works but grants more access than this deployment needs.{{< /alert >}}
- The [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli)
- A [GitHub Account](https://github.com)
- Bash shell (e.g. macOS, Linux, [Windows Subsystem for Linux (WSL)](https://docs.microsoft.com/windows/wsl/about), [Multipass](https://multipass.run/), or [Azure Cloud Shell](https://docs.microsoft.com/azure/cloud-shell/quickstart))
- The following installed in your Bash shell
    - [Kustomize](https://github.com/kubernetes-sigs/kustomize/releases) v5.8.1 exactly. The deployment checks this because later versions can remove Kustomize APIs used by the pinned Kubeflow release.
      - Install Kustomize
      ```bash
      go install sigs.k8s.io/kustomize/kustomize/v5@v5.8.1
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

## Least-privilege deployment role

The deployment identity can use a custom role scoped to an existing target resource group. Creating that resource group, defining the custom role, and assigning it are bootstrap operations performed by an administrator. The deployment identity needs these management-plane actions:

```json
[
  "Microsoft.Resources/subscriptions/resourceGroups/read",
  "Microsoft.Resources/deployments/read",
  "Microsoft.Resources/deployments/write",
  "Microsoft.Resources/deployments/validate/action",
  "Microsoft.Resources/deployments/whatIf/action",
  "Microsoft.Resources/deployments/operations/read",
  "Microsoft.ContainerService/managedClusters/read",
  "Microsoft.ContainerService/managedClusters/write",
  "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",
  "Microsoft.Authorization/roleAssignments/read",
  "Microsoft.Authorization/roleAssignments/write"
]
```

These permissions let `just validate`, `just deploy-aks`, and `just credentials` run, and let `main.bicep` grant the selected principal Azure Kubernetes Service RBAC Cluster Admin on the new cluster. No policy-assignment permission is required. Resource-group deletion remains an administrator cleanup operation and is deliberately outside this role.

Because `Microsoft.Authorization/roleAssignments/write` can otherwise assign any role at the resource-group scope, assign the custom role with an Azure RBAC condition that permits only the Azure Kubernetes Service RBAC Cluster Admin role used by `main.bicep`:

```text
(
  (!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}))
  OR
  (
    @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
      ForAnyOfAnyValues:GuidEquals
      {b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b}
  )
)
```

Set the condition version to `2.0`. This constrained delegation prevents the deployment identity from using its role-assignment permission to grant Owner, User Access Administrator, or any other role.
