// Azure resources for the Remote WiFi Performance Tool.
// Deploy:    az deployment group create -g <rg> -f main.bicep -p adminPassword=<pw> ingestToken=<tok> registry=<docker user>
// Tear down: az group delete -n <rg>
// Everything targets free / low tiers (MSc budget). See infra/README.md.

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Prefix for resource names.')
param prefix string = 'comp702'

@description('PostgreSQL admin password.')
@secure()
param adminPassword string

@description('Bearer token the probe uses against /ingest.')
@secure()
param ingestToken string

@description('Container registry namespace holding wifi-api and wifi-ref images, e.g. docker.io/<user>.')
param registry string

@description('Client IP allowed to reach Postgres directly (for local Grafana). Empty disables the rule.')
param clientIp string = ''

// --- Storage (Blob) for raw payloads ---
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${prefix}stg${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
}

var storageConnStr = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

// --- PostgreSQL Flexible Server with TimescaleDB ---
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

resource pgDb 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
  parent: pg
  name: 'wifi'
}

// TimescaleDB must be preloaded and allowlisted before CREATE EXTENSION
// (the Alembic migration) can run.
resource pgPreload 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-06-01-preview' = {
  parent: pg
  name: 'shared_preload_libraries'
  properties: { value: 'timescaledb', source: 'user-override' }
}

resource pgExtensions 'Microsoft.DBforPostgreSQL/flexibleServers/configurations@2023-06-01-preview' = {
  parent: pg
  name: 'azure.extensions'
  properties: { value: 'TIMESCALEDB', source: 'user-override' }
  dependsOn: [pgPreload]
}

// Allow the App Services (Azure-internal traffic) to reach Postgres.
resource pgFwAzure 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = {
  parent: pg
  name: 'allow-azure-services'
  properties: { startIpAddress: '0.0.0.0', endIpAddress: '0.0.0.0' }
}

// Optional: home IP for a locally-run Grafana against the cloud DB.
resource pgFwClient 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = if (clientIp != '') {
  parent: pg
  name: 'allow-client'
  properties: { startIpAddress: clientIp, endIpAddress: clientIp }
}

// --- App Service plan shared by backend + cloud reference endpoint ---
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${prefix}-plan'
  location: location
  sku: { name: 'B1', tier: 'Basic' }
  kind: 'linux'
  properties: { reserved: true }
}

// --- FastAPI backend (container, same image as local compose) ---
resource api 'Microsoft.Web/sites@2023-12-01' = {
  name: '${prefix}-api'
  location: location
  properties: {
    serverFarmId: plan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${registry}/wifi-api:latest'
      appSettings: [
        { name: 'API_INGEST_TOKEN', value: ingestToken }
        { name: 'API_DATABASE_URL', value: 'postgresql+psycopg://wifi:${adminPassword}@${pg.properties.fullyQualifiedDomainName}:5432/wifi?sslmode=require' }
        { name: 'API_BLOB_CONN_STR', value: storageConnStr }
        { name: 'WEBSITES_PORT', value: '8000' }
      ]
    }
  }
  dependsOn: [pgDb]
}

// --- Cloud reference endpoint (same nginx image as the local server) ---
resource ref 'Microsoft.Web/sites@2023-12-01' = {
  name: '${prefix}-ref'
  location: location
  properties: {
    serverFarmId: plan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${registry}/wifi-ref:latest'
      appSettings: [
        { name: 'WEBSITES_PORT', value: '80' }
      ]
    }
  }
}

output apiHostname string = api.properties.defaultHostName
output refHostname string = ref.properties.defaultHostName
output pgHostname string = pg.properties.fullyQualifiedDomainName
