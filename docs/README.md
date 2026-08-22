---
title: "Deploy Kubeflow with Password, Ingress and TLS"
aliases:
  - "/categories/"
  - "/categories/getstarted/"
  - "/categories/prerequisites/"
  - "/categories/quickstart/"
  - "/main/docs/"
  - "/main/docs/deployment-options/"
  - "/docs/deployment-options/"
  - "/main/docs/deployment-options/custom-password-tls/"
  - "/docs/deployment-options/custom-password-tls/"
  - "/main/docs/deployment-options/prerequisites/"
  - "/docs/deployment-options/prerequisites/"
  - "/main/docs/deployment-options/vanilla-installation/"
  - "/docs/deployment-options/vanilla-installation/"
  - "/main/docs/overview/"
  - "/docs/overview/"
  - "/main/docs/contribution-guidelines/"
  - "/docs/contribution-guidelines/"
  - "/main/search/"
  - "/search/"
  - "/tags/"
  - "/tags/docs/"
  - "/tags/sample/"
  - "/tags/test/"
---

## Background

Use the [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli) and the `main.bicep` template in this repository to deploy an [Azure Kubernetes Service (AKS)](https://learn.microsoft.com/en-us/azure/aks/what-is-aks) cluster, then install Kubeflow on it.
Kubeflow is installed from a pinned community distribution release on a hostname you choose, served over publicly trusted HTTPS, with a generated Dex password that can be rotated.

## Prerequisites

- An **Azure Subscription** (e.g. [Free](https://aka.ms/azure-free-account) or [Student](https://aka.ms/azure-student-account) account)
- A [GitHub Account](https://github.com)
- Bash 4 or later, on Linux, macOS, [Windows Subsystem for Linux (WSL)](https://docs.microsoft.com/windows/wsl/about), [Multipass](https://multipass.run/), or [Azure Cloud Shell](https://docs.microsoft.com/azure/cloud-shell/quickstart). The deployment uses `mapfile`, so the Bash 3.2 that macOS ships is too old; install a newer one with Homebrew

Install the following into that shell:

- [Azure CLI](https://docs.microsoft.com/cli/azure/install-azure-cli)
- [just](https://just.systems/man/en/packages.html), which runs every deployment step in this repository
- [Bicep](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install). `versions.env` records `0.46.1` as the version this deployment is built against, though nothing checks it at runtime
- [Kustomize](https://github.com/kubernetes-sigs/kustomize/releases) `v5.8.1` exactly, because later versions can remove Kustomize APIs used by the pinned Kubeflow release. This is the one version the deployment checks
- [Kubectl](https://kubernetes.io/docs/tasks/tools/) `v1.35`, `v1.36` or `v1.37`, within one minor version of the `1.36` API server this deployment creates
- [Kubelogin](https://github.com/Azure/kubelogin), the exec plugin that signs you in to the cluster
- [Go](https://go.dev/doc/install) 1.26.0 or greater. `tools/password/go.mod` requests the `go1.26.6` toolchain, which Go downloads on demand; install 1.26.6 itself if `GOTOOLCHAIN` is set to `local`
- [git](https://git-scm.com/downloads)
- [sed](https://gnuwin32.sourceforge.net/packages/sed.htm), used to render the Dex configuration
- `curl`, `tar`, `sha256sum`, `base64`, `tr`, `grep` and `awk`, used to fetch and verify the Kubeflow release and to render its secrets
- Network access to `codeload.github.com` and the Go module proxy

The deployment checks the Kustomize version and refuses to run on a mismatch, so install it with Go rather than a package manager:

```bash
go install sigs.k8s.io/kustomize/kustomize/v5@v5.8.1
kustomize version
```

The Azure CLI ships and updates `kubectl` and `kubelogin` for you. Install them explicitly only if you are not using it:

```bash
az aks install-cli
```

For a deployment identity with only the permissions this deployment needs, see the [least-privilege custom role](custom-role.md).

## Deploy AKS

Deploy the cluster with the `main.bicep` template in this repository.

The cluster uses Microsoft Entra ID with Azure RBAC for Kubernetes authorization, so `kubectl` access follows from a role assignment rather than from a shared credential. AKS still issues a cluster-local admin credential to callers holding `listClusterAdminCredential`, which bypasses Entra entirely; the [least-privilege custom role](custom-role.md) deliberately withholds it.

Login to the Azure CLI.
```bash
az login
```

> [!NOTE]
> If you have access to multiple subscriptions, you may need to run the following command to work with the appropriate subscription: `az account set --subscription <NAME_OR_ID_OF_SUBSCRIPTION>`.

Clone this repository.

```bash
git clone https://github.com/Azure/kubeflow-aks.git
cd kubeflow-aks
```

Set up your environment variables. Every recipe below reads these.

```bash
export RESOURCE_GROUP=kubeflow
export AKS_NAME=kubeflow-aks
export LOCATION=eastus
export SIGNEDINUSER=$(az ad signed-in-user show --query id --out tsv)
```

`SIGNEDINUSER` is the object ID of the signed-in user. The deployment grants it the `Azure Kubernetes Service RBAC Cluster Admin` role on the cluster, which `kubectl` needs because the cluster authenticates with Microsoft Entra ID.

`LOCATION` selects the region for the resource group created below. The cluster inherits the region from the resource group, so a group that already exists keeps its own region regardless of this value.

> [!NOTE]
> `az ad signed-in-user show` works only for an interactive user sign-in. Signed in as a service principal it fails with `/me request is only valid with delegated authentication flow`. Use the principal's object ID instead, and say so, because the deployment otherwise records the role assignment against the wrong principal type:
> ```bash
> export SIGNEDINUSER=$(az ad sp show --id "$AZURE_CLIENT_ID" --query id --out tsv)
> export SIGNEDINUSER_TYPE=ServicePrincipal
> ```
> `SIGNEDINUSER_TYPE` accepts `User`, `Group` or `ServicePrincipal` and defaults to `User`.

Create the resource group

```bash
az group create -n $RESOURCE_GROUP -l $LOCATION
```

Create the cluster. `just validate` previews the same deployment without changing anything.

```bash
just deploy-aks
```

> [!NOTE]
> `just deploy-aks` creates the cluster on the [Free pricing tier](https://learn.microsoft.com/en-us/azure/aks/free-standard-pricing-tiers), so cluster management costs nothing and you pay as you go for the nodes and other resources the cluster consumes. The Free tier carries no financially backed uptime SLA. The system node pool has two nodes, which you can size with the `nodeCount` and `vmSize` template parameters. Its Kubernetes version comes from `versions.env`. The cluster must not enforce Azure Policy or the AKS managed admission policies, which reject this workload. AKS also creates a second resource group of its own, named `MC_<resource group>_<cluster>_<region>`, which holds the nodes and their supporting resources.

### Connect to the cluster
After the cluster is created, you can connect to it using the Azure CLI. The following command retrieves the credentials for your AKS cluster and configures `kubectl` to use them.

```bash
just credentials
```

Verify connectivity to the cluster. This should return a list of nodes.

```bash
kubectl get nodes
```

> [!NOTE]
> The cluster authenticates to the Kubernetes API with Microsoft Entra ID, so `kubectl` signs you in through the `kubelogin` exec plugin and the first command prompts you to sign in. On Kubernetes 1.24 and later, `az aks get-credentials` writes that exec-plugin format for you, so there is no `kubelogin convert-kubeconfig` step for an interactive sign-in. In a non-interactive context such as CI, or when signed in as a service principal, run `kubelogin convert-kubeconfig -l azurecli` first. What authorizes you either way is the `Azure Kubernetes Service RBAC Cluster Admin` role assignment the deployment created for `$SIGNEDINUSER`.

## Install Kubeflow

Run the deployment from the repository root, with the same environment
variables exported above still set. No hostname needs choosing: the Bicep
deployment generated one, and Kubeflow is served on it over publicly trusted
HTTPS.

```bash
just deploy-kubeflow
```

The hostname is `kubeflow-<unique>.<location>.cloudapp.azure.com`, derived from
the resource group, the cluster name and the location.

> [!WARNING]
> Save the password `just deploy-kubeflow` prints. It is shown once and is never
> written to a file.

Wait for the deployment to settle, then check it:

```bash
just wait-ready
just e2e
```

`just wait-ready` waits for every pod, for the TLS certificate to be issued, and
for Dex and OAuth2 Proxy to roll out. `just e2e` then checks the endpoint
independently: it requires an unauthenticated request to redirect to Dex over
HTTPS with normal certificate verification.

> [!NOTE]
> `just wait-ready` allows fifteen minutes for the certificate. If it gives up
> there, look at the ACME challenge:
>
> ```bash
> kubectl get challenge --namespace istio-system
> ```
>
> A challenge still `pending` while the challenge URL answers from outside the
> cluster means cert-manager has stopped making progress rather than that
> anything is unreachable. Restarting its controller recovers it:
>
> ```bash
> kubectl delete pod --namespace cert-manager \
>     --selector app.kubernetes.io/component=controller
> ```
>
> The certificate usually issues within a minute. Re-run `just wait-ready`.

Open the printed `https://` URL and sign in as `user@example.com`.

### Choosing the Azure hostname

To pick the Azure DNS label rather than accept the generated one, set
`DNS_LABEL` before deploying. It has to be unique within the region.

```bash
export DNS_LABEL=my-unique-kubeflow-label

just deploy-kubeflow
```

The hostname becomes `$DNS_LABEL.$LOCATION.cloudapp.azure.com`.

### Serving Kubeflow on your own domain

To serve Kubeflow on a domain you control, set `DOMAIN` to a lower-case FQDN. It
becomes the certificate and login hostname, and `DNS_LABEL` selects the Azure
name you point it at.

```bash
export DOMAIN=kubeflow.example.com

just deploy-kubeflow
```

Unlike the other two, this path does not complete in one command. `just
deploy-kubeflow` stops and prints the unproxied DNS record to create. Create it,
let it resolve publicly, then continue:

```bash
just wait-ready
just e2e
```

The record must send `/.well-known/acme-challenge/` on port 80 straight to the
Istio ingress. Do not put it behind a proxy or provider-side forced HTTPS: Let's
Encrypt renews a 90-day certificate after roughly 60 days, so an interception
added later can leave a working deployment unable to renew. That path is the
only one exempt from Kubeflow's OAuth2 and JWT checks; all other unauthenticated
HTTP traffic is denied.

### Rotate the Dex password

```bash
just configure-dex
```

This generates a new password and cost-12 bcrypt hash, validates the hash before using it, replaces the `dex-passwords` Secret, restarts Dex, refreshes the `RequestAuthentication` JWKS URI so Istio picks up the new signing keys, and waits for the Dex and oauth2-proxy rollouts. Each run invalidates the previous password.

> [!WARNING]
> For production, integrate Dex with an external identity provider instead of relying on a shared static account. For password rotation and additional static users, see [Manage Kubeflow users](user-authentication.md).

## Clean up

Remove everything the deployment created, keeping the resource group and the
role assignments scoped to it:

```bash
just group-empty
```

This deploys an empty template in Complete mode, which deletes every resource in
the group. It prints the group it is about to empty and waits ten seconds first.

> [!WARNING]
> Check `RESOURCE_GROUP` before running this. It empties whichever group that
> variable names, and the resources are not recoverable.

Deleting the resource group itself also works, if you created it. It is worth
knowing what that costs: deleting a group removes every role assignment scoped
to it along with the resources. Where an administrator created the group and
granted access to it, including through the
[least-privilege custom role](custom-role.md), deleting the group destroys that
grant. The custom role deliberately excludes resource-group deletion for this
reason, so empty the group instead and leave removing it to whoever created it.
