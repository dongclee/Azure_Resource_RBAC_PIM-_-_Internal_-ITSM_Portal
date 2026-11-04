# Azure Resource PIM + Internal ITSM Portal v2.0.7

A PowerShell-based Full Backend sample that demonstrates how an organization can implement **Azure RBAC and Azure Resource PIM access request, approval, Eligible provisioning, and evidence collection** from its own internal ITSM portal.

> The goal of this project is not to replace the Azure Portal IAM/PIM experience as a product. It demonstrates the core implementation pattern required to integrate an enterprise ITSM/change-management UI with Azure access governance.

## 1\. Background

Azure Portal provides native IAM (RBAC) and Privileged Identity Management (PIM) experiences for managing access to Azure resources.

Some enterprise environments require a different operating model:

* Users do not request access directly from Azure Portal.
* Azure access requests originate from an internal ITSM portal.
* Only requests that pass the enterprise approval process are provisioned.
* Approved requests are automatically translated into Azure Resource PIM Eligible assignments.
* Users, roles, scopes, tickets, approvers, and Azure PIM requests are correlated.
* Audit evidence is retained for later verification.

This sample implements that workflow with Azure App Service, Microsoft Entra ID, Managed Identity, Azure RBAC, and the Azure Resource PIM API.

## 2\. High-Level Architecture

```text
Requester / Approver
        |
        | Microsoft Entra ID sign-in
        v
Azure App Service
+ Entra Easy Auth
        |
        v
Internal ITSM Portal / Node.js Backend
        |
        | System-assigned Managed Identity
        v
Azure Resource Manager
Microsoft.Authorization
        |
        v
Target Resource Group
+ Azure RBAC
+ Azure Resource PIM
        |
        +--> Eligible Assignment
        +--> PIM Request ID
        +--> Eligibility Schedule ID
        +--> Evidence SHA-256
```
<img width="1599" height="984" alt="Azure-Resource-PIM-ITSM-Portal_Architecture" src="https://github.com/user-attachments/assets/aac736db-932d-413a-8a5c-410866879d97" />

### Identity Separation

|Identity|Responsibility|
|-|-|
|Launcher Operator|Configures demo infrastructure, Easy Auth, Managed Identity, and backend deployment|
|Requester / Target User|Requests Azure access and becomes the target of PIM eligibility/activation|
|ITSM Approver|Approves requests according to the configured approver allowlist|
|App Service Managed Identity|Executes approved Azure Resource PIM operations|

A key design principle is:

```text
Deployment Identity != Runtime Managed Identity != End User PIM Role
```

## 3\. Key Capabilities

### Entra Easy Auth

App Service Authentication redirects unauthenticated users to Microsoft Entra ID sign-in.

The backend uses authenticated user context passed by App Service Authentication to identify the requester or approver.

### ITSM Access Request

The sample portal creates a ticket containing information such as:

* Target user UPN
* Azure RBAC role
* Business justification
* Requester
* Creation time

The initial state is `REQUESTED`.

### Approval Workflow

A request can move to `APPROVED` only when the signed-in user is included in the configured approver allowlist.

A ticket that has not been approved cannot proceed to PIM provisioning.

### Managed Identity Backend API

The backend does not store Azure administrator credentials in application code.

It uses the App Service **system-assigned Managed Identity** to obtain an Azure Resource Manager access token and call ARM APIs.

The backend Managed Identity receives `User Access Administrator` only at the target Resource Group scope for the demo.

### Azure Resource PIM AdminAssign

An approved request is translated into an Eligible assignment through the following Azure Resource Manager resource provider:

```text
Microsoft.Authorization/roleEligibilityScheduleRequests
```

Conceptual payload:

