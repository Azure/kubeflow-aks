---
title: "Least-privilege deployment role"
---

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
