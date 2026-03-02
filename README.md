# Agent Identity Samples

This repository contains samples that demonstrate how to create, manage, and use agent identities across identity platforms. Each sample provides a complete, deployable solution with infrastructure-as-code, application source, and setup scripts so you can get started quickly.

## Microsoft Entra Agent ID

| Sample | Description |
|---|---|
| [Create Agent Identity Blueprint and Identities](entra-agent-id/create-agent-blueprint-and-identities/) | A .NET API deployed to Azure Container Apps that creates and manages Entra Agent Identities via Microsoft Graph. Includes Bicep infrastructure, automated blueprint setup, and a device-code test client. |
| [Call Azure Service with Entra Agent Identity](entra-agent-id/call-azure-service/) | An interactive chat application powered by Azure OpenAI that uses an Entra Agent Identity to autonomously authenticate to Azure Cosmos DB under the agent's own identity. Demonstrates the autonomous agent token pattern with a Blazor frontend and .NET API on Azure Container Apps. |
