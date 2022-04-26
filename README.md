# Intro

This readme describes how to create a network in Azure with a WireGuard based gateway/router to an on premise corporate network. The gateway VM does not have any persistent disks, instead the WireGuard configuration file is downloaded from a Key Vault during the reimageing process. The VM will reimage itself every week, ensuring the usage of the latest linux image and packages. Effectively this is a form of automatic updating. There is no need to login to the server, so all TCP ports are closed (even SSH). Only WireGuard UDP port 51820 is open, to allow incoming WireGuard connection(s).

Prerequisites you will need to provide yourself:
- id_rsa.pub file containing your public ssh key (required for creation of the VM).
- wg0.conf file containing the wireguard config (as used by the VM).

The WireGuard config file containing the private key will be stored in a Key Vault. The network acl is set to the subnet that will contain the gateway vm. So only the VM can access the vault.


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
RESOURCEGROUP=infra-test
az group create --name ${RESOURCEGROUP} --location "westeurope"
```

Now create the virtual network with the WireGuard gateway. See the azure-wireguard.bicep for all parameters. 
For a basic test deploy run:
```
az deployment group create --resource-group ${RESOURCEGROUP} --template-file azure-wireguard.bicep 
```
