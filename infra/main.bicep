// Azure resources for the Remote WiFi Performance Tool.
// Deploy:  az deployment group create -g <rg> -f main.bicep -p adminPassword=<pw>
// Tear down: delete the resource group.
// Everything targets free / low tiers (MSc budget).

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Prefix for resource names.')
param prefix string = 'comp702'

@description('PostgreSQL admin password.')
@secure()
param adminPassword string

// --- Storage (Blob) for raw payloads ---
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${prefix}stg${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

// --- PostgreSQL Flexible Server (enable TimescaleDB extension post-deploy) ---
resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name: '${prefix}-pg'
  location: location
  sku: { name: 'Standard_B1ms', tier: 'Burstable' }
  properties: {
    version: '16'
    administratorLogin: 'wifi'
    administratorLoginPassword: adminPassword
    storage: { storageSizeGB: 32 }
  }
}

// --- App Service plan shared by backend + cloud reference endpoint ---
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${prefix}-plan'
  location: location
  sku: { name: 'B1', tier: 'Basic' }
  kind: 'linux'
  properties: { reserved: true }
}

// --- FastAPI backend ---
resource api 'Microsoft.Web/sites@2023-12-01' = {
  name: '${prefix}-api'
  location: location
  properties: {
    serverFarmId: plan.id
    siteConfig: { linuxFxVersion: 'PYTHON|3.11' }
  }
}

// --- Cloud reference endpoint (same nginx image as the local server) ---
resource ref 'Microsoft.Web/sites@2023-12-01' = {
  name: '${prefix}-ref'
  location: location
  properties: {
    serverFarmId: plan.id
    siteConfig: { linuxFxVersion: 'DOCKER|wifi-ref:latest' }
  }
}

output apiHostname string = api.properties.defaultHostName
output refHostname string = ref.properties.defaultHostName
