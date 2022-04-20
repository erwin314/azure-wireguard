# Intro

This readme describes how to create a network in Azure with a WireGuard based gateway/router to an on premise corporate network. The gateway VM does not have any persistent disks, instead the WireGuard configuration file is downloaded from a Key Vault during the reimageing process. The VM will reimage itself every week, ensuring the usage of the latest linux image and packages. 

The following sections can be used to create all the parts needed.

These environment variables are required by the following script fragments:
```
ONPREM_IPS: contains the ips of the peer network (on premise).
AZURE_IPS: contains the ips of the virtual network (in Azure).
SUBNET_IPS: subnet within AZURE_IPS.
GATEWAY_IP: ip of the gateway vm within the SUBNET_IPS range.
```

Example:
```
RESOURCEGROUP="corp-infra"
ONPREM_IPS="10.19.76.0/22"
AZURE_IPS="10.19.80.0/20"
SUBNET_IPS="10.19.80.0/24"
GATEWAY_IP="10.19.80.4"
```


To check the default subscription used by the az cli run:
```
az account show 
```

If the default subscription is not correct, you can change it by running:
```
az account set --subscription "YOUR_SUBSCRIPT_NAME_HERE"
```

If the resource group does not exist you must create it:
```
az group create --name ${RESOURCEGROUP} --location "westeurope"
```

## Create Network, subnet and route

The azure virtual network wil be inside the range ${AZURE_IPS}. 
The main subnet wil be ${SUBNET_IPS}. 
We will need a route table and add a route to the onpremise corporate network using the Gateway VM (which will have ip ${GATEWAY_IP}):
```
az network route-table create -g ${RESOURCEGROUP} --name corp-routetable

az network route-table route create -g ${RESOURCEGROUP} \
--name corp-onprem \
--route-table-name corp-routetable \
--next-hop-type VirtualAppliance \
--address-prefix ${ONPREM_IPS} \
--next-hop-ip-address ${GATEWAY_IP}
```

Create the actual virtual network and the main subnet. We want to (optionally) use the Key Vault service from the main subnet, because the GatewayVM will need it. And the subnet should use the corp-routetable.
```
az network vnet create --resource-group ${RESOURCEGROUP} \
--name corp-azure-vnet \
--address-prefix ${AZURE_IPS}

az network vnet subnet create --resource-group ${RESOURCEGROUP} \
--name main \
--vnet-name corp-azure-vnet \
--address-prefixes ${SUBNET_IPS} \
--route-table corp-routetable \
--service-endpoints Microsoft.KeyVault
```


## Create Key Vault
The WireGuard config file containing the private key will be stored in a Key Vault. The name must be global unique, so we use a random string and set a tag to be able to find out which key vault is ours. We set the network acl to the subnet that will contain the gateway vm, but for now we will keep the firewall turned off (default Allow).
```
RANDOM="$(head /dev/urandom | tr -dc a-z0-9 | head -c10)"
az keyvault create --resource-group ${RESOURCEGROUP} \
--name "vmgateway01-${RANDOM}" \
--enable-rbac-authorization true \
--default-action Allow \
--network-acls "{\"vnet\":[\"corp-azure-vnet/main\"]}" \
--tags used_by_vmgateway01
```


Make sure the current user can manage the private key in the vault:
```
VAULTID=$(az keyvault list --resource-group ${RESOURCEGROUP} --query "[?tags.used_by_vmgateway01 == ''].id" -o tsv)
ME=$(az account show --query user.name -o tsv)
az role assignment create --scope "${VAULTID}" --assignee "${ME}" --role "Key Vault Administrator" 
```

