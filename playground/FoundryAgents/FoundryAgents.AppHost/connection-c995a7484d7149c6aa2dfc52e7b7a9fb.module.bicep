@description('The location for the resource(s) to be deployed.')
param location string = resourceGroup().location

param proj_myproject_outputs_name string

param search_outputs_name string

resource proj_myproject 'Microsoft.CognitiveServices/accounts/projects@2025-09-01' existing = {
  name: proj_myproject_outputs_name
}

resource search 'Microsoft.Search/searchServices@2023-11-01' existing = {
  name: search_outputs_name
}

resource connection_c995a7484d7149c6aa2dfc52e7b7a9fb 'Microsoft.CognitiveServices/accounts/projects/connections@2026-03-01' = {
  name: 'connection-c995a7484d7149c6aa2dfc52e7b7a9fb'
  properties: {
    category: 'CognitiveSearch'
    metadata: {
      ApiType: 'Azure'
      ResourceId: search.id
      location: search.location
    }
    target: 'https://${search_outputs_name}.search.windows.net'
    authType: 'AAD'
  }
  parent: proj_myproject
}

output name string = 'connection-c995a7484d7149c6aa2dfc52e7b7a9fb'

output id string = connection_c995a7484d7149c6aa2dfc52e7b7a9fb.id