@description('Name of the Log Analytics workspace')
param name string

@description('Azure region')
param location string

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

output customerId string = logAnalytics.properties.customerId

@secure()
output sharedKey string = logAnalytics.listKeys().primarySharedKey