```json
{
  "properties": {
    "principalId": "<target-principal-id>",
    "roleDefinitionId": "<azure-rbac-role-definition-id>",
    "requestType": "AdminAssign",
    "justification": "ITSM <ticket-id>: <business-justification>",
    "scheduleInfo": {
      "expiration": {
        "type": "AfterDuration",
        "duration": "P30D"
      }
    },
    "ticketInfo": {
      "ticketNumber": "<ticket-id>",
      "ticketSystem": "Internal ITSM v2"
    }
  }
}
```

### Evidence Correlation

A successful provisioning operation correlates:

```text
ITSM Ticket
  -> Requester
  -> Approver
  -> Target User
  -> Target Role
  -> Azure Scope
  -> PIM Request ID
  -> Eligibility Schedule ID
  -> Evidence SHA-256
```

The launcher can export Azure PIM inventory and local state as JSON and generate an evidence ZIP with a SHA-256 manifest.

## 4\. Supported Role Allowlist

The default sample allows these Azure RBAC roles:

* Reader
* Contributor
* Virtual Machine Contributor
* Network Contributor
* Key Vault Secrets User

Modify the source allowlist to match your organization's policy where appropriate.

## 5\. Prerequisites

### PowerShell

* Windows PowerShell 5.1 or PowerShell 7.x

### Azure PowerShell Modules

* `Az.Accounts`
* `Az.Resources`
* `Az.Websites`

Launcher menu `P` performs a basic prerequisite check.

### Azure / Entra Permissions

Depending on the menu being executed, the deployment operator needs sufficient permissions to:

* Create/configure Resource Groups and App Service resources
* Create an Entra App Registration
* Configure App Service Authentication
* Assign the required role to the Managed Identity at the target scope

The end user does not need Resource Group creation permission.

## 6\. Running the Launcher

If the GitHub artifact is stored with a `.txt` suffix, rename it to `.ps1` before execution.

