default:
    @just --list

resource_group := env_var_or_default("RESOURCE_GROUP", "")
location := env_var_or_default("LOCATION", "eastus")
aks_name := env_var_or_default("AKS_NAME", "kubeflow-aks")
signedinuser := env_var_or_default("SIGNEDINUSER", "")
signedinuser_type := env_var_or_default("SIGNEDINUSER_TYPE", "User")
domain := env_var_or_default("DOMAIN", "")
dns_label := env_var_or_default("DNS_LABEL", "")

export RESOURCE_GROUP := resource_group
export LOCATION := location
export AKS_NAME := aks_name
export SIGNEDINUSER := signedinuser
export SIGNEDINUSER_TYPE := signedinuser_type
export DOMAIN := domain
export DNS_LABEL := dns_label
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT := "1"

# Preview the AKS deployment without changing anything.
validate:
    #!/usr/bin/env bash
    set -euo pipefail
    source versions.env
    : "${RESOURCE_GROUP:?Set RESOURCE_GROUP to an existing resource group}"
    az deployment group what-if \
        --resource-group "$RESOURCE_GROUP" \
        --template-file main.bicep \
        --parameters \
            "clusterName=$AKS_NAME" \
            "kubernetesVersion=$AKS_KUBERNETES_VERSION" \
            "signedinuser=$SIGNEDINUSER" \
            "signedinuserType=$SIGNEDINUSER_TYPE"

# Deploy the AKS cluster at resource-group scope.
deploy-aks:
    #!/usr/bin/env bash
    set -euo pipefail
    source versions.env
    : "${RESOURCE_GROUP:?Set RESOURCE_GROUP to an existing resource group}"
    az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --template-file main.bicep \
        --parameters \
            "clusterName=$AKS_NAME" \
            "kubernetesVersion=$AKS_KUBERNETES_VERSION" \
            "signedinuser=$SIGNEDINUSER" \
            "signedinuserType=$SIGNEDINUSER_TYPE"

# Get credentials for the AKS cluster.
credentials:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${RESOURCE_GROUP:?Set RESOURCE_GROUP to an existing resource group}"
    az aks get-credentials \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AKS_NAME" \
        --overwrite-existing

# Download, verify, and prepare the pinned Kubeflow release.
fetch-kubeflow:
    #!/usr/bin/env bash
    set -euo pipefail
    source versions.env
    if ! installed_kustomize="$(kustomize version 2>/dev/null)"; then
        printf 'Kustomize %s is required but kustomize is not available.\n' \
            "$KUSTOMIZE_VERSION" >&2
        exit 1
    fi
    if [[ "$installed_kustomize" != "$KUSTOMIZE_VERSION" ]]; then
        printf 'Kustomize %s is required; found %s.\n' \
            "$KUSTOMIZE_VERSION" "$installed_kustomize" >&2
        exit 1
    fi

    archive=".cache/community-distribution-${KUBEFLOW_VERSION}.tar.gz"
    release_dir=".cache/community-distribution-${KUBEFLOW_VERSION}"
    temp_archive="${archive}.tmp"
    trap 'rm -f "$temp_archive"' EXIT
    mkdir -p .cache

    curl --fail --location --silent --show-error \
        "https://codeload.github.com/kubeflow/community-distribution/tar.gz/refs/tags/${KUBEFLOW_VERSION}" \
        --output "$temp_archive"
    mv "$temp_archive" "$archive"
    echo "$KUBEFLOW_ARCHIVE_SHA256  $archive" | sha256sum --check --strict

    rm -rf -- "$release_dir"
    mkdir -p "$release_dir"
    tar -xzf "$archive" --strip-components=1 -C "$release_dir"
    cp -R overlay "$release_dir/aks-overlay"

