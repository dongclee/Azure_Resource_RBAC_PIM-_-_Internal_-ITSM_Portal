# Azure_Resource_RBAC_PIM-_-_Internal_-ITSM_Portal
자체 ITSM 포털에서 **Azure RBAC 및 Azure Resource PIM 권한 요청, 승인, Eligible 프로비저닝, 증적 수집** 흐름을 데모하기 위한 PowerShell 기반 Full Backend 샘플입니다.

> 이 프로젝트의 목적은 Azure Portal의 IAM/PIM UI를 대체하는 제품을 제공하는 것이 아니라, 기업이 자체 ITSM/Change Management UI와 Azure 권한 거버넌스를 연계할 때 필요한 핵심 구현 패턴을 보여주는 것입니다.

## 1\. 프로젝트 배경

Azure Portal에서는 기본적으로 IAM(RBAC)과 Privileged Identity Management(PIM)를 사용하여 Azure 리소스 권한을 관리할 수 있습니다.

많은 기업 환경에서는 다음과 같은 운영 모델이 필요할 수 있습니다.

* 사용자가 Azure Portal에서 직접 권한을 요청하지 않음
* 사내 ITSM 포털에서 Azure 접근 권한 요청
* 사내 승인 절차를 통과한 요청만 실행
* 승인 결과를 Azure Resource PIM Eligible Assignment로 자동 반영
* 사용자, 역할, Scope, Ticket, 승인자와 Azure PIM Request를 연결
* Audit/Evidence를 남겨 사후 검증 가능

이 샘플은 이 흐름을 Azure App Service, Microsoft Entra ID, Managed Identity, Azure RBAC, Azure Resource PIM API로 구현합니다.

## 2\. 핵심 아키텍처

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

<img width="1599" height="984" alt="Azure-Resource-PIM-ITSM-Portal_Architecture" src="https://github.com/user-attachments/assets/8cea73e2-f3a3-47ac-b1ac-a4956cdb2036" />

### Identity 분리

|Identity|역할|
|-|-|
|Launcher Operator|데모 인프라, Easy Auth, Managed Identity, Backend 배포 구성|
|Requester / Target User|Azure 권한 요청 및 PIM Eligible/Activation 대상|
|ITSM Approver|승인자 allowlist에 따라 요청 승인|
|App Service Managed Identity|승인된 요청을 Azure Resource PIM API로 실행|

핵심 원칙은 다음과 같습니다.

```text
Deployment Identity != Runtime Managed Identity != End User PIM Role
```

## 3\. 주요 기능

### Entra Easy Auth

App Service 앞단에서 인증되지 않은 사용자를 Microsoft Entra ID 로그인으로 전환합니다.

Backend는 App Service Authentication이 전달하는 로그인 사용자 Context를 사용하여 Requester 또는 Approver를 확인합니다.

### ITSM 권한 요청

샘플 Portal에서는 다음 정보를 사용해 Ticket을 생성합니다.

* Target User UPN
* Azure RBAC Role
* Business justification
* Requester
* 생성 시각

초기 상태는 `REQUESTED`입니다.

### 승인 Workflow

로그인 사용자가 구성된 Approver allowlist에 포함되는 경우에만 요청을 `APPROVED` 상태로 변경합니다.

승인되지 않은 Ticket은 PIM Provision 단계로 진행할 수 없습니다.

### Managed Identity 기반 Backend API

Backend는 Azure Credential을 코드에 저장하지 않습니다.

App Service의 **System-assigned Managed Identity**로 Azure Resource Manager Access Token을 획득하고 ARM API를 호출합니다.

Managed Identity에는 데모 Target Resource Group Scope에서만 `User Access Administrator` 역할을 부여합니다.

### Azure Resource PIM AdminAssign

승인된 요청은 다음 Azure Resource Manager Resource Provider를 통해 Eligible Assignment로 변환됩니다.

```text
Microsoft.Authorization/roleEligibilityScheduleRequests
```

주요 Payload 개념:

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

성공한 요청은 다음 항목을 연결합니다.

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

Launcher는 Azure PIM Inventory와 State를 JSON으로 저장하고 Evidence ZIP 및 SHA-256 Manifest를 생성할 수 있습니다.

