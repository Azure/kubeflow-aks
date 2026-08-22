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

# Run local source, manifest, and test checks. Needs no Azure account.
validate-static:
    #!/usr/bin/env bash
    set -euo pipefail
    source versions.env

    require_equal() {
        if [[ "$3" != "$2" ]]; then
            printf '%s: expected %s, got %s\n' "$1" "$2" "$3" >&2
            exit 1
        fi
    }

    require_equal "pinned test dependency" "requests==2.32.5" \
        "$(grep -Ev '^[[:space:]]*(#|$)' tests/requirements.txt)"
    python3 -m py_compile tests/e2e.py tests/e2e_selftest.py
    python3 tests/e2e_selftest.py

    # The gate proves publicly trusted TLS, so it must own no way to turn
    # verification off, and it must reach stdout only through the scrubbing
    # helpers that redact the password and session cookies.
    if grep -Eq 'verify[[:space:]]*=[[:space:]]*False|skip_tls_verify|disable_warnings' \
        tests/e2e.py; then
        printf 'tests/e2e.py must not weaken TLS verification.\n' >&2
        exit 1
    fi
    require_equal "unscrubbed print calls in tests/e2e.py" "2" \
        "$(grep -Ec '^[[:space:]]*print\(' tests/e2e.py)"
    grep -Fq 'register_secret(dex_password)' tests/e2e.py
    for marker in trusted-tls dex-login dashboard notebook-controller notebook-api jupyterlab; do
        grep -Fq "\"PASS $marker\"" tests/e2e.py
    done

    # Upstream's Notebook fixture has no volumeMounts, and the Jupyter Web App
    # list endpoint subscripts that field, so listing it returns 500.
    grep -Fq 'volumeMounts:' tests/notebook.yaml
    grep -Fq 'namespace: kubeflow-user-example-com' tests/notebook.yaml

    just --quiet fetch-kubeflow

    # deploy-kubeflow writes params.env from the live deployment outputs, so
    # seed a throwaway one here. These values are only ever rendered, never
    # applied; the hostname is a fixed placeholder so the render is stable.
    overlay_dir=".cache/community-distribution-${KUBEFLOW_VERSION}/aks-overlay"
    static_host='kubeflow-static-validation.eastus.cloudapp.azure.com'
    printf '%s\n' \
        "DNS_LABEL=kubeflow-static-validation" \
        "KUBEFLOW_HOST=${static_host}" \
        "DEX_ISSUER=https://${static_host}/dex" \
        "DEX_LOGIN_URL=https://${static_host}/dex/auth" \
        "OAUTH2_REDIRECT_URI=https://${static_host}/oauth2/callback" \
        > "$overlay_dir/params.env"
    sed \
        -e "s|@@DEX_ISSUER@@|https://${static_host}/dex|g" \
        -e "s|@@OAUTH2_REDIRECT_URI@@|https://${static_host}/oauth2/callback|g" \
        "$overlay_dir/patches/dex-config.yaml.in" \
        > "$overlay_dir/patches/dex-config.yaml"

    rendered="$(mktemp)"
    trap 'rm -f "$rendered"' EXIT
    kustomize build ".cache/community-distribution-${KUBEFLOW_VERSION}/aks-overlay" \
        > "$rendered"
    test -s "$rendered"

    # Upstream selects the trainer webhook NetworkPolicy on an Istio-injected
    # label, so where NetworkPolicy is enforced and no sidecar was injected it
    # selects nothing and the admission webhook fails closed.
    if ! grep -A20 '^  name: trainer-webhook$' "$rendered" |
        grep -Fq 'app.kubernetes.io/name: trainer'; then
        printf 'trainer-webhook NetworkPolicy does not select a Deployment-owned label.\n' >&2
        exit 1
    fi
    require_equal "Istio-injected trainer selectors" "0" \
        "$(grep -Fc 'service.istio.io/canonical-name: trainer' "$rendered" || true)"

# Preview the AKS deployment without changing anything.
validate: validate-static
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

    just --quiet _restart-sidecarless
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

