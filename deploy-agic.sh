az account set -s $subscriptionId && az account show
az aks list -o table

# DYNAMIC VARIABLES AKS (only work with a single or the first cluster in the subscription)
####################################################################################
resourceGroup=$(az aks list --query [0].resourceGroup -o tsv)
clusterName=$(az aks list --query [0].name -o tsv)
apiServerAddress=$(az aks show --resource-group $resourceGroup --name $clusterName --query fqdn -o tsv)
appGWid=$(az network application-gateway list --query [0].id -o tsv)
appGWName=$(az network application-gateway list --query [0].name -o tsv)
appGWResourceGroupID=$(az group show --name $resourceGroup --query id -o tsv)
nodeResourceGroup=$(az aks show --resource-group $resourceGroup --name $clusterName --query nodeResourceGroup -o tsv)
spn=$(az aks show -g $resourceGroup -n $clusterName --query servicePrincipalProfile.clientId -o tsv)

# add cluster to kube context
az aks get-credentials --resource-group $resourceGroup --name $clusterName --admin --overwrite-existing 
kubectl config get-contexts

# DYNAMIC VARIABLES KUBERNETES
####################################################################################
namespace="${afdeling}-${applicatie}-${env}"
folder="manifests-${afdeling}"

echo "namespace: " $namespace
echo "folder: " $folder

# CREATE MANIFEST FOLDER
####################################################################################
mkdir $folder

# CREATE NAMESPACE
####################################################################################
cat <<EOF > ./$folder/namespace-$namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    bo: $bo
    afdeling: $afdeling
    applicatie: $applicatie
    dev: $dev
    ops: $ops
EOF

kubectl apply -f ./$folder/namespace-$namespace.yaml

####################################################################################
####################################################################################

# add AGIC helm package
helm repo add application-gateway-kubernetes-ingress https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
helm repo update

# Get/Create AAD Identity for pod
####################################################################################
aadAksIdentityReader=$(az identity list --resource-group $resourceGroup --query [].name -o tsv)
if [ -z "$aadAksIdentityReader" ]
then
      az identity create -g $resourceGroup -n $aadAksIdentity -o json
      aadAksIdentity=$(az identity list --resource-group $resourceGroup --query [].name -o tsv)
      echo "$aadAksIdentity is created"
else
      aadAksIdentity=$(az identity list --resource-group $resourceGroup --query [].name -o tsv)
      echo "$aadAksIdentity already provisioned during deployment"
fi

# Set variables from identity output (show)
identityResourceID=$(az identity show --resource-group $resourceGroup --name $aadAksIdentity --query id -o tsv)
identityClientID=$(az identity show --resource-group $resourceGroup --name $aadAksIdentity --query clientId -o tsv)

# run this command to create the aad-pod-identity deployment on an RBAC-enabled cluster
# It is required to deploy NMI and MIC into the default namespace
kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment-rbac.yaml
# a copy of the deployment-rbac.yaml manifest is in the project folder aks-extension

# create Azure identity manifest files in the manifest directory
mkdir ./manifest

cat <<EOF > ./manifest/aadpodidentity.yaml
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentity
metadata:
  name: topaas-aks-identity
spec:
  type: 0
  ResourceID: $identityResourceID
  ClientID: $identityClientID
EOF

kubectl apply -f ./manifest/aadpodidentity.yaml

cat <<EOF > ./manifest/aadpodidentitybinding.yaml
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentityBinding
metadata:
  name: topaas-aks-identity-binding
spec:
  AzureIdentity: topaas-aks-identity
  Selector: $selector
EOF

kubectl apply -f ./manifest/aadpodidentitybinding.yaml

# Set Permissions for MIC
az role assignment create --role "Managed Identity Operator" --assignee $spn --scope $identityResourceID

# Create an Azure identity and give it permissions ARM
####################################################################################

az identity create -g $nodeResourceGroup -n $armAksIdentity
armIdentityResourceID=$(az identity show --resource-group $nodeResourceGroup --name $armAksIdentity --query id -o tsv)
armIdentityClientID=$(az identity show --resource-group $nodeResourceGroup --name $armAksIdentity --query clientId -o tsv)

echo 'waiting...'
sleep 30

az role assignment create --role 'Contributor' --assignee $armIdentityClientID --scope $appGWid
az role assignment create --role 'Reader' --assignee $armIdentityClientID --scope $appGWResourceGroupID

# DEPLOY AGIC - PUBLIC INGRESS CONTROLLER
####################################################################################

# deploy and configure ingress controller with helm chart
cat <<EOF > ./manifest/helm-config.yaml
# This file contains the essential configs for the ingress controller helm chart

# Verbosity level of the App Gateway Ingress Controller
verbosityLevel: 3

################################################################################
# Specify which application gateway the ingress controller will manage
#
appgw:
    subscriptionId: $subscriptionId
    resourceGroup: $resourceGroup
    name: $appGWName
    usePrivateIP: false

    # Setting appgw.shared to "true" will create an AzureIngressProhibitedTarget CRD.
    # This prohibits AGIC from applying config for any host/path.
    # Use "kubectl get AzureIngressProhibitedTargets" to view and change this.
    shared: false

################################################################################
# Specify which kubernetes namespace the ingress controller will watch
# Default value is "default"
# Leaving this variable out or setting it to blank or empty string would
# result in Ingress Controller observing all acessible namespaces.
#
# kubernetes:
#   watchNamespace: <namespace>

################################################################################
# Specify the authentication with Azure Resource Manager
#
# Two authentication methods are available:
# - Option 1: AAD-Pod-Identity (https://github.com/Azure/aad-pod-identity)
armAuth:
    type: aadPodIdentity
    identityResourceID: $armIdentityResourceID
    identityClientID:  $armIdentityClientID

## Alternatively you can use Service Principal credentials
# armAuth:
#    type: servicePrincipal
#    secretJSON: <<Generate this value with: "az ad sp create-for-rbac --subscription <subscription-uuid> --sdk-auth | base64 -w0" >>

################################################################################
# Specify if the cluster is RBAC enabled or not
rbac:
    enabled: true

# Specify aks cluster related information. THIS IS BEING DEPRECATED.
aksClusterConfiguration:
    apiServerAddress: $apiServerAddress
EOF

helm install ingress-azure -f ./manifest/helm-config.yaml application-gateway-kubernetes-ingress/ingress-azure --namespace $namespace --version '1.2.0-rc1'

####################################################################################
####################################################################################