Now you can set (or update) the WireGuard config file. The contents of the wg0.conf file depends on your infrastructure, see the [WireGuard config file docs](https://git.zx2c4.com/wireguard-tools/about/src/man/wg.8#CONFIGURATION%20FILE%20FORMAT) and [additional supported settings](https://git.zx2c4.com/wireguard-tools/about/src/man/wg-quick.8#CONFIGURATION) for more information. Tip: If you do not want to configure a fixed public IP for the VM, use the Persistent Keepalive setting to force an initial handshake when the VM starts.

Set or update the WireGuard config file:
```
VAULTNAME=$(az keyvault list --resource-group ${RESOURCEGROUP} --query "[?tags.used_by_vmgateway01 == ''].name" -o tsv)
az keyvault secret set --vault-name ${VAULTNAME} --name wg0conf --file wg0.conf
```

OPTIONAL: After the config file is set, we can enable the firewall to only allow the corp-azure-vnet/main subnet:
```
VAULTNAME=$(az keyvault list --resource-group ${RESOURCEGROUP} --query "[?tags.used_by_vmgateway01 == ''].name" -o tsv)
az keyvault update --name ${VAULTNAME} --default-action Deny
```


## Create Gateway VM

First we wil create the VM. The VM will immediatly start booting, which is unfortunate because the roles for the managed identity still need to be configured. The VM uses the [cloud-config.yml](cloud-config.yml) file to setup the machine as a WireGuard gateway/router. It also configures a cronjob to reimage the VM every week. This ensures the VM is automatically updated.

After the VM is created we can determine the managed identity and assign the correct roles. The VM may need to be reimaged if the roles are not assigned on time. The machine needs two roles on the vault. The "Reader" roll to find the vault id and the "Key Vault Secrets User" to read the wg0.conf file from the vault. The machine also needss a role on itself. The "Virtual Machine Contributer" role is needed to let the machine reimage itself.

```
az vm create \
--resource-group ${RESOURCEGROUP} \
--name vmgateway01 \
--image Canonical:UbuntuServer:18_04-lts-gen2:latest \
--size Standard_DS1_v2 \ 
--assign-identity [system] \
--ephemeral-os-disk true \
--ephemeral-os-disk-placement CacheDisk \
--custom-data cloud-config.yml \
--generate-ssh-keys \
--accelerated-networking true \
--vnet-name corp-azure-vnet \
--subnet main \
--private-ip-address ${GATEWAY_IP} \
--public-ip-sku Standard \
--nsg vmgateway01NSG \
--nsg-rule NONE 

VAULTID=$(az keyvault list --resource-group ${RESOURCEGROUP} --query "[?tags.used_by_vmgateway01 == ''].id" -o tsv)
VMIDENTITY=$(az vm get-instance-view --resource-group ${RESOURCEGROUP} --name vmgateway01 --query identity.principalId -o tsv)
az role assignment create --scope "${VAULTID}" --assignee "${VMIDENTITY}" --role "Reader" 
az role assignment create --scope "${VAULTID}" --assignee "${VMIDENTITY}" --role "Key Vault Secrets User" 

VMID=$(az vm get-instance-view --resource-group ${RESOURCEGROUP} --name vmgateway01 --query id -o tsv)
az role assignment create --scope "${VMID}" --assignee "${VMIDENTITY}" --role "Virtual Machine Contributor" 
```

## Confige the VM Network Card and Network Security Group.

The network card of the VM needs to allow IP forwarding to function as a gateway.
And we need to allow incoming UDP packets to the WireGuard port 51820. Otherwise the VPN connection can only be initiated from the inside of Azure.

```
NICID=$(az vm nic list --resource-group ${RESOURCEGROUP} --vm-name "vmgateway01" --query "[].{id:id}" --output tsv)
NICNAME=$(az vm nic show -g ${RESOURCEGROUP} --vm-name vmgateway01 --nic ${NICID} --query "{name:name}" --output tsv)
az network nic update -g ${RESOURCEGROUP} -n ${NICNAME} --ip-forwarding true

az network nsg rule create \
    --resource-group ${RESOURCEGROUP} \
    --nsg-name vmgateway01NSG \
    --name AllowWireGuardInbound \
    --protocol udp \
    --priority 100 \
    --destination-port-range 51820
```