# Restart workloads that started before Istio could inject a sidecar.
[private]
_restart-sidecarless:
    #!/usr/bin/env bash
    set -euo pipefail
    # Rendering the release produces one manifest stream, so applying it
    # creates workloads in the same pass that creates the Istio control plane.
    # Anything created before istiod is serving never gets a proxy, and there
    # is no admission error to notice because at that moment there is no
    # webhook to fail. Those pods stay Ready while every route to them through
    # an ISTIO_MUTUAL DestinationRule times out and returns 503.
    kubectl rollout status deployment/istiod --namespace istio-system --timeout=10m >&2

    restarted=0
    mapfile -t injected_namespaces < <(
        kubectl get namespaces --selector=istio-injection=enabled \
            --output=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    )
    for namespace in "${injected_namespaces[@]}"; do
        [[ -n "$namespace" ]] || continue
        mapfile -t owners < <(
            kubectl get pods --namespace "$namespace" --output=json |
                jq -r '.items[]
                    | select((([.spec.initContainers[]?.name]
                             + [.spec.containers[].name]) | index("istio-proxy")) | not)
                    | select((.metadata.labels["sidecar.istio.io/inject"] // "") != "false")
                    | select((.metadata.annotations["sidecar.istio.io/inject"] // "") != "false")
                    | .metadata.ownerReferences[0]? // empty
                    | if .kind == "ReplicaSet"
                      then "deployment/" + (.name | sub("-[a-z0-9]+$"; ""))
                      elif .kind == "StatefulSet" then "statefulset/" + .name
                      else empty end' |
                sort -u
        )
        for owner in "${owners[@]}"; do
            [[ -n "$owner" ]] || continue
            kubectl rollout restart "$owner" --namespace "$namespace" >&2
            restarted=$((restarted + 1))
        done
    done

    if (( restarted > 0 )); then
        printf 'Restarted %d workloads that missed sidecar injection.\n' "$restarted" >&2
        for namespace in "${injected_namespaces[@]}"; do
            [[ -n "$namespace" ]] || continue
            kubectl rollout status deployment,statefulset --namespace "$namespace" \
                --timeout=15m >&2 || true
        done
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

    # A pod can be Ready and still have missed sidecar injection, which leaves
    # every ISTIO_MUTUAL route returning 503 through the ingress. Readiness
    # cannot detect that, so assert it, or a deployment where a large part of
    # the platform is unreachable reports healthy.
    uninjected=""
    for namespace in $(
        kubectl get namespaces --selector=istio-injection=enabled \
            --output=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    ); do
        uninjected+="$(
            kubectl get pods --namespace "$namespace" --output=json |
                jq -r --arg ns "$namespace" '.items[]
                    | select((([.spec.initContainers[]?.name]
                             + [.spec.containers[].name]) | index("istio-proxy")) | not)
                    | select((.metadata.labels["sidecar.istio.io/inject"] // "") != "false")
                    | select((.metadata.annotations["sidecar.istio.io/inject"] // "") != "false")
                    | "\($ns)/\(.metadata.name)"'
        )"
    done
    uninjected="$(printf '%s' "$uninjected" | grep -v '^$' || true)"
    if [[ -n "$uninjected" ]]; then
        printf 'Ready pods with no Istio sidecar that did not opt out:\n%s\n' \
            "$uninjected" >&2
        printf 'Rerun just deploy-kubeflow; it restarts workloads that missed injection.\n' >&2
        exit 1
    fi

# Run the authenticated end-to-end release gate against the live deployment.
e2e:
    #!/usr/bin/env bash
    set -euo pipefail
    notebook_manifest="tests/notebook.yaml"
    if [[ ! -f "$notebook_manifest" ]]; then
        printf 'Missing %s.\n' "$notebook_manifest" >&2
        exit 1
    fi

    host="$(
        kubectl get certificate kubeflow-tls \
            --namespace istio-system \
            --output=jsonpath='{.spec.dnsNames[0]}'
    )"
    : "${host:?Certificate/kubeflow-tls has no dnsNames[0]}"
    endpoint="https://${host}"

    # The endpoint is derived from the cluster, never supplied. An explicit
    # KUBEFLOW_ENDPOINT is honoured only as an assertion that the caller agrees
    # with the certificate, so a stale shell cannot silently test another host.
    if [[ -n "${KUBEFLOW_ENDPOINT:-}" && "$KUBEFLOW_ENDPOINT" != "$endpoint" ]]; then
        printf 'KUBEFLOW_ENDPOINT is %s but Certificate/kubeflow-tls selects %s.\n' \
            "$KUBEFLOW_ENDPOINT" "$endpoint" >&2
        exit 1
    fi

    dex_username="${DEX_USERNAME:-user@example.com}"
    dex_password="${DEX_PASSWORD:-}"
    if [[ -z "$dex_password" ]]; then
        if [[ ! -t 0 ]]; then
            printf 'DEX_PASSWORD is unset and stdin is not a terminal.\n' >&2
            exit 1
        fi
        read -r -s -p "Dex password for ${dex_username}: " dex_password
        printf '\n'
        : "${dex_password:?DEX_PASSWORD must not be empty}"
    fi

    venv_dir=".cache/e2e-venv"
    if [[ ! -x "$venv_dir/bin/python" ]]; then
        python3 -m venv "$venv_dir"
    fi
    "$venv_dir/bin/python" -m pip install --quiet --disable-pip-version-check \
        --requirement tests/requirements.txt

    KUBEFLOW_ENDPOINT="$endpoint" \
    DEX_USERNAME="$dex_username" \
    DEX_PASSWORD="$dex_password" \
    NOTEBOOK_MANIFEST="$notebook_manifest" \
        "$venv_dir/bin/python" tests/e2e.py

    if [[ -n "${E2E_SKIP_REISSUANCE:-}" ]]; then
        printf 'Skipping forced reissuance because E2E_SKIP_REISSUANCE is set.\n'
        exit 0
    fi

    # Prove ACME HTTP-01 renewal traverses Istio. Static rendering cannot show
    # this: only a changed serial on the wire does. Let's Encrypt allows five
    # duplicate certificates per week, so five forced reissuances per week is
    # the ceiling; set E2E_SKIP_REISSUANCE to run only the functional half.
    serial_on_the_wire() {
        openssl s_client -connect "${host}:443" -servername "$host" </dev/null 2>/dev/null |
            openssl x509 -noout -serial || true
    }
    old_serial="$(serial_on_the_wire)"
    : "${old_serial:?Could not read the serving certificate serial}"

    kubectl delete secret kubeflow-tls --namespace istio-system
    kubectl wait --for=condition=Ready certificate/kubeflow-tls \
        --namespace istio-system --timeout=15m

    new_serial=""
    for attempt in {1..90}; do
        new_serial="$(serial_on_the_wire)"
        if [[ -n "$new_serial" && "$new_serial" != "$old_serial" ]]; then
            break
        fi
        sleep 10
    done
    if [[ -z "$new_serial" || "$new_serial" == "$old_serial" ]]; then
        printf 'Certificate serial did not change after forced reissuance.\n' >&2
        exit 1
    fi
    curl --fail --silent --show-error --output /dev/null "https://${host}/"
    printf 'PASS reissuance (%s -> %s)\n' "$old_serial" "$new_serial"

# Generate a 32-character password and its cost-12 bcrypt hash.
password:
    @cd tools/password && go run .

# Remove the downloaded and extracted Kubeflow release.
clean-cache:
    rm -rf -- .cache
