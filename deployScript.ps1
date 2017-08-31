<#
 .SYNOPSIS
    Deploys a template to Azure

 .DESCRIPTION
    Deploys an Azure Resource Manager template

 .PARAMETER subscriptionId
    The subscription id where the template will be deployed.

 .PARAMETER resourceGroupName
    The resource group where the template will be deployed. Can be the name of an existing or a new resource group.

 .PARAMETER resourceGroupLocation
    Optional, a resource group location. If specified, will try to create a new resource group in this location. If not specified, assumes resource group is existing.

 .PARAMETER deploymentName
    The deployment name.

 .PARAMETER etheriumConsertiumTemplateFilePath
    Path to the template Etherium Consertium file. Defaults to template.json.

 .PARAMETER etheriumConsertiumParametersFilePath
    Optional, path to the Etherium Consertium parameters file. Defaults to parameters.json. If file is not found, will prompt for parameter values based on template.
#>

param(
 [Parameter(Mandatory=$True)]
 [string]
 $subscriptionId,

 [Parameter(Mandatory=$True)]
 [string]
 $resourceGroupName,

 [string]
 $resourceGroupLocation,

 [Parameter(Mandatory=$True)]
 [string]
 $deploymentName,

 [string]
 $etheriumConsertiumTemplateFilePath = "etheriumConsertiumTemplate.json",

 [string]
 $etheriumConsertiumParametersFilePath = "etheriumConsertiumParameters.json",
 
 [string]
 $supplyChainTemplateFilePath = "supplyChainTemplate.json",
 
 [string]
 $supplyChainParametersFilePath = "supplyChainParameters.json"
)


<#
.SYNOPSIS
    Registers RPs
#>
Function RegisterRP {
    Param(
        [string]$ResourceProviderNamespace
    )

    Write-Host "Registering resource provider '$ResourceProviderNamespace'";
    Register-AzureRmResourceProvider -ProviderNamespace $ResourceProviderNamespace;
}

#******************************************************************************
# Script body
# Execution begins here
#******************************************************************************
$ErrorActionPreference = "Stop"

# sign in
Write-Host "Logging in...";
Login-AzureRmAccount;

# select subscription
Write-Host "Selecting subscription '$subscriptionId'";
Select-AzureRmSubscription -SubscriptionID $subscriptionId;

# Register RPs
$resourceProviders = @("microsoft.compute","microsoft.network","microsoft.storage","microsoft.web");
if($resourceProviders.length) {
    Write-Host "Registering resource providers"
    foreach($resourceProvider in $resourceProviders) {
        RegisterRP($resourceProvider);
    }
}

#Create or check for existing resource group
$resourceGroup = Get-AzureRmResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
if(!$resourceGroup)
{
    Write-Host "Resource group '$resourceGroupName' does not exist. To create a new resource group, please enter a location.";
    if(!$resourceGroupLocation) {
        $resourceGroupLocation = Read-Host "resourceGroupLocation";
    }
    Write-Host "Creating resource group '$resourceGroupName' in location '$resourceGroupLocation'";
    New-AzureRmResourceGroup -Name $resourceGroupName -Location $resourceGroupLocation
}
else{
    Write-Host "Using existing resource group '$resourceGroupName'";
}

# Start the Etherium Consertium deployment
Write-Host "Starting Etherium deployment...";
if(Test-Path $etheriumConsertiumParametersFilePath) {
    $etheriumConsertiumOutput = New-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile $etheriumConsertiumTemplateFilePath -TemplateParameterFile $etheriumConsertiumParametersFilePath;
} else {
    $etheriumConsertiumOutput = New-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile $etheriumConsertiumTemplateFilePath;
}

$ethTxVmRpcEndpoint = $etheriumConsertiumOutput.Outputs.'ethereum-rpc-endpoint'.value;

#$ethVnetName = (az network vnet list -g $resourceGroupName --query "[].{name:name}" | ConvertFrom-Json).name;
$ethVnetName = (Get-AzureRmVirtualNetwork -ResourceGroupName $resourceGroupName).name;

Write-Host "ethVnetName = '$ethVnetName'";
Write-Host "ethTxVmRpcEndpoint = '$ethTxVmRpcEndpoint'";

$etheriumConsertiumParameters = Get-Content $etheriumConsertiumParametersFilePath -raw | ConvertFrom-Json;
$supplyChainParameters = Get-Content $supplyChainParametersFilePath -raw | ConvertFrom-Json;

$namePrefix = $etheriumConsertiumParameters.parameters.namePrefix.value;
$etheriumTxRpcPassword = $etheriumConsertiumParameters.parameters.ethereumAccountPsswd.value;
$supplyChainParameters.parameters.deploymentPreFix.value = $namePrefix;
$supplyChainParameters.parameters.ethVnetName.value = $ethVnetName;
$supplyChainParameters | ConvertTo-Json  | set-content $supplyChainParametersFilePath;

