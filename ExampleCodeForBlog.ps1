#region Login

Add-AzureRmAccount
$Subscription = 'SubscriptionName'
$Sub = Get-AzureRmSubscription -SubscriptionName $Subscription
Set-AzureRmContext -SubscriptionName $Sub.Name

#endregion

#region GetAutomationAccount

$AutoResGrp = Get-AzureRmResourceGroup -Name 'AutomationAccountName'
$AutoAcct = Get-AzureRmAutomationAccount -ResourceGroupName $AutoResGrp.ResourceGroupName

#endregion

#region Keyvault Credential

$KeyVault = Get-AzureRmKeyVault -ResourceGroupName $AutoAcct.ResourceGroupName -VaultName 'VaultName'

#endregion

#region compress configurations

    Set-Location C:\Scripts\Presentations\AzureDSCCompositeTest
    $Modules = Get-ChildItem -Directory
    
    ForEach ($Mod in $Modules){

        Compress-Archive -Path $Mod.PSPath -DestinationPath ((Get-Location).Path + '\' + $Mod.Name + '.zip') -Force

    }


#endregion

#region Access blob container

$StorAcct = Get-AzureRmStorageAccount -ResourceGroupName $AutoAcct.ResourceGroupName

Add-AzureAccount
$AzureSubscription = ((Get-AzureSubscription).where({$PSItem.SubscriptionName -eq $Sub.Name})) 
Select-AzureSubscription -SubscriptionName $AzureSubscription.SubscriptionName -Current
$StorKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $StorAcct.ResourceGroupName -Name $StorAcct.StorageAccountName).where({$PSItem.KeyName -eq 'key1'})
$StorContext = New-AzureStorageContext -StorageAccountName $StorAcct.StorageAccountName -StorageAccountKey $StorKey.Value
$Container = Get-AzureStorageContainer -Name ('ContainerName') -Context $StorContext


#endregion

#region upload zip files

$ModulesToUpload = Get-ChildItem -Filter "*.zip"

ForEach ($Mod in $ModulesToUpload){

        $Blob = Set-AzureStorageBlobContent -Context $StorContext -Container $Container.Name -File $Mod.FullName -Force
        
        New-AzureRmAutomationModule -ResourceGroupName $AutoAcct.ResourceGroupName -AutomationAccountName $AutoAcct.AutomationAccountName -Name ($Mod.Name).Replace('.zip','') -ContentLink $Blob.ICloudBlob.Uri.AbsoluteUri

}


#endregion

#region Import Composite Configuration

#***NOTE*** - Configuration Name must match Configuration Script Name
#***NOTE*** (Get-Item .\Configuration.ps1).FullName must be used or will get Invalid argument specified error.
$Config = Import-AzureRmAutomationDscConfiguration -SourcePath (Get-Item C:\Scripts\Presentations\AzureDSCCompositeTest\CompositeConfig.ps1).FullName -AutomationAccountName $AutoAcct.AutomationAccountName -ResourceGroupName $AutoAcct.ResourceGroupName -Description DemoConfiguration -Published -Force

#endregion

#region Compile Configuration
$Parameters = @{
    
            'DomainName' = 'domain.local'
            'ResourceGroupName' = $AutoAcct.ResourceGroupName
            'AutomationAccountName' = $AutoAcct.AutomationAccountName
            'AdminName' = ''
}

$ConfigData = 
@{
    AllNodes = 
    @(
        @{
            NodeName = "*"
            PSDscAllowPlainTextPassword = $true
        },


        @{
            NodeName     = "webServer"
            Role         = "WebServer"
        }
        
        @{
            NodeName = "domainController"
            Role = "domaincontroller"
        }

        @{
            NodeName = 'sqlServer'
            Role = 'sqlServer'
        }

        @{
            NodeName = 'licenseServer'
            Role = 'licenseServer'
        }

    )
}


$DSCComp = Start-AzureRmAutomationDscCompilationJob -AutomationAccountName $AutoAcct.AutomationAccountName -ConfigurationName $Config.Name -ConfigurationData $ConfigData -Parameters $Parameters -ResourceGroupName $AutoAcct.ResourceGroupName

Get-AzureRmAutomationDscCompilationJob -Id $DSCComp.Id -ResourceGroupName $AutoAcct.ResourceGroupName -AutomationAccountName $AutoAcct.AutomationAccountName

#endregion

#region Register EndPoint

$TargetResGroup = 'targetVMResGroup'
$VMName = 'vmName'

$VM = Get-AzureRmVM -ResourceGroupName $TargetResGroup -Name $VMName

$DSCLCMConfig = @{

    'ConfigurationMode' = 'ApplyAndAutocorrect'
    'RebootNodeIfNeeded' = $true
    'ActionAfterReboot' = 'ContinueConfiguration'

}

Register-AzureRmAutomationDscNode -AzureVMName $VM.Name -AzureVMResourceGroup $VM.ResourceGroupName -AzureVMLocation $VM.Location -AutomationAccountName $AutoAcct.AutomationAccountName -ResourceGroupName $AutoAcct.ResourceGroupName @DSCLCMConfig


#endregion

#region GetDesiredConfig

    #Be careful not to confuse Get-AzureRmAutomationDSCConfiguration with NodeConfiguration

$Configuration = Get-AzureRmAutomationDscNodeConfiguration -AutomationAccountName $AutoAcct.AutomationAccountName -ResourceGroupName $AutoAcct.ResourceGroupName -Name 'CompositeConfig.domainController'

#endregion


#region Apply Configuration

$TargetNode = Get-AzureRmAutomationDscNode -Name $VM.Name -ResourceGroupName $AutoAcct.ResourceGroupName -AutomationAccountName $AutoAcct.AutomationAccountName
Set-AzureRmAutomationDscNode -Id $TargetNode.Id -NodeConfigurationName $Configuration.Name -AutomationAccountName $AutoAcct.AutomationAccountName -ResourceGroupName $AutoAcct.ResourceGroupName -Verbose -Force

#endregion

#region Gotchas

    #Some of the DSC Resources in the gallery will not register properly because of how the directory structure is formatted.
        #Show xPendingReboot 0.3.0.0 directory structure.

    #If you register a Node with the configuration applied in the same command, it can fail (Last tested as of August 17 2017)

#endregion