.\\Azure-Resource-PIM-ITSM-Portal-v2.0.7-Launcher.ps1
```

## 7\. Recommended Clean Deployment Sequence

```text
P
-> 1
-> 2
-> 3
-> 4
-> 5
-> 6
-> 7
-> 8
-> 9
-> Portal E2E Test
-> 10
-> 11
```

### Menu Reference

|Menu|Description|
|-|-|
|P|Validate PowerShell/Az prerequisites|
|1|Display architecture and security boundaries|
|2|Sign in to Azure and establish subscription context|
|3|Configure target RG, user, approver, role, and eligibility period|
|4|Prepare/reuse the target RG and resolve Entra/RBAC objects|
|5|Create Linux App Service and system-assigned Managed Identity|
|6|Create Entra App Registration and configure Easy Auth|
|7|Grant target-RG-scoped User Access Administrator to the Managed Identity|
|8|Deploy the backend PIM API and ITSM portal|
|9|Display portal URL and E2E configuration|
|10|Read Azure Resource PIM inventory|
|11|Export evidence ZIP and SHA-256 manifest|
|13|Display launcher state|
|90|Preview cleanup scope|
|91|Remove target-RG RBAC from the Managed Identity|
|92|Remove portal resources and authentication app|
|93|Remove a launcher-owned target demo RG|

## 8\. Portal E2E Demo

### Step 1. Sign In

When the portal is opened, Entra Easy Auth requires Microsoft Entra ID authentication.

### Step 2. Submit an Access Request

Enter the target user, role, and business justification.

```text
REQUESTED
```

### Step 3. Approve the Request

Approve the ticket with an account configured as an approver.

```text
REQUESTED -> APPROVED
```

### Step 4. Provision PIM Eligibility

Provision the approved ticket to Azure Resource PIM.

```text
APPROVED -> PROVISIONED
```

The backend executes:

```text
Portal
-> Backend API
-> Managed Identity Token
-> Azure Resource Manager
-> roleEligibilityScheduleRequests
-> AdminAssign
-> Eligible Schedule
```

### Step 5. Verify in Azure PIM

Sign in as the target user and verify the Eligible assignment in Azure Portal:

```text
Privileged Identity Management
-> Azure resources
-> My roles
-> Eligible assignments
```

## 9\. Least-Privilege Validation Example

If the target user receives only the `Reader` role, attempting to create a virtual machine should fail.

For example, VM deployment can require the following action:

```text
Microsoft.Resources/deployments/validate/action
```

`Reader` does not provide resource creation permissions, so Azure can return `AuthorizationFailed`.

This is not a PIM failure. It demonstrates that:

> Just-in-time access does not allow actions outside the approved Azure RBAC role and scope.

## 10\. App Service Code Deployment

The launcher prefers Microsoft Entra authentication for backend ZIP deployment.

```text
Create a unique ZIP package
-> Get-AzAccessToken
-> Microsoft Entra Bearer Token
-> Kudu SCM ZIP Deploy API
-> Poll asynchronous deployment status
-> Restart Web App
```

Endpoint:

```text
https://<webapp>.scm.azurewebsites.net/api/zipdeploy?isAsync=true
```

`Publish-AzWebApp` and SCM Basic Authentication are not the default deployment path.

A controlled Basic Authentication fallback is included for environments where Microsoft Entra-authenticated SCM deployment is not accepted. When fallback is used, SCM Basic Authentication is disabled again after the deployment attempt.

## 11\. State and Evidence

Default state file:

```text
AZR-PIM-V2-State.json
```

Default output directory:

```text
AZR-PIM-V2-Output
```

Evidence can include:

* Launcher state
* Azure Resource PIM inventory
* Eligible / Active / Request data
* SHA-256 manifest

## 12\. Cleanup

Recommended cleanup sequence:

```text
11 -> 90 -> 91 -> 92 -> 93
```

The launcher tracks whether the target Resource Group was created by the launcher.

An existing customer Resource Group is preserved when `OwnedTargetResourceGroup=false`.

## 13\. Security Design Highlights

* End users do not need Resource Group creation permissions.
* Requester authentication and approver authorization are separate controls.
* Target user UPN allowlist.
* Azure RBAC role allowlist.
* `APPROVED` state is required before PIM provisioning.
* Duplicate provisioning for the same ticket is blocked.
* App Service system-assigned Managed Identity is used for runtime Azure access.
* Managed Identity permissions are scoped to the target Resource Group.
* Evidence SHA-256 is generated.
* Cleanup protects non-launcher-owned resources.

## 14\. Demo vs. Production

This repository is a **demo, PoC, and architecture-validation sample**.

Before production adoption, evaluate and implement controls such as:

* Enforced separation of requester and approver duties
* Group/App-Role-based approver authorization
* Durable state storage such as Azure SQL or Cosmos DB
* Concurrency and transaction management
* Azure Activity Log / PIM Audit / SIEM integration
* Integration with the real ITSM/CMDB/change-management platform
* App Registration credential lifecycle management
* Conditional Access
* PIM Role Management Policy
* Private Endpoint / network isolation
* WAF / reverse proxy
* App Service deployment slots and rollback
* Monitoring / health checks / alerting

## 15\. Important Notes

* Do not deploy this sample to production without a security and architecture review.
* Prefer a dedicated subscription or an approved demo scope for testing.
* Review Azure RBAC scope and PIM policy before expanding permissions.
* Check evidence and ownership state before cleanup.
* Never commit tenant IDs, subscription IDs, real user UPNs, secrets, access tokens, or customer-identifying data to a public repository.

## 16\. Suggested Repository Layout

```text
.
├── Azure-Resource-PIM-ITSM-Portal-v2.0.7-Launcher.ps1
├── README.md
├── README.en.md
├── LICENSE
└── docs/
    └── architecture-and-demo-guide.pptx
```

## 17\. License

Before publishing this project, select an open-source license that matches your organization's requirements.

Examples include MIT and Apache-2.0.

\---

**Azure Resource PIM + Internal ITSM Portal v2.0.7**  
Easy Auth · Managed Identity · Backend ARM PIM API · ITSM Approval · Evidence Correlation

