/*

RG=infra-test
az group create --name $RG --location westeurope
az deployment group create --resource-group $RG --template-file corp-infra.bicep 

*/


/* 
Select the range of the IP's allowed inside the Azure Virtual Network. Make sure it
is big enough to accomodate the number of ip's you need (now and in the future). 
*/
param AZURE_NET string = '10.10.64.0/20'


/*
Deploy a virtual appliance (gateway) into a different subnet than the resources that route 
through the virtual appliance are deployed in. Deploying the virtual appliance to the same subnet, 
then applying a route table to the subnet that routes traffic through the virtual appliance, 
can result in routing loops, where traffic never leaves the subnet.

AZURE_GW_SUBNET is the subnet where the virtual appliance will be deployed.
AZURE_VM_SUBNET is the subnet where the resources that route through the virtual appliance are deployed.
*/
param AZURE_GW_SUBNET string = '10.10.64.0/24'

param AZURE_VM_SUBNET string = '10.10.78.0/24'

/*
IP number of the virtual appliance.
Must be within the AZURE_SUBNET and the last digit must be 4 or higher.
*/
param GATEWAY_IP string = '10.10.64.4'

/*
List of networks on the on premise network that will be routed through the virtual appliance.
*/
param ONPREM_NET_LIST array = [
  '10.10.76.0/24'
  '10.10.77.0/24'
]

param AZURE_GW_SUBNET_NAME string = '${virtualMachineName}-subnet'
param AZURE_VM_SUBNET_NAME string = 'vm-subnet'

param location string = resourceGroup().location
param tenantId string = subscription().tenantId

param keyVaultName string = 'wg0-${uniqueString(resourceGroup().id)}'

param virtualMachineName string = 'vmgateway01'
param virtualMachineComputerName string = virtualMachineName
param virtualMachineSize string = 'Standard_DS1_v2'
param ephemeralDiskType string = 'CacheDisk'

param adminUsername string = 'azureuser'

param publicIpAddressName string = '${virtualMachineName}-ip'
param enableAcceleratedNetworking bool = true
param networkSecurityGroupName string = '${virtualMachineName}-nsg'
param publicIpAddressType string = 'Static' // Static or Dynamic
param publicIpAddressSku string = 'Basic' // Basic or Standard
param nicDeleteOption string = 'Detach'

param networkSecurityGroupRules array = [ 
  {
    name: 'AllowWireGuardInBound'
    properties: {
        priority: 300
        protocol: 'UDP'
        access: 'Allow'
        direction: 'Inbound'
        sourceAddressPrefix: '*'
        sourcePortRange: '*'
        destinationAddressPrefix: '*'
        destinationPortRange: '51820'
    }
  }
]

var vnetId = virtualNetwork.id
var gatewaySubnetId = '${vnetId}/subnets/${AZURE_GW_SUBNET_NAME}'

var cloudInit_base64 = loadFileAsBase64('cloud-config.yml')
var ssh_pub_key = loadTextContent('id_rsa.pub')
var wg0_config = loadTextContent('wg0.conf')


///////// References to built in roles //////////
@description('This is the built-in Key Vault Administrator role. See https://docs.microsoft.com/azure/role-based-access-control/built-in-roles')
resource keyVaultAdministratorRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: '00482a5a-887f-4fb3-b363-3b7fe8e74483'
}
resource keyVaultSecretsUserRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: '4633458b-17de-408a-b874-0445c86b69e6'
}
resource readerRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
}
resource virtualMachineContributerRoleDefinition 'Microsoft.Authorization/roleDefinitions@2018-01-01-preview' existing = {
  scope: subscription()
  name: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
}
/////////////////////////////////////////////////


// --- Identity for the VM and the Role Assignments ---

resource vmIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' = {
  name: '${virtualMachineName}-identity'
  location: location
}

resource keyVaultSecretsUserRole 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  name: guid(subscription().id, keyVault.id, vmIdentity.id, keyVaultSecretsUserRoleDefinition.id)
  scope: keyVault
  properties: {
    principalId: vmIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleDefinition.id
  }
}

resource keyVaultReaderRole 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  name: guid(subscription().id, keyVault.id, vmIdentity.id, readerRoleDefinition.id)
  scope: keyVault
  properties: {
    principalId: vmIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRoleDefinition.id
  }
}

