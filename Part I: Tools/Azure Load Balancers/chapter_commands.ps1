$projectName = 'NoBSAzureLb'

$resourceGroupName = $projectName
$location = 'eastus'

## We're putting everything in the same resource group. No need to include the resource group for all commands
az configure --defaults "resource-group=$resourceGroupName"

#region Create the resource group
az group create --name $resourceGroupName --location $location
#endregion

#region Create the public IP
$pipName = "$projectName-pip"

## Must capture this to provide to the Load balancer frontend IP configuration later
$pubIp = az network public-ip create --name $pipName --allocation-method Static | ConvertFrom-Json
#endregion

#region Create the vNet and subnet
$vNetName = "$projectName-vNet"
az network vnet create --name $vNetName --address-prefixes '10.0.0.0/16'
 
## subnet
$subNetName = "$projectName-Subnet"
az network vnet subnet create --address-prefixes '10.0.0.0/24' --name $subNetName --vnet-name $vNetName

## Create the NSG and rules
$nsgName = "$projectName-Nsg"
az network nsg create --name $nsgName

az network nsg rule create --nsg-name $nsgName --name "$nsgName-RuleHTTP" `
    --protocol tcp --direction inbound --priority 1001 --source-address-prefix '*' --source-port-range '*' `
    --destination-address-prefix '*' --destination-port-range 80 --access allow --priority 2000

#endregion

#region Create the load balancer
$lbName = "$projectName-Lb"
$lbFeIp = "$projectName-LbFeIp"
$lbAddrPool = "$projectName-AddrPool"
az network lb create `
    --name $lbName `
    --public-ip-address $pipName `
    --sku Basic `
    --frontend-ip-name $lbFeIp `
    --backend-pool-name $lbAddrPool
#endregion

#region Create the health probe

## Not using the http health probe because it only is allowed for the Standard SKU
$lbProbeName = "$lbName-HealthProbe"
az network lb probe create --lb-name $lbName --name $lbProbeName --port 80 --protocol http --path /
#endregion

#region Creates an LB rule for port 80.
az network lb rule create `
    --lb-name $lbName `
    --name "$lbName-RuleWeb" `
    --protocol tcp `
    --frontend-port 80 `
    --backend-port 80 `
    --frontend-ip-name $lbFeIp `
    --backend-pool-name $lbAddrPool `
    --probe-name $lbProbeName
#endregion

#region Create the VM avaialability set
$availabilitySetName = "$projectName-VmAvailSet"
az vm availability-set create --name $availabilitySetName
#endregion

#region Create the VMs to place into the availability set

0..2 | ForEach-Object {
    $vmName = "$projectName-$_"
    $nicName = "$vmName-Nic"
    
    ## Create the VM's NIC
    az network nic create `
        --name $nicName `
        --vnet-name $vNetName --subnet $subNetName `
        --network-security-group $nsgName --lb-name $lbName `
        --lb-address-pools $lbAddrPool

    ## Create the VM
    az vm create `
        --name $vmName `
        --availability-set $availabilitySetName `
        --image MicrosoftWindowsServer:WindowsServer:2019-Datacenter:latest `
        --nics $nicName `
        --size 'Standard_DS1_v2' `
        --admin-password 'I like azure.' `
        --admin-username 'NoBS'

    ## Install the custom script extension on the VMs and install IIS
    az vm extension set `
        --vm-name $vmName --name customScript `
        --publisher Microsoft.Azure.Extensions `
        --protected-settings ./script-config.json
}
#endregion

#region Monitor the VM creation
while (az deployment group list --query "[?properties.provisioningState=='Running'].name" | ConvertFrom-Json) {
    Write-Host 'Still waiting on all resource deployments to finish...'
    Start-Sleep -Seconds 5
}

#endregion

#endregion

#region Cleaning up
az group delete --yes --no-wait
#endregion