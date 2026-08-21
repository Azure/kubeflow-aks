---
title: "Manage Kubeflow users"
aliases:
  - "/main/docs/deployment-options/authn-users-entra/"
  - "/docs/deployment-options/authn-users-entra/"
---

## Background

Change the Dex password and add more static users. Integrating Dex with Microsoft Entra ID is not covered here.

## Change the Dex password

The deployment no longer ships a default password: rendered manifests carry an unusable sentinel, and `just deploy-kubeflow` generates a real one at install time. To replace it at any point, run:

```bash
just configure-dex
```

That generates a 32-character password and its cost-12 bcrypt hash, validates the hash, replaces the `dex-passwords` Secret, restarts Dex, refreshes the Istio `RequestAuthentication` JWKS URI, and prints the password once. To generate a password and hash without touching the cluster, run `just password`.

> [!WARNING]
> Do not paste a password into an online bcrypt generator. `just password` produces the hash locally from a cryptographically secure source.

To add more users, edit `overlay/patches/dex-config.yaml.in`, which patches Dex's ConfigMap when the overlay is rendered. Keep using `hashFromEnv` so no hash is committed:

```yaml
    staticPasswords:
    - email: user@example.com
      hashFromEnv: DEX_USER_PASSWORD
      username: user
      userID: "15841185641784"
    - email: user2@example.com
      hashFromEnv: DEX_USER2_PASSWORD
      username: user2
      userID: "15841185641785"
```

Generate the second user's credentials, saving the printed password before continuing:

```bash
just password
```

Add its hash to the same Secret, then re-render and restart Dex:

```bash
kubectl patch secret dex-passwords -n auth --type=json \
  -p='[{"op":"add","path":"/data/DEX_USER2_PASSWORD","value":"'"$(printf %s '<paste-the-hash>' | base64 | tr -d '\n')"'"}]'
just deploy-kubeflow
```