## 4\. 지원 Role Allowlist

기본 샘플은 다음 Azure RBAC 역할만 허용합니다.

* Reader
* Contributor
* Virtual Machine Contributor
* Network Contributor
* Key Vault Secrets User

필요한 경우 소스의 allowlist를 조직 정책에 맞게 수정할 수 있습니다.

## 5\. 사전 요구 사항

### PowerShell

* Windows PowerShell 5.1 또는 PowerShell 7.x

### Azure PowerShell 모듈

* `Az.Accounts`
* `Az.Resources`
* `Az.Websites`

Launcher 메뉴 `P`에서 기본 prerequisite를 확인할 수 있습니다.

### Azure / Entra 권한

데모 구축 계정에는 실행하는 단계에 따라 다음 작업 권한이 필요합니다.

* Resource Group/App Service 생성 및 구성
* Entra App Registration 생성
* App Service Authentication 구성
* Managed Identity에 Target Scope RBAC 역할 할당

실제 End User에게 Resource Group 생성 권한을 부여할 필요는 없습니다.

## 6\. Launcher 실행

GitHub에서 파일이 `.txt` 확장자로 제공되는 경우 실행 전에 `.ps1`로 변경합니다.

.\\Azure-Resource-PIM-ITSM-Portal-v2.0.7-Launcher.ps1
```

## 7\. 권장 신규 구축 순서

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

### 메뉴 설명

|메뉴|설명|
|-|-|
|P|PowerShell/Az prerequisite 확인|
|1|Architecture / security boundary 확인|
|2|Azure 로그인 및 Subscription Context 구성|
|3|Target RG, User, Approver, Role, Eligibility 기간 설정|
|4|Target RG 생성/재사용 및 Entra/RBAC 객체 확인|
|5|Linux App Service + System-assigned Managed Identity 구성|
|6|Entra App Registration + Easy Auth 구성|
|7|Managed Identity에 Target RG-scoped User Access Administrator 부여|
|8|Backend API + ITSM Portal 배포|
|9|Portal URL 및 E2E 구성 확인|
|10|Azure Resource PIM Inventory 조회|
|11|Evidence ZIP + SHA-256 Manifest 생성|
|13|Launcher State 확인|
|90|Cleanup Preview|
|91|Managed Identity의 Target RG RBAC 제거|
|92|Portal Resource Group 및 Authentication App 정리|
|93|Launcher가 생성한 Target Demo RG 정리|

## 8\. Portal E2E Demo

### Step 1. 로그인

Portal 접속 시 Entra Easy Auth가 Microsoft Entra ID 로그인을 요구합니다.

### Step 2. 권한 요청

Portal에서 Target User, Role, 업무 사유를 입력하고 요청을 생성합니다.

```text
REQUESTED
```

### Step 3. 업무 승인

구성된 Approver 계정으로 승인합니다.

```text
REQUESTED -> APPROVED
```

### Step 4. PIM Eligible Provision

승인된 Ticket에 대해 PIM Provision을 실행합니다.

```text
APPROVED -> PROVISIONED
```

Backend에서는 다음 흐름이 수행됩니다.

```text
Portal
-> Backend API
-> Managed Identity Token
-> Azure Resource Manager
-> roleEligibilityScheduleRequests
-> AdminAssign
-> Eligible Schedule
```

### Step 5. Azure PIM 확인

Target User로 Azure Portal에 로그인하여 다음 경로에서 Eligible Assignment를 확인합니다.

```text
Privileged Identity Management
-> Azure resources
-> My roles
-> Eligible assignments
```

## 9\. 최소권한 검증 예시

Target User에게 `Reader`만 Eligible/Active로 부여한 경우 VM 생성은 실패하는 것이 정상입니다.

예를 들어 VM 배포 과정에서 다음과 같은 권한이 필요할 수 있습니다.

```text
Microsoft.Resources/deployments/validate/action
```

`Reader`에는 리소스 생성 권한이 없으므로 `AuthorizationFailed`가 발생할 수 있습니다.

이 결과는 PIM 실패가 아니라 다음 원칙이 정상 동작한다는 증거입니다.

> JIT 권한도 승인된 Role과 Scope를 넘어서는 작업을 허용하지 않습니다.

## 10\. App Service 코드 배포 방식

이 프로젝트는 Backend ZIP 배포 시 Microsoft Entra Access Token을 우선 사용합니다.

```text
고유 ZIP 패키지 생성
-> Get-AzAccessToken
-> Microsoft Entra Bearer Token
-> Kudu SCM ZIP Deploy API
-> 비동기 Deployment Status 확인
-> Web App Restart
```

주요 Endpoint:

```text
https://<webapp>.scm.azurewebsites.net/api/zipdeploy?isAsync=true
```

`Publish-AzWebApp`과 SCM Basic Authentication은 기본 배포 경로로 사용하지 않습니다.

Microsoft Entra 기반 SCM 배포가 허용되지 않는 환경을 위한 제한적 Basic Authentication fallback이 코드에 포함되어 있으며, fallback을 사용하는 경우 배포 종료 후 SCM Basic Authentication을 다시 비활성화합니다.

## 11\. State 및 Evidence

기본 State 파일:

```text
AZR-PIM-V2-State.json
```

기본 Output 폴더:

```text
AZR-PIM-V2-Output
```

Evidence에는 다음 정보가 포함될 수 있습니다.

* Launcher State
* Azure Resource PIM Inventory
* Eligible / Active / Request 정보
* SHA-256 Manifest

## 12\. Cleanup

권장 순서:

```text
11 -> 90 -> 91 -> 92 -> 93
```

Launcher는 자신이 생성한 Target Resource Group과 기존 고객 Resource Group을 구분하기 위해 ownership 상태를 기록합니다.

기존 고객 Resource Group은 `OwnedTargetResourceGroup=false`인 경우 삭제하지 않습니다.

## 13\. 보안 설계 핵심

* End User에게 Resource Group 생성 권한 불필요
* Requester 인증과 Approver authorization 분리
* Target User UPN allowlist
* Azure RBAC Role allowlist
* PIM Provision 전 `APPROVED` 상태 확인
* 동일 Ticket 중복 Provision 차단
* App Service System-assigned Managed Identity 사용
* Managed Identity 권한 Scope를 Target Resource Group으로 제한
* Evidence SHA-256 생성
* Launcher-owned Resource만 Cleanup

## 14\. 데모와 Production의 차이

이 저장소는 **교육, PoC, Architecture 검증용 샘플**입니다.

Production 적용 시 다음 항목을 별도로 검토해야 합니다.

* Requester와 Approver 강제 분리(Separation of Duties)
* 승인자 Group/App Role 기반 authorization
* Azure SQL, Cosmos DB 등 영속 State 저장소
* 동시성 및 Transaction 처리
* Activity Log / PIM Audit / SIEM 연계
* 실제 ITSM/CMDB/Change Ticket 연동
* App Registration credential lifecycle
* Conditional Access
* PIM Role Management Policy
* Private Endpoint / Network isolation
* WAF / reverse proxy
* App Service Deployment Slot 및 rollback
* Monitoring / Health Check / Alerting

## 15\. 주의 사항

* 샘플을 Production에 그대로 배포하지 마십시오.
* 테스트는 별도 Subscription 또는 승인된 Demo Scope에서 수행하는 것을 권장합니다.
* 권한을 확대하기 전에 Azure RBAC Scope와 PIM Policy를 검토하십시오.
* Cleanup 메뉴를 실행하기 전에 Evidence와 ownership 정보를 확인하십시오.
* 저장소에 Tenant ID, Subscription ID, 실제 UPN, Secret, Access Token 또는 고객 식별 정보를 커밋하지 마십시오.

## 16\. Repository 권장 구성

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

공개 저장소로 배포할 경우 조직 정책에 맞는 Open Source License를 별도로 선택하십시오.

예: MIT, Apache-2.0 등.

\---

**Azure Resource PIM + Internal ITSM Portal v2.0.7**  
Easy Auth · Managed Identity · Backend ARM PIM API · ITSM Approval · Evidence Correlation