# Install pinned Kubeflow and configure its runtime Dex credentials.
deploy-kubeflow: fetch-kubeflow
    #!/usr/bin/env bash
    set -euo pipefail
    source versions.env
    release_dir=".cache/community-distribution-${KUBEFLOW_VERSION}"

    domain_label_pattern='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
    if [[ -n "$DOMAIN" ]] &&
        { (( ${#DOMAIN} > 253 )) ||
          [[ ! "$DOMAIN" =~ ^${domain_label_pattern}(\.${domain_label_pattern})+$ ]]; }; then
        printf 'DOMAIN must be a lower-case ASCII FQDN without a scheme, path, port, wildcard, or trailing dot.\n' >&2
        exit 1
    fi
    if [[ -n "$DNS_LABEL" ]] &&
        [[ ! "$DNS_LABEL" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        printf 'DNS_LABEL must be 1-63 lower-case letters, digits, or hyphens and start and end with a letter or digit.\n' >&2
        exit 1
    fi

    if ! deployment_output_tsv="$(
        az deployment group show \
            --resource-group "$RESOURCE_GROUP" \
            --name main \
            --query '[
                properties.outputs.dnsLabel.value,
                properties.outputs.kubeflowHostname.value,
                properties.outputs.location.value
            ]' \
            --output tsv
    )"; then
        printf 'Failed to read AKS deployment outputs. Run just deploy-aks first.\n' >&2
        exit 1
    fi
    mapfile -t deployment_outputs < <(
        printf '%s\n' "$deployment_output_tsv" | tr '\t' '\n'
    )
    if (( ${#deployment_outputs[@]} != 3 )); then
        printf 'Expected three AKS deployment outputs, got %d.\n' \
            "${#deployment_outputs[@]}" >&2
        exit 1
    fi
    default_dns_label="${deployment_outputs[0]}"
    default_kubeflow_host="${deployment_outputs[1]}"
    deployment_location="${deployment_outputs[2]}"
    : "${default_dns_label:?AKS deployment output dnsLabel is empty}"
    : "${default_kubeflow_host:?AKS deployment output kubeflowHostname is empty}"
    : "${deployment_location:?AKS deployment output location is empty}"

    selected_dns_label="${DNS_LABEL:-$default_dns_label}"
    azure_host="${selected_dns_label}.${deployment_location,,}.cloudapp.azure.com"
    kubeflow_host="${DOMAIN:-$azure_host}"
    if [[ -z "$DNS_LABEL" ]]; then
        test "$azure_host" = "$default_kubeflow_host"
    fi

    printf '%s\n' \
        "DNS_LABEL=$selected_dns_label" \
        "KUBEFLOW_HOST=$kubeflow_host" \
        "DEX_ISSUER=https://${kubeflow_host}/dex" \
        "DEX_LOGIN_URL=https://${kubeflow_host}/dex/auth" \
        "OAUTH2_REDIRECT_URI=https://${kubeflow_host}/oauth2/callback" \
        > "$release_dir/aks-overlay/params.env"
    sed \
        -e "s|@@DEX_ISSUER@@|https://${kubeflow_host}/dex|g" \
        -e "s|@@OAUTH2_REDIRECT_URI@@|https://${kubeflow_host}/oauth2/callback|g" \
        "$release_dir/aks-overlay/patches/dex-config.yaml.in" \
        > "$release_dir/aks-overlay/patches/dex-config.yaml"
    ! grep -q '@@' "$release_dir/aks-overlay/patches/dex-config.yaml"

    credential_output="$(cd tools/password && go run . --deployment-machine)"
    mapfile -t deployment_credentials <<< "$credential_output"
    if (( ${#deployment_credentials[@]} != 4 )) ||
       [[ -z "${deployment_credentials[0]}" ||
          -z "${deployment_credentials[1]}" ||
          -z "${deployment_credentials[2]}" ||
          -z "${deployment_credentials[3]}" ]]; then
        printf 'Password tool returned incomplete deployment output; refusing to render authentication secrets.\n' >&2
        exit 1
    fi
    password="${deployment_credentials[0]}"
    hash="${deployment_credentials[1]}"
    oidc_client_secret="${deployment_credentials[2]}"
    oauth2_cookie_secret="${deployment_credentials[3]}"
    (cd tools/password && go run . --validate-hash "$hash")
    hash_b64="$(printf %s "$hash" | base64 | tr -d '\n')"
    oidc_client_secret_b64="$(
        printf %s "$oidc_client_secret" | base64 | tr -d '\n'
    )"
    oauth2_cookie_secret_b64="$(
        printf %s "$oauth2_cookie_secret" | base64 | tr -d '\n'
    )"

    # Every hostname in the overlay is a seed that kustomize replacements
    # overwrite from params.env. Authentication placeholders are replaced in
    # memory so generated credentials are never written to disk.
    rendered="$(
        kustomize build "$release_dir/aks-overlay" |
            sed \
                -e "s|@@DEX_PASSWORD_HASH_B64@@|${hash_b64}|g" \
                -e "s|@@OIDC_CLIENT_SECRET_B64@@|${oidc_client_secret_b64}|g" \
                -e "s|@@OAUTH2_COOKIE_SECRET_B64@@|${oauth2_cookie_secret_b64}|g"
    )"
    if grep -qE 'replaced-by-kustomize|@@' <<<"$rendered"; then
        printf 'Rendered manifests still contain a placeholder, so a kustomize replacement did not match. Refusing to apply.\n' >&2
        grep -nE 'replaced-by-kustomize|@@' <<<"$rendered" | head -5 >&2
        exit 1
    fi

    attempt=1
    injection_retried=0
    while true; do
        if apply_output="$(printf '%s\n' "$rendered" |
            kubectl apply --server-side --force-conflicts -f - 2>&1)"; then
            printf '%s\n' "$apply_output"
            break
        fi
        printf '%s\n' "$apply_output" >&2

        # A cluster enforcing Azure Policy or the AKS managed admission
        # policies rejects this workload outright, so retrying only wastes
        # time.
        if grep -qE 'validation\.gatekeeper\.sh|ValidatingAdmissionPolicy' \
            <<<"$apply_output"; then
            printf 'Cluster policy rejected Kubeflow. This workload needs a cluster that does not enforce Azure Policy or the AKS managed admission policies.\n' >&2
            exit 1
        fi

        # Kubeflow's trainer-webhook NetworkPolicy admits only pods carrying
        # the service.istio.io/canonical-name label, which Istio adds at
        # injection time. A controller that started before istiod was serving
        # never gets it, so its webhook stays unreachable however long we
        # retry. Restart it once istiod is up, then carry on.
        if (( injection_retried == 0 )) &&
            grep -q 'trainer.kubeflow.org' <<<"$apply_output"; then
            if kubectl rollout status deployment/istiod \
                --namespace istio-system --timeout=5m >&2; then
                printf 'Restarting the trainer controller so Istio labels it.\n' >&2
                kubectl rollout restart \
                    deployment/kubeflow-trainer-controller-manager \
                    --namespace kubeflow-system >&2 || true
                kubectl rollout status \
                    deployment/kubeflow-trainer-controller-manager \
                    --namespace kubeflow-system --timeout=5m >&2 || true
                injection_retried=1
            fi
        fi

        if (( attempt == 15 )); then
            printf 'Failed after 15 attempts: kustomize build aks-overlay\n' >&2
            exit 1
        fi
        printf 'Retrying to apply resources\n'
        sleep 20
        ((attempt += 1))
    done

    just --quiet _restart-auth

    ingress_ip=""
    for attempt in {1..60}; do
        ingress_ip="$(
            kubectl get service istio-ingressgateway \
                --namespace istio-system \
                --output=jsonpath='{.status.loadBalancer.ingress[0].ip}'
        )"
        if [[ -n "$ingress_ip" ]]; then
            break
        fi
        if (( attempt < 60 )); then
            sleep 10
        fi
    done
    if [[ -z "$ingress_ip" ]]; then
        printf 'Istio ingress did not receive an IP address within 10 minutes.\n' >&2
        kubectl describe service istio-ingressgateway --namespace istio-system >&2
        exit 1
    fi

    printf 'Username: user@example.com\nPassword: %s\nURL: https://%s\nIngress IP: %s\n' \
        "$password" "$kubeflow_host" "$ingress_ip"
    if [[ -n "$DOMAIN" ]]; then
        printf 'Create this unproxied DNS record before running just wait-ready:\n'
        printf '%s CNAME %s\n' "$DOMAIN" "$azure_host"
        printf 'Alternatively: %s A %s\n' "$DOMAIN" "$ingress_ip"
    fi

# Restart Dex and OAuth2 Proxy after changing their runtime secrets.
_restart-auth:
    #!/usr/bin/env bash
    set -euo pipefail
    kubectl rollout restart deployment/dex --namespace auth >&2
    kubectl rollout status deployment/dex --namespace auth --timeout=5m >&2
    jwks_uri="http://dex.auth.svc.cluster.local:5556/dex/keys?refresh=$(date -u +%s)"
    kubectl patch requestauthentication/dex-jwt \
        --namespace istio-system \
        --type=json \
        --patch="[
            {
                \"op\": \"replace\",
                \"path\": \"/spec/jwtRules/0/jwksUri\",
                \"value\": \"${jwks_uri}\"
            }
        ]" >&2
    kubectl rollout restart deployment/oauth2-proxy \
        --namespace oauth2-proxy >&2
    kubectl rollout status deployment/oauth2-proxy \
        --namespace oauth2-proxy --timeout=5m >&2

# Generate and apply runtime Dex credentials, then restart authentication.
configure-dex:
    #!/usr/bin/env bash
    set -euo pipefail
    credential_output="$(cd tools/password && go run . --machine)"
    mapfile -t credentials <<< "$credential_output"
    if (( ${#credentials[@]} != 2 )) ||
       [[ -z "${credentials[0]}" || -z "${credentials[1]}" ]]; then
        printf 'Password tool returned incomplete machine output; refusing to update dex-passwords.\n' >&2
        exit 1
    fi
    password="${credentials[0]}"
    hash="${credentials[1]}"
    (cd tools/password && go run . --validate-hash "$hash")

    kubectl create secret generic dex-passwords \
        --namespace auth \
        --from-literal="DEX_USER_PASSWORD=$hash" \
        --dry-run=client \
        --output yaml |
        kubectl apply --filename - >&2
    just --quiet _restart-auth

    printf 'Password: %s\n' "$password"

# Wait for every Kubeflow pod and the TLS certificate to become ready.
wait-ready:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! kubectl wait --for=condition=Ready pods --all --all-namespaces \
        --field-selector=status.phase!=Succeeded --timeout=20m; then
        printf 'Pods that did not become ready:\n' >&2
        kubectl get pods --all-namespaces \
            --field-selector=status.phase!=Succeeded \
            --output=jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.phase}{"\n"}{end}' |
            awk -F '\t' '$3 != "True"' >&2 || true
        exit 1
    fi
    kubectl wait --for=condition=Ready certificate/kubeflow-tls \
        --namespace istio-system --timeout=15m
    kubectl rollout status deployment/dex --namespace auth --timeout=5m
    kubectl rollout status deployment/oauth2-proxy --namespace oauth2-proxy --timeout=5m

# Check the public HTTPS endpoint with trusted TLS.
e2e:
    #!/usr/bin/env bash
    set -euo pipefail
    host="$(
        kubectl get certificate kubeflow-tls \
            --namespace istio-system \
            --output=jsonpath='{.spec.dnsNames[0]}'
    )"
    result="$(
        curl --silent --show-error --output /dev/null \
            --write-out '%{http_code} %{ssl_verify_result} %{redirect_url}' \
            "https://${host}/"
    )"
    read -r status ssl_verify_result redirect_url <<< "$result"
    test "$ssl_verify_result" = "0"
    test "$status" = "302"
    [[ "$redirect_url" == "https://${host}/dex/auth?"* ]]
    printf 'HTTPS endpoint: https://%s/ redirects to Dex (%s, TLS verification %s)\n' \
        "$host" "$status" "$ssl_verify_result"

# Generate a 32-character password and its cost-12 bcrypt hash.
password:
    @cd tools/password && go run .

# Empty the resource group while preserving it and its scoped access.
group-empty:
    #!/usr/bin/env bash
    set -euo pipefail
    : "${RESOURCE_GROUP:?Set RESOURCE_GROUP to an existing resource group}"
    temp_dir="$(mktemp -d)"
    empty_bicep="$temp_dir/empty.bicep"
    trap 'rm -f "$empty_bicep"; rmdir "$temp_dir"' EXIT
    : > "$empty_bicep"

    printf 'Emptying RESOURCE_GROUP %s in 10 seconds.\n' "$RESOURCE_GROUP"
    sleep 10
    az deployment group create \
        --resource-group "$RESOURCE_GROUP" \
        --template-file "$empty_bicep" \
        --mode Complete

# Remove the downloaded and extracted Kubeflow release.
clean-cache:
    rm -rf -- .cache
