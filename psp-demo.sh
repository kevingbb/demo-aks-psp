#!/bin/bash

# Setup alias becuase I am lazy when it comes to typing.
alias k=kubectl

# Regsiter Provider
az feature register --name PodSecurityPolicyPreview --namespace Microsoft.ContainerService
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/PodSecurityPolicyPreview')].{Name:name,State:properties.state}"
az provider register --namespace Microsoft.ContainerService
az provider show -n Microsoft.ContainerService -o json --query "registrationState"

# Create Resource Group.
PREFIX="psp"
RG="${PREFIX}-rg"
LOC="eastus"
NAME="${PREFIX}20190328"

#*****************************
# Put $NAME in parameters.json File
#*****************************

# Create Resource Group
az group create --name $RG --location $LOC

# Create SP and Assign Permission to Virtual Network
az ad sp create-for-rbac -n "${PREFIX}sp" --skip-assignment
# Assign Permission to Virtual Network
APPID="???"
PASSWORD="???"

# Create AKS Cluster
az group deployment create -n $NAME -g $RG \
  --template-file template.json \
  --parameters '@parameters.json' \
  --no-wait
# Get Deployment Details
az group deployment list -g $RG -o tsv --query '[].properties.outputResources[0].id'

# Version and Upgrade Info
az aks get-versions -l $LOC -o table
# List the new Cluster & Registry
az aks list -o table
# Get AKS Credentials so kubectl works
az aks get-credentials -g $RG -n $NAME --admin
az aks get-credentials -g $RG -n $NAME
az aks get-credentials -g $RG -n $NAME --debug 2> debugoutput.txt
# Get Nodes
k get nodes -o wide
# Version and Upgrade Info
az aks get-upgrades -g $RG -n $NAME --output table

# Test Privileged Pod
k apply -f nginx-privileged.yaml
# Exec into Pod and Check Traffic
k get po -o wide
k exec -it nginx-privileged -- /bin/bash
ls -al /proc
exit
# Remove the Pod
k delete -f nginx-privileged.yaml

# Setup Resources for PSP
k create namespace psp-test
k create serviceaccount -n psp-test nonadmin-user
k create rolebinding -n psp-test psp-test-editor --clusterrole=edit --serviceaccount=psp-test:nonadmin-user
alias kubectl-admin='kubectl -n psp-test'
alias kubectl-nonadminuser='kubectl --as=system:serviceaccount:psp-test:nonadmin-user -n psp-test'
# Get PSP Defaults and Roles
kubectl-admin get psp
kubectl-admin get clusterroles | grep psp
kubectl-admin describe clusterrole psp:privileged
kubectl-admin get clusterrole psp:privileged -o yaml
kubectl-admin describe clusterrole psp:restricted
kubectl-admin get clusterrole psp:restricted -o yaml
kubectl-admin get clusterrolebindings | grep restricted
kubectl-admin get clusterrolebindings default:restricted -o yaml
# Check Access
kubectl-nonadminuser auth can-i use podsecuritypolicy/psp-deny-privileged
kubectl-admin auth can-i use podsecuritypolicy/psp-deny-privileged
# Try Privileged Pod Creation Again as Non-Admin User (Should Fail)
kubectl-nonadminuser apply -f nginx-privileged.yaml
# Try Unprivileged Pod Creation Again (Will Fail)
kubectl-nonadminuser apply -f nginx-unprivileged.yaml
kubectl-nonadminuser get po
kubectl-nonadminuser describe po nginx-unprivileged
kubectl-nonadminuser delete -f nginx-unprivileged.yaml
# Try Unprivileged, but with non-root User (Will Succeed, but Startup Failure)
kubectl-nonadminuser apply -f nginx-unprivileged-nonroot.yaml
kubectl-nonadminuser get po
kubectl-nonadminuser describe po nginx-unprivileged-nonroot
kubectl-nonadminuser logs nginx-unprivileged-nonroot --previous
kubectl-nonadminuser delete -f nginx-unprivileged-nonroot.yaml
# Try Unprivileged Ubuntu Pod, but with non-root User (Will Succeed)
kubectl-nonadminuser apply -f ubuntu-unprivileged-nonroot.yaml
kubectl-nonadminuser get po
kubectl-nonadminuser describe po security-context-ubuntu
kubectl-nonadminuser exec -it security-context-ubuntu -- /bin/bash
whoami
ps aux
touch test.log
apt-get update
apt-get install openssh-client -y
sudo -i
su -
exit
kubectl-nonadminuser delete -f ubuntu-unprivileged-nonroot.yaml

# Apply PSP
kubectl-admin get psp
kubectl-admin apply -f psp-deny-privileged.yaml
kubectl-admin delete -f psp-deny-privileged.yaml
kubectl-admin get psp
# Allow User Account to use PSP
# Create Role
kubectl-admin apply -f psp-deny-privileged-clusterrole.yaml
kubectl-admin delete -f psp-deny-privileged-clusterrole.yaml
# Create RoleBinding
kubectl-admin apply -f psp-deny-privileged-clusterrolebinding.yaml
kubectl-admin delete -f psp-deny-privileged-clusterrolebinding.yaml
# Check Permissions Again
kubectl-nonadminuser auth can-i use podsecuritypolicy/psp-deny-privileged
kubectl-admin auth can-i use podsecuritypolicy/psp-deny-privileged
# Try Privileged Pod Creation Again (Should Fail)
kubectl-nonadminuser apply -f nginx-privileged.yaml
# Try Unprivileged Pod Creation Again (Should Work)
kubectl-nonadminuser apply -f nginx-unprivileged.yaml
kubectl-admin get po
kubectl-nonadminuser delete -f nginx-unprivileged.yaml

# Helm Setup
# Check Helm Setup/Config
helm version
kubectl-admin apply -f tiller-rbacsetup.yaml
kubectl-admin delete -f tiller-rbacsetup.yaml
helm init --service-account=tiller --tiller-namespace psp-test --upgrade
kubectl-admin get po
kubectl-admin describe po $(kubectl-admin get po -l name=tiller -o jsonpath='{.items[0].metadata.name}')
kubectl-admin delete deployment.apps/tiller-deploy
# Grant Tiller Service Account Correct Permissions
kubectl-admin apply -f tiller-clusterrolebinding.yaml
# Try Again
helm init --service-account=tiller --tiller-namespace psp-test --upgrade
kubectl-admin get po
helm version --tiller-namespace psp-test
# Test Helm
helm list --tiller-namespace psp-test
helm repo update
helm install stable/mongodb --tiller-namespace psp-test
helm install stable/mongodb --tiller-namespace psp-test --namespace psp-test
kubectl-admin get po
helm list --tiller-namespace psp-test

# Cleanup
kubectl-admin delete -f psp-deny-privileged-clusterrolebinding.yaml
kubectl-admin delete -f psp-deny-privileged-clusterrole.yaml
kubectl-admin delete -f psp-deny-privileged.yaml
kubectl-admin delete namespace psp-test

# Add PSP to existing AKS Cluster
az aks update-cluster \
    --resource-group $RG \
    --name $NAME \
    --enable-pod-security-policy

# Cleanup
# Cleanup K8s Contexts
k config delete-context $NAME
k config delete-context "${NAME}-admin"
k config delete-cluster $NAME
k config unset "users.clusterUser_${RG}_${NAME}"
k config unset "users.clusterAdmin_${RG}_${NAME}"
k config view
# Delete RG
az group delete --name $RG --no-wait -y