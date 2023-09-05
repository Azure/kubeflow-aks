param nameseed string = 'kubeflow'
param location string = resourceGroup().location
param signedinuser string

//---------Kubernetes Construction---------
module aksconst './AKS-Construction/bicep/main.bicep' = {
  name: 'aksconstruction'
  params: {
    location: location
    resourceName: nameseed
    enable_aad: true
    kubernetesVersion: '1.26.6'
    enableAzureRBAC: true
    registries_sku: 'Standard'
    omsagent: true
    retentionInDays: 30
    agentCount: 4
    agentVMSize: 'Standard_D2ds_v4'
    osDiskType: 'Managed'
    AksPaidSkuForSLA: true
    networkPolicy: 'azure'
    azurepolicy: 'audit'
    acrPushRolePrincipalId: signedinuser
    adminPrincipalId: signedinuser
    AksDisableLocalAccounts: true
    custom_vnet: true
    upgradeChannel: 'stable'

    //Workload Identity requires OidcIssuer to be configured on AKS
    // oidcIssuer: true

    //We'll also enable the CSI driver for Key Vault
    keyVaultAksCSI: true
  }
}
output aksOidcIssuerUrl string = aksconst.outputs.aksOidcIssuerUrl
output aksClusterName string = aksconst.outputs.aksClusterName

// deploy keyvault
module keyVault './AKS-Construction/bicep/keyvault.bicep' = {
  name: 'kv${nameseed}'
  params: {
    resourceName: 'app${nameseed}'
    keyVaultPurgeProtection: false
    keyVaultSoftDelete: false
    location: location
    privateLinks: false
  }
}
output kvAppName string = keyVault.outputs.keyVaultName

resource kubeflowidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2022-01-31-preview' = {
  name: 'kubeflow'
  location: location

  // resource fedCreds 'federatedIdentityCredentials' = {
  //   name: nameseed
  //   properties: {
  //     audiences: aksconst.outputs.aksOidcFedIdentityProperties.audiences
  //     issuer: aksconst.outputs.aksOidcFedIdentityProperties.issuer
  //     subject: 'system:serviceaccount:superapp:serversa'
  //   }
  // }
}
output kubeflowidentityClientId string = kubeflowidentity.properties.clientId
output kubeflowidentityId string = kubeflowidentity.id

module kvSuperappRbac './KVRBAC.bicep' = {
  name: 'kubeflowKvRbac'
  params: {
    appclientId: kubeflowidentity.properties.principalId
    kvName: keyVault.outputs.keyVaultName
  }
}