Start-Sleep -s 180

#Deploy the smart contract to the Etherium TX VM:
cd ..\ibera-smart-contracts
$deployCommand = "node deploy ProofOfProduceQuality $ethTxVmRpcEndpoint $etheriumTxRpcPassword"
$deployResult = Invoke-Expression "$deployCommand 2>&1" 
Write-Host $deployResult
cd '..\PS script\'

#Get the deployment result and extract the Account and Contract addresses in case of success or the Error string in case of failure:
$deployResultJson = ('{'+($deployResult -split '{')[-1] | ConvertFrom-Json)
$deploymentError = $deployResultJson.error;
if($deploymentError){
	Write-Host 'deploymentError= ' $deploymentError;
}else{
	$accountAddress = $deployResultJson.accountAddress;
	$contractAddress = $deployResultJson.contractAddress;
	Write-Host 'accountAddress= ' $accountAddress;
	Write-Host 'contractAddress= ' $contractAddress;
}

# Start the Supply Chain deployment
Try
{
	Write-Host "Starting Supply Chain deployment...";
	if(Test-Path $supplyChainParametersFilePath) {
		New-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile $supplyChainTemplateFilePath -TemplateParameterFile $supplyChainParametersFilePath;
	} else {
		New-AzureRmResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateFile $supplyChainTemplateFilePath;
	}
}
Catch
{
	Write-Host $_.Exception.Message
}

#Getting Services webapp endpoint:
$officeIntegrationWebappName = $namePrefix + $supplyChainParameters.parameters.sites_oi_name.value;
$servicesWebappName = $namePrefix + $supplyChainParameters.parameters.sites_services_api_name.value;
#$servicesWebappEndpoint = 'https://'+(az webapp show -g $resourceGroupName -n $servicesWebappName | ConvertFrom-Json).defaultHostName;
$servicesWebappEndpoint = 'https://'+(Get-AzureRmWebApp -Name $servicesWebappName -ResourceGroupName $resourceGroupName).DefaultHostName;

Write-Host "servicesWebappEndpoint = '$servicesWebappEndpoint'";

#Getting storage account connection string:
$storageName = $namePrefix + $supplyChainParameters.parameters.storageAccounts_service_name.value;
#$storageKey = (az storage account keys list -g $resourceGroupName -n $storageName | ConvertFrom-Json)[0].value;
$storageKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $storageName).Value[0];
$storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=' + $storageName + ';AccountKey=' + $storageKey + ';EndpointSuffix=core.windows.net';
Write-Host "storageConnectionString = '$storageConnectionString'";

#Setting Services webapp environment variables:
$servicesWebapp = Get-AzureRMWebAppSlot -ResourceGroupName $resourceGroupName -Name $servicesWebappName -Slot production
$servicesWebappSettingList = $servicesWebapp.SiteConfig.AppSettings

$servicesWebappHash = @{}
ForEach ($kvp in $servicesWebappSettingList) {
    $servicesWebappHash[$kvp.Name] = $kvp.Value
}
$servicesWebappHash['CONTRACT_ADDRESS'] = $contractAddress;
$servicesWebappHash['ACCOUNT_ADDRESS'] = $accountAddress;
$servicesWebappHash['ACCOUNT_PASSWORD'] = $etheriumTxRpcPassword;
$servicesWebappHash['GAS'] = '2000';
$servicesWebappHash['GET_RPC_ENDPOINT'] = $ethTxVmRpcEndpoint;
$servicesWebappHash['AZURE_STORAGE_CONNECTION_STRING'] = $storageConnectionString;

Set-AzureRMWebAppSlot -ResourceGroupName $resourceGroupName -Name $servicesWebappName -AppSettings $servicesWebappHash -Slot production


#Setting OfficeIntegration webapp environment variables:
$oiWebapp = Get-AzureRMWebAppSlot -ResourceGroupName $resourceGroupName -Name $officeIntegrationWebappName -Slot production
$oiWebappSettingList = $oiWebapp.SiteConfig.AppSettings

$oiWebappHash = @{}
ForEach ($kvp in $oiWebappSettingList) {
    $oiWebappHash[$kvp.Name] = $kvp.Value
}
$oiWebappHash['IBERA_SERVICES_ENDPOINT'] = $servicesWebappEndpoint;
$oiWebappHash['DOCUMENT_SERVICES_ENDPOINT'] = 'https://ibera-document-service.azurewebsites.net/api/Attachment';

Set-AzureRMWebAppSlot -ResourceGroupName $resourceGroupName -Name $officeIntegrationWebappName -AppSettings $oiWebappHash -Slot production