resource vmContributerRole 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  name: guid(subscription().id, virtualMachine.id, vmIdentity.id, virtualMachineContributerRoleDefinition.id)
  scope: virtualMachine
  properties: {
    principalId: vmIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: virtualMachineContributerRoleDefinition.id
  }
}

///////////


resource routeTableWireGuard 'Microsoft.Network/routeTables@2019-11-01' = {
  name: '${virtualMachineName}-routetable'
  location: location
  properties: {
    routes: [for ONPREM_NET in ONPREM_NET_LIST: {
        name: replace(replace('WireGuard_${ONPREM_NET}','.','_'),'/','m')
        properties: {
          addressPrefix: ONPREM_NET
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: GATEWAY_IP
        }
    }]
    disableBgpRoutePropagation: true
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2019-11-01' = {
  name: 'corp-azure-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        AZURE_NET
      ]
    }
    subnets: [
      {
        name: AZURE_GW_SUBNET_NAME
        properties: {
          addressPrefix: AZURE_GW_SUBNET
          serviceEndpoints: [
            {
              service: 'Microsoft.KeyVault'             
            }
          ]
        }

      }
      {
        name: AZURE_VM_SUBNET_NAME
        properties: {
          addressPrefix: AZURE_VM_SUBNET
          routeTable: {
            id: routeTableWireGuard.id
          }
        }
      }
    ]
  }  
}

resource keyVault 'Microsoft.KeyVault/vaults@2021-10-01' = {
  name: keyVaultName 
  location: location
  properties: {
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
    enableRbacAuthorization: true
    tenantId: tenantId
    sku: {
      name: 'standard'
      family: 'A'
    }

    // Only allow access to the key vault from the gateway subnet
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: [
        {
          id: gatewaySubnetId
        }
      ]
    }
  }

  // Upload the wg0.conf file to this Key Vault
  resource wg0 'secrets' = {
    name: 'wg0conf'
    properties: {
      value: wg0_config
    }
  }

}

resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2019-02-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules: networkSecurityGroupRules
  }
}

resource publicIpAddress 'Microsoft.Network/publicIpAddresses@2020-08-01' = {
  name: publicIpAddressName
  location: location
  properties: {
    publicIPAllocationMethod: publicIpAddressType
  }
  sku: {
    name: publicIpAddressSku
  }
}

resource networkInterface 'Microsoft.Network/networkInterfaces@2021-03-01' = {
  name: '${virtualMachineName}-nic'
  location: location
  properties: {
    enableIPForwarding: true
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: gatewaySubnetId
          }
          
          privateIPAllocationMethod: 'Static'
          privateIPAddress: GATEWAY_IP
          publicIPAddress: {
            id: publicIpAddress.id
            properties: {
              deleteOption: 'Detach'
            }
          }
        }
      }
    ]
    enableAcceleratedNetworking: enableAcceleratedNetworking
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
  }
}


resource virtualMachine 'Microsoft.Compute/virtualMachines@2021-07-01' = {
  name: virtualMachineName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: virtualMachineSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
        caching: 'ReadOnly'
        diffDiskSettings: {
          option: 'Local'
          placement: ephemeralDiskType
        }
        deleteOption: 'Delete'
      }
      imageReference: {
        publisher: 'canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'        

        // publisher: 'canonical'
        // offer: '0001-com-ubuntu-server-focal'
        // sku: '20_04-lts-gen2'
        // version: 'latest'
        
        // publisher: 'Canonical'
        // offer: 'UbuntuServer'
        // sku: '18_04-lts-gen2'
        // version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            deleteOption: nicDeleteOption
          }
        }
      ]
    }
    osProfile: {
      computerName: virtualMachineComputerName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh:  {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: ssh_pub_key
            }
          ]
        }
      }
      customData: cloudInit_base64
    }

    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }

  // We use a UserAssigned identity so we can configure the roles before starting the VM.
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${vmIdentity.id}': { }
    }
  }

  // During boot the cloud-config script will need access to the Key Vault.
  dependsOn: [
    keyVaultSecretsUserRole
    keyVaultReaderRole
  ]  
}



