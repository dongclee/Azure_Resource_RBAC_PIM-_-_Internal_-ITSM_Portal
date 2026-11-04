#requires -Version 5.1
<#
.SYNOPSIS
 Azure Resource PIM + Internal ITSM Portal v2.0.7 - Full Backend Demo Launcher
.DESCRIPTION
 Dedicated V2 demo: App Service + Entra Easy Auth + System-assigned Managed Identity
 + Backend ARM PIM API + ITSM Approval + Evidence Correlation.
 Windows PowerShell 5.1 / PowerShell 7.x compatible design.

 IMPORTANT SECURITY MODEL
 - End user does not need Resource Group create permission.
 - Use an existing approved Target RG where possible.
 - Backend Managed Identity receives User Access Administrator only at Target RG scope.
 - Backend role and user are allowlisted/configured by the launcher.
 - Requester authentication and Approver authorization are separate controls.
#>
[CmdletBinding()]
param(
 [string]$TenantId='',
 [string]$SubscriptionId='',
 [string]$Location='koreacentral',
 [string]$TargetResourceGroupName='rg-resource-pim-demo-target',
 [string]$PortalResourceGroupName='rg-azr-pim-itsm-v2',
 [string]$AppServicePlanName='asp-azr-pim-itsm-v2',
 [string]$WebAppName='',
 [string]$TargetUserUpn='',
 [string]$ApproverUpn='',
 [ValidateSet('Reader','Contributor','Virtual Machine Contributor','Network Contributor','Key Vault Secrets User')]
 [string]$TargetRoleName='Reader',
 [ValidateRange(1,90)][int]$EligibilityDays=30,
 [string]$OutputRoot=(Join-Path $PSScriptRoot 'AZR-PIM-V2-Output'),
 [string]$StatePath=(Join-Path $PSScriptRoot 'AZR-PIM-V2-State.json')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$script:Version='2.0.7';$script:State=$null;$script:Connected=$false;$script:PimApi='2020-10-01'
function Log([string]$m,[string]$l='INFO'){$c=@{INFO='Cyan';STEP='White';OK='Green';WARN='Yellow';ERROR='Red'}[$l];Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$l] $m" -ForegroundColor $c}
function Pause-X{[void](Read-Host 'Press Enter to continue')}
function Utc{(Get-Date).ToUniversalTime().ToString('o')}
function Ensure([string]$p=$OutputRoot){if(-not(Test-Path $p)){[void](New-Item -ItemType Directory -Path $p -Force)}}
function Exact([string]$Prompt,[string]$Expected){Write-Host $Prompt -ForegroundColor Yellow;(Read-Host "Type exactly: $Expected") -ceq $Expected}
function Prop($o,[string]$n,$d=$null){if($null -ne $o -and $null -ne $o.PSObject.Properties[$n]){return $o.$n};return $d}
function New-State{[pscustomobject]@{Version=$script:Version;TenantId=$TenantId;SubscriptionId=$SubscriptionId;Location=$Location;TargetResourceGroupName=$TargetResourceGroupName;PortalResourceGroupName=$PortalResourceGroupName;AppServicePlanName=$AppServicePlanName;WebAppName=$WebAppName;TargetUserUpn=$TargetUserUpn;TargetUserObjectId=$null;ApproverUpn=$ApproverUpn;TargetRoleName=$TargetRoleName;RoleDefinitionResourceId=$null;EligibilityDays=$EligibilityDays;PortalUrl=$null;ManagedIdentityPrincipalId=$null;AuthAppId=$null;AuthAppObjectId=$null;AuthServicePrincipalId=$null;MiRoleAssignmentId=$null;OwnedPortalResourceGroup=$false;OwnedTargetResourceGroup=$false;EvidenceFiles=@();UpdatedUtc=$null}}
function Add-State([string]$n,$v){if($null -eq $script:State.PSObject.Properties[$n]){$script:State|Add-Member -NotePropertyName $n -NotePropertyValue $v}}
function Load-State{if(Test-Path $StatePath){$script:State=Get-Content $StatePath -Raw|ConvertFrom-Json;foreach($x in (New-State).PSObject.Properties){Add-State $x.Name $x.Value};$script:State.Version=$script:Version;Log "State loaded: $StatePath" OK}else{$script:State=New-State;Log 'New V2 state initialized.' INFO}}
function Save-State{Ensure (Split-Path -Parent $StatePath);$script:State.UpdatedUtc=Utc;$enc=New-Object Text.UTF8Encoding($true);[IO.File]::WriteAllText($StatePath,($script:State|ConvertTo-Json -Depth 30),$enc)}
function Need-Connection{if(-not$script:Connected){$c=Get-AzContext -ErrorAction SilentlyContinue;if($null -eq $c -or -not$c.Subscription.Id){throw 'Run menu 2 first.'};$script:Connected=$true}}
function Target-Scope{"/subscriptions/$($script:State.SubscriptionId)/resourceGroups/$($script:State.TargetResourceGroupName)"}
function Arm([string]$Method,[string]$Path,$Body=$null){Need-Connection;$p=@{Method=$Method;Path=$Path;ErrorAction='Stop'};if($null -ne $Body){$p.Payload=$Body|ConvertTo-Json -Depth 50 -Compress};$r=Invoke-AzRestMethod @p;$status=Prop $r 'StatusCode' $null;if($null -ne $status -and ([int]$status -lt 200 -or [int]$status -ge 300)){throw "ARM HTTP $status $Method $Path : $(Prop $r 'Content' '')"};$content=[string](Prop $r 'Content' '');if(-not[string]::IsNullOrWhiteSpace($content)){try{return $content|ConvertFrom-Json}catch{return $r}};return $r}
function Test-Prereq{$mods=@('Az.Accounts','Az.Resources','Az.Websites');$rows=foreach ($n in $mods){$m=Get-Module -ListAvailable $n|Sort-Object Version -Descending|Select-Object -First 1;[pscustomobject]@{Module=$n;Installed=if($m){$m.Version}else{'-'};Ready=[bool]$m}};$rows|Format-Table -AutoSize;if(@($rows|Where-Object{-not$_.Ready}).Count){Log 'Install/update Az modules before continuing.' WARN}}
function Connect-V2{Import-Module Az.Accounts;Import-Module Az.Resources;Import-Module Az.Websites -DisableNameChecking;$p=@{};if($script:State.TenantId){$p.Tenant=$script:State.TenantId};if($script:State.SubscriptionId){$p.Subscription=$script:State.SubscriptionId};Connect-AzAccount @p|Out-Null;$c=Get-AzContext;$script:State.TenantId=[string]$c.Tenant.Id;$script:State.SubscriptionId=[string]$c.Subscription.Id;$script:Connected=$true;Save-State;Log "Connected: $($script:State.SubscriptionId) / $($script:State.TenantId)" OK}
function Configure-V2{
 foreach ($n in @('TargetResourceGroupName','TargetUserUpn','ApproverUpn','TargetRoleName')){
  $old=[string]$script:State.$n;$v=Read-Host "$n [$old]";if($v){$script:State.$n=$v.Trim()}
 }
 $v=Read-Host "EligibilityDays [$($script:State.EligibilityDays)]";if($v){$script:State.EligibilityDays=[int]$v}
 if([string]::IsNullOrWhiteSpace([string]$script:State.TargetResourceGroupName)){throw 'TargetResourceGroupName is required.'}
 if([string]::IsNullOrWhiteSpace([string]$script:State.TargetUserUpn)){throw 'TargetUserUpn is required.'}
 if([string]::IsNullOrWhiteSpace([string]$script:State.ApproverUpn)){throw 'ApproverUpn is required.'}
 if($script:State.TargetUserUpn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$'){throw 'TargetUserUpn format is invalid.'}
 if($script:State.ApproverUpn -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$'){throw 'ApproverUpn format is invalid.'}
 if($script:State.TargetRoleName -notin @('Reader','Contributor','Virtual Machine Contributor','Network Contributor','Key Vault Secrets User')){throw 'Role outside allowlist'}
 if($script:State.EligibilityDays -lt 1 -or $script:State.EligibilityDays -gt 90){throw 'EligibilityDays must be 1..90'}
 Save-State;Log "V2 configuration saved. TargetUser=$($script:State.TargetUserUpn); Approver=$($script:State.ApproverUpn)" OK
}
function Ensure-TargetRg{
 Need-Connection
 $rg=Get-AzResourceGroup -Name $script:State.TargetResourceGroupName -ErrorAction SilentlyContinue
 if($null -ne $rg){Log "Target RG exists and will be reused: $($rg.ResourceGroupName) [$($rg.Location)]" OK;return}
 Log "Target RG not found: $($script:State.TargetResourceGroupName)" WARN
 if(-not(Exact "Create dedicated V2 target demo RG '$($script:State.TargetResourceGroupName)' in $($script:State.Location)." 'CREATE-V2-TARGET-RG')){throw 'Target RG is required. Creation cancelled.'}
 $rg=New-AzResourceGroup -Name $script:State.TargetResourceGroupName -Location $script:State.Location -Tag @{Purpose='AzureResourcePIM-ITSM-v2';CreatedBy='Azure-Resource-PIM-ITSM-Portal-v2'}
 $script:State.OwnedTargetResourceGroup=$true;Save-State;Log "V2 target demo RG created: $($rg.ResourceGroupName) [$($rg.Location)]" OK
}

function Resolve-V2Objects{Need-Connection;$rg=Get-AzResourceGroup -Name $script:State.TargetResourceGroupName -ErrorAction SilentlyContinue;if($null -eq $rg){throw "Target RG not found: $($script:State.TargetResourceGroupName). V2 production profile expects an existing approved RG."};if([string]::IsNullOrWhiteSpace([string]$script:State.TargetUserUpn)){throw 'TargetUserUpn is required.'};if([string]::IsNullOrWhiteSpace([string]$script:State.ApproverUpn)){throw 'ApproverUpn is required.'};$u=Get-AzADUser -UserPrincipalName $script:State.TargetUserUpn -ErrorAction Stop;if($null -eq $u -or -not$u.Id){throw 'Target user not found'};$approver=Get-AzADUser -UserPrincipalName $script:State.ApproverUpn -ErrorAction Stop;if($null -eq $approver -or -not $approver.Id){throw 'Approver user not found'};$role=Get-AzRoleDefinition -Name $script:State.TargetRoleName -ErrorAction Stop;$script:State.TargetUserObjectId=[string]$u.Id;$script:State.RoleDefinitionResourceId="/subscriptions/$($script:State.SubscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$($role.Id)";Save-State;Log "Resolved TargetUser=$($script:State.TargetUserObjectId), Approver=$($script:State.ApproverUpn), Role=$($script:State.TargetRoleName), Scope=$(Target-Scope)" OK}
function Show-Architecture{Write-Host @'
Azure Resource PIM + Internal ITSM Portal v2.0
  Entra Easy Auth sign-in
      -> POST /api/request
      -> signed-in Approver POST /api/approve
      -> POST /api/pim/eligible
      -> App Service System-assigned Managed Identity
      -> ARM Microsoft.Authorization roleEligibilityScheduleRequests/AdminAssign
      -> PIM Request ID + Target Schedule ID + SHA-256 evidence correlation

Recommended: P -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9 -> Portal E2E -> 10 -> 11
Cleanup: 11 -> 90 -> 91 -> 92 -> 93
'@}
function Set-WebAppLinuxRuntime{
 param([string]$ResourceGroupName,[string]$Name,[string]$LinuxFxVersion='NODE|20-lts')
 Need-Connection
 $path="/subscriptions/$($script:State.SubscriptionId)/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$Name/config/web?api-version=2022-03-01"
 $body=@{properties=@{linuxFxVersion=$LinuxFxVersion;alwaysOn=$true}}
 [void](Arm PUT $path $body)
 Log "Linux runtime configured through ARM: $LinuxFxVersion" OK
}
function New-Infra{Need-Connection;Resolve-V2Objects;if(-not(Exact 'Create V2 Portal RG, Linux App Service Plan, Web App and System Managed Identity.' 'CREATE-V2-INFRA')){return};if([string]::IsNullOrWhiteSpace([string]$script:State.WebAppName)){$script:State.WebAppName="azr-pim-itsm-v2-$(([guid]::NewGuid().Guid.Replace('-','')).Substring(0,8))"};$rg=Get-AzResourceGroup -Name $script:State.PortalResourceGroupName -ErrorAction SilentlyContinue;if($null -eq $rg){$rg=New-AzResourceGroup -Name $script:State.PortalResourceGroupName -Location $script:State.Location;$script:State.OwnedPortalResourceGroup=$true};$plan=Get-AzAppServicePlan -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.AppServicePlanName -ErrorAction SilentlyContinue;if($null -eq $plan){$plan=New-AzAppServicePlan -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.AppServicePlanName -Location $script:State.Location -Tier Basic -NumberofWorkers 1 -Linux};$app=Get-AzWebApp -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName -ErrorAction SilentlyContinue;if($null -eq $app){$app=New-AzWebApp -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName -Location $script:State.Location -AppServicePlan $script:State.AppServicePlanName};Set-AzWebApp -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName -AssignIdentity $true|Out-Null;Set-WebAppLinuxRuntime -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName;Start-Sleep 3;$app=Get-AzWebApp -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName;$script:State.ManagedIdentityPrincipalId=[string]$app.Identity.PrincipalId;$script:State.PortalUrl="https://$($script:State.WebAppName).azurewebsites.net";Save-State;Log "V2 infra ready: $($script:State.PortalUrl), MI=$($script:State.ManagedIdentityPrincipalId)" OK}
function Set-EasyAuth{Need-Connection;if(-not$script:State.WebAppName){throw 'Run menu 5 first.'};$redirect="https://$($script:State.WebAppName).azurewebsites.net/.auth/login/aad/callback";$a=$null;if($script:State.AuthAppId){$a=Get-AzADApplication -ApplicationId $script:State.AuthAppId -ErrorAction SilentlyContinue};if($null -eq $a){$a=New-AzADApplication -DisplayName "Azure Resource PIM ITSM v2 - $($script:State.WebAppName)" -Web @{RedirectUri=@($redirect);ImplicitGrantSetting=@{EnableIdTokenIssuance=$true}};$script:State.AuthAppId=[string]$a.AppId;$script:State.AuthAppObjectId=[string]$a.Id;$sp=New-AzADServicePrincipal -ApplicationId $a.AppId -ErrorAction SilentlyContinue;if($sp){$script:State.AuthServicePrincipalId=[string]$sp.Id}};$cred=New-AzADAppCredential -ObjectId $a.Id -EndDate (Get-Date).AddMonths(3);$settings=@{AZURE_CLIENT_SECRET=$cred.SecretText};Set-AzWebApp -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName -AppSettings $settings|Out-Null;$cfg=@{properties=@{platform=@{enabled=$true};globalValidation=@{requireAuthentication=$true;unauthenticatedClientAction='RedirectToLoginPage';redirectToProvider='azureactivedirectory'};identityProviders=@{azureActiveDirectory=@{enabled=$true;registration=@{openIdIssuer="https://sts.windows.net/$($script:State.TenantId)/v2.0";clientId=$script:State.AuthAppId;clientSecretSettingName='AZURE_CLIENT_SECRET'}}};login=@{tokenStore=@{enabled=$true}}}};[void](Arm PUT "/subscriptions/$($script:State.SubscriptionId)/resourceGroups/$($script:State.PortalResourceGroupName)/providers/Microsoft.Web/sites/$($script:State.WebAppName)/config/authsettingsV2?api-version=2022-03-01" $cfg);Save-State;Log "Easy Auth ready. AppId=$($script:State.AuthAppId)" OK}
function Grant-MiRole{Need-Connection;if(-not$script:State.ManagedIdentityPrincipalId){throw 'Run menu 5 first.'};$scope=Target-Scope;if(-not(Exact "Grant User Access Administrator to V2 Managed Identity only at $scope" 'GRANT-V2-MI-UAA')){return};$e=Get-AzRoleAssignment -ObjectId $script:State.ManagedIdentityPrincipalId -Scope $scope -RoleDefinitionName 'User Access Administrator' -ErrorAction SilentlyContinue;if($null -eq $e){$ra=New-AzRoleAssignment -ObjectId $script:State.ManagedIdentityPrincipalId -Scope $scope -RoleDefinitionName 'User Access Administrator';$script:State.MiRoleAssignmentId=[string]$ra.RoleAssignmentId}else{$script:State.MiRoleAssignmentId=[string]@($e)[0].RoleAssignmentId};Save-State;Log 'Managed Identity scoped RBAC ready.' OK}
function New-BackendPackage{Ensure;$stamp=Get-Date -Format 'yyyyMMdd-HHmmssfff';$nonce=([guid]::NewGuid().Guid.Replace('-','')).Substring(0,8);$root=Join-Path $OutputRoot "Backend-${stamp}-${nonce}";[void](New-Item $root -ItemType Directory -Force);$pkg='{"scripts":{"start":"node server.js"},"engines":{"node":">=20"}}';[IO.File]::WriteAllText((Join-Path $root 'package.json'),$pkg,(New-Object Text.UTF8Encoding($false)));$server=@'
const http=require('http'),fs=require('fs'),crypto=require('crypto');const port=process.env.PORT||8080,db='/home/data/azrpim-v2.json',roles=['Reader','Contributor','Virtual Machine Contributor','Network Contributor','Key Vault Secrets User'];function load(){try{return JSON.parse(fs.readFileSync(db))}catch{return{requests:[]}}}function save(d){fs.mkdirSync('/home/data',{recursive:true});fs.writeFileSync(db,JSON.stringify(d,null,2))}function who(req){return String(req.headers['x-ms-client-principal-name']||'').toLowerCase()}function send(res,c,o){res.writeHead(c,{'Content-Type':'application/json; charset=utf-8'});res.end(JSON.stringify(o))}function b(req){return new Promise((ok,bad)=>{let d='';req.on('data',x=>{d+=x;if(d.length>1048576)bad(Error('payload too large'))});req.on('end',()=>{try{ok(d?JSON.parse(d):{})}catch(e){bad(e)}})})}async function miToken(){let e=process.env.IDENTITY_ENDPOINT,h=process.env.IDENTITY_HEADER;if(!e||!h)throw Error('Managed Identity endpoint unavailable');let r=await fetch(e+'?resource='+encodeURIComponent('https://management.azure.com/')+'&api-version=2019-08-01',{headers:{'X-IDENTITY-HEADER':h}});if(!r.ok)throw Error('Managed Identity token '+r.status);return(await r.json()).access_token}async function arm(method,path,body){let t=await miToken(),r=await fetch('https://management.azure.com'+path,{method,headers:{Authorization:'Bearer '+t,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined}),text=await r.text();if(!r.ok)throw Error('ARM '+r.status+' '+text);return text?JSON.parse(text):{}}function now(){return new Date().toISOString()}function page(){return `<!doctype html><meta charset=utf-8><title>Internal ITSM | Azure Resource PIM v2</title><style>body{margin:0;font:14px Segoe UI;background:#f3f6fa;color:#102133}header{background:#08233f;color:white;padding:22px 5%}main{max-width:1120px;margin:22px auto}.g{display:grid;grid-template-columns:1fr 1fr;gap:18px}.c{background:white;padding:20px;border:1px solid #dce5ef;border-radius:12px}input,select,textarea,button{width:100%;box-sizing:border-box;padding:10px;margin:6px 0}button{background:#1267d6;color:white;border:0;border-radius:7px;font-weight:700}.row{padding:10px;border-bottom:1px solid #eee}.ok{color:#087253;font-weight:700}.warn{color:#9a6b00;font-weight:700}small{word-break:break-all}</style><header><h2>Internal ITSM · Azure Resource PIM v2.0</h2>Easy Auth + Managed Identity + Backend PIM API + Evidence Correlation</header><main><div class=g><section class=c><h2>1. 권한 요청</h2><input id=u placeholder="요청자 UPN"><select id=r><option>Reader</option><option>Contributor</option><option>Virtual Machine Contributor</option><option>Network Contributor</option><option>Key Vault Secrets User</option></select><textarea id=j>승인된 변경 작업 수행</textarea><button onclick=reqx()>요청 등록</button><h2>2. 업무 승인</h2><input id=t placeholder="Ticket ID"><button onclick=apx()>현재 로그인 계정으로 승인</button><h2>3. PIM Eligible</h2><button onclick=pimx()>승인 Ticket을 Azure PIM으로 Provision</button></section><section class=c><h2>Request / PIM / Evidence</h2><div id=list>Loading...</div></section></div></main><script>async function a(p,m='GET',x){let z=await fetch(p,{method:m,headers:{'Content-Type':'application/json'},body:x?JSON.stringify(x):null}),j=await z.json();if(!z.ok)alert(j.error||JSON.stringify(j));return j}async function rf(){let x=await a('/api/requests');list.innerHTML=x.requests.map(function(q){return '<div class=row><b>'+q.ticket+'</b> <span class='+(q.status==='PROVISIONED'?'ok':'warn')+'>'+q.status+'</span><br>'+q.upn+' · '+q.role+'<br><small>Requester: '+(q.requester||'-')+'<br>Approver: '+(q.approver||'-')+'<br>PIM Request: '+(q.pimRequestId||'-')+'<br>Schedule: '+(q.targetScheduleId||'-')+'<br>Evidence SHA256: '+(q.evidenceSha256||'-')+'</small></div>'}).join('')}async function reqx(){let x=await a('/api/request','POST',{upn:u.value,role:r.value,justification:j.value});t.value=x.ticket||'';rf()}async function apx(){await a('/api/approve','POST',{ticket:t.value});rf()}async function pimx(){await a('/api/pim/eligible','POST',{ticket:t.value});rf()}rf()</script>`}
http.createServer(async(req,res)=>{try{let me=who(req);if(process.env.REQUIRE_AUTH==='true'&&!me)return send(res,401,{error:'Easy Auth identity required'});if(req.url==='/'&&req.method==='GET'){res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});return res.end(page())}let d=load();if(req.url==='/api/requests')return send(res,200,d);if(req.url==='/api/request'&&req.method==='POST'){let x=await b(req);if(!x.upn||!roles.includes(x.role))return send(res,400,{error:'invalid UPN/role'});if(x.upn.toLowerCase()!==String(process.env.DEMO_USER_UPN||'').toLowerCase())return send(res,403,{error:'target UPN outside configured demo allowlist'});let q={ticket:'CHG-AZR-PIM-'+Date.now(),upn:x.upn,role:x.role,justification:x.justification||'',requester:me,status:'REQUESTED',createdUtc:now()};d.requests.unshift(q);save(d);return send(res,201,q)}if(req.url==='/api/approve'&&req.method==='POST'){let x=await b(req),q=d.requests.find(y=>y.ticket===x.ticket);if(!q)return send(res,404,{error:'ticket not found'});let allow=String(process.env.APPROVER_UPNS||'').toLowerCase().split(';').filter(Boolean);if(!allow.includes(me))return send(res,403,{error:'signed-in identity is not an approver'});q.approver=me;q.status='APPROVED';q.approvedUtc=now();save(d);return send(res,200,q)}if(req.url==='/api/pim/eligible'&&req.method==='POST'){let x=await b(req),q=d.requests.find(y=>y.ticket===x.ticket);if(!q)return send(res,404,{error:'ticket not found'});if(q.status!=='APPROVED')return send(res,409,{error:'ticket must be APPROVED'});if(q.pimRequestId)return send(res,409,{error:'idempotency: PIM request already exists'});if(q.role!==process.env.PIM_ROLE_NAME)return send(res,403,{error:'role differs from launcher allowlisted role'});let rid=crypto.randomUUID(),days=Math.min(90,Math.max(1,parseInt(process.env.ELIGIBILITY_DAYS||'30'))),payload={properties:{principalId:process.env.DEMO_PRINCIPAL_ID,roleDefinitionId:process.env.PIM_ROLE_DEFINITION_ID,requestType:'AdminAssign',justification:`ITSM ${q.ticket}: ${q.justification}`,scheduleInfo:{startDateTime:now(),expiration:{type:'AfterDuration',duration:`P${days}D`}},ticketInfo:{ticketNumber:q.ticket,ticketSystem:'Internal ITSM v2'}}},path=`${process.env.TARGET_SCOPE}/providers/Microsoft.Authorization/roleEligibilityScheduleRequests/${rid}?api-version=2020-10-01`,rr=await arm('PUT',path,payload);q.pimRequestId=rid;q.targetScheduleId=rr.properties?.targetRoleEligibilityScheduleId||null;q.pimStatus=rr.properties?.status||'Submitted';q.status='PROVISIONED';q.provisionedUtc=now();q.evidenceSha256=crypto.createHash('sha256').update(JSON.stringify({ticket:q.ticket,requestId:rid,schedule:q.targetScheduleId,principalId:process.env.DEMO_PRINCIPAL_ID,roleDefinitionId:process.env.PIM_ROLE_DEFINITION_ID,scope:process.env.TARGET_SCOPE})).digest('hex');save(d);return send(res,200,q)}return send(res,404,{error:'not found'})}catch(e){send(res,500,{error:e.message})}}).listen(port);
'@;[IO.File]::WriteAllText((Join-Path $root 'server.js'),$server,(New-Object Text.UTF8Encoding($false)));$zip=Join-Path $OutputRoot "Azure-Resource-PIM-ITSM-v2-Backend-${stamp}-${nonce}.zip";Compress-Archive "$root/*" $zip -Force;Log "Unique backend package created: $zip" OK;return $zip}
function Get-ExceptionDetail{
 param([System.Exception]$Exception)
 $items=New-Object System.Collections.Generic.List[string]
 $e=$Exception
 while($null -ne $e){$items.Add("$($e.GetType().FullName): $($e.Message)");if($e -is [AggregateException]){foreach($inner in $e.Flatten().InnerExceptions){$items.Add("Inner: $($inner.GetType().FullName): $($inner.Message)")}};$e=$e.InnerException}
 return ($items -join ' | ')
}
function Convert-TokenToPlainText{
 param($Token)
 if($Token -is [Security.SecureString]){$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token);try{return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}}
 return [string]$Token
}
function Invoke-ScmZipUpload{
 param([string]$Uri,[hashtable]$Headers,[string]$ZipPath)
 return Invoke-WebRequest -Uri $Uri -Method POST -Headers $Headers -InFile $ZipPath -ContentType 'application/zip' -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
}
function Wait-ScmDeployment{
 param($Response,[hashtable]$Headers,[string]$WebAppName)
 $location=[string](Prop $Response.Headers 'Location' $null)
 if([string]::IsNullOrWhiteSpace($location)){$location="https://$WebAppName.scm.azurewebsites.net/api/deployments/latest"}
 Log "SCM ZIP accepted. Monitoring: $location" STEP
 $deadline=(Get-Date).AddMinutes(10)
 do{
  Start-Sleep -Seconds 5
  try{$check=Invoke-RestMethod -Uri $location -Method GET -Headers $Headers -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop}catch{if((Get-Date)-ge$deadline){throw "SCM deployment status timeout: $(Get-ExceptionDetail $_.Exception)"};continue}
  $status=[int](Prop $check 'status' 0);$message=[string](Prop $check 'message' '')
  if($status -eq 4){Log "SCM ZIP deployment succeeded. $message" OK;return $check}
  if($status -eq 3){throw "SCM ZIP deployment failed: $message"}
  Log "SCM deployment status=$status $message" STEP
 }while((Get-Date)-lt$deadline)
 throw 'SCM deployment did not complete within 10 minutes.'
}
function Deploy-ZipByScm{
 param([string]$ResourceGroupName,[string]$WebAppName,[string]$ZipPath)
 Need-Connection
 if(-not(Test-Path $ZipPath)){throw "ZIP package not found: $ZipPath"}
 $base="https://$WebAppName.scm.azurewebsites.net"
 $uri="$base/api/zipdeploy?isAsync=true"
 # Preferred path: Microsoft Entra access token. No SCM Basic Auth or publishing password required.
 try{
  $tokenResponse=Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
  $aadToken=Convert-TokenToPlainText $tokenResponse.Token
  if([string]::IsNullOrWhiteSpace($aadToken)){throw 'Get-AzAccessToken returned an empty token.'}
  $aadHeaders=@{Authorization="Bearer $aadToken"}
  Log 'Trying SCM ZIP deployment with Microsoft Entra authentication.' STEP
  $aadResponse=Invoke-ScmZipUpload -Uri $uri -Headers $aadHeaders -ZipPath $ZipPath
  return (Wait-ScmDeployment -Response $aadResponse -Headers $aadHeaders -WebAppName $WebAppName)
 }catch{
  Log "Microsoft Entra SCM deployment was not accepted; controlled Basic Auth fallback will be used. Detail: $(Get-ExceptionDetail $_.Exception)" WARN
 }
 $policyPath="/subscriptions/$($script:State.SubscriptionId)/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$WebAppName/basicPublishingCredentialsPolicies/scm?api-version=2022-03-01"
 $credPath="/subscriptions/$($script:State.SubscriptionId)/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$WebAppName/config/publishingcredentials/list?api-version=2022-03-01"
 $basicEnabled=$false
 try{
  [void](Arm PUT $policyPath @{properties=@{allow=$true}});$basicEnabled=$true
  Log 'SCM Basic Auth temporarily enabled; waiting for policy propagation.' STEP
  $enabled=$false
  for($i=1;$i -le 6;$i++){
   Start-Sleep -Seconds 5
   try{$policy=Arm GET $policyPath;$enabled=[bool](Prop (Prop $policy 'properties' $policy) 'allow' $false)}catch{$enabled=$false}
   if($enabled){Log "SCM Basic Auth policy confirmed on attempt $i." OK;break}
  }
  if(-not$enabled){throw 'SCM Basic Auth policy did not become effective.'}
  $lastError=$null
  for($attempt=1;$attempt -le 6;$attempt++){
   try{
    $credResponse=Arm POST $credPath;$cp=Prop $credResponse 'properties' $credResponse
    $user=[string](Prop $cp 'publishingUserName' (Prop $cp 'PublishingUserName' $null));$pass=[string](Prop $cp 'publishingPassword' (Prop $cp 'PublishingPassword' $null))
    if([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($pass)){throw 'SCM publishing credentials were empty.'}
    $basicToken=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${user}:${pass}"));$basicHeaders=@{Authorization="Basic $basicToken"}
    # Authenticate before uploading the ZIP so a 401 can be retried without resending the package.
    [void](Invoke-WebRequest -Uri "$base/api/settings" -Method GET -Headers $basicHeaders -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop)
    Log "SCM Basic authentication verified on attempt $attempt." OK
    $basicResponse=Invoke-ScmZipUpload -Uri $uri -Headers $basicHeaders -ZipPath $ZipPath
    return (Wait-ScmDeployment -Response $basicResponse -Headers $basicHeaders -WebAppName $WebAppName)
   }catch{$lastError=Get-ExceptionDetail $_.Exception;Log "SCM Basic authentication/upload attempt $attempt failed: $lastError" WARN;if($attempt-lt6){Start-Sleep -Seconds 10}}
  }
  throw "SCM ZIP deployment failed after authentication retries: $lastError"
 }finally{
  if($basicEnabled){try{[void](Arm PUT $policyPath @{properties=@{allow=$false}});Log 'SCM Basic Auth disabled after deployment attempt.' OK}catch{Log "Could not disable SCM Basic Auth automatically: $($_.Exception.Message)" WARN}}
 }
}

function Deploy-Backend{
 Need-Connection
 Resolve-V2Objects
 if(-not $script:State.WebAppName){throw 'Run menu 5 first.'}
 $app=Get-AzWebApp -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName
 $settings=@{}
 foreach ($kv in $app.SiteConfig.AppSettings){$settings[$kv.Name]=$kv.Value}
 $settings['TARGET_SCOPE']=Target-Scope
 $settings['PIM_ROLE_NAME']=$script:State.TargetRoleName
 $settings['PIM_ROLE_DEFINITION_ID']=$script:State.RoleDefinitionResourceId
 $settings['DEMO_USER_UPN']=$script:State.TargetUserUpn
 $settings['DEMO_PRINCIPAL_ID']=$script:State.TargetUserObjectId
 $settings['APPROVER_UPNS']=$script:State.ApproverUpn
 $settings['ELIGIBILITY_DAYS']=[string]$script:State.EligibilityDays
 $settings['REQUIRE_AUTH']='true'
 $settings['WEBSITES_ENABLE_APP_SERVICE_STORAGE']='true'
 $settings['WEBSITE_NODE_DEFAULT_VERSION']='~20'
 $settings['SCM_DO_BUILD_DURING_DEPLOYMENT']='false'
 Set-AzWebApp -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName -AppSettings $settings|Out-Null
 Set-WebAppLinuxRuntime -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName
 $zip=New-BackendPackage
 Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
 $archive=$null
 try{
  $archive=[IO.Compression.ZipFile]::OpenRead($zip)
  $zipItems=@($archive.Entries|ForEach-Object{$_.FullName})
 }finally{
  if($null -ne $archive){$archive.Dispose()}
 }
 if($zipItems -notcontains 'server.js' -or $zipItems -notcontains 'package.json'){throw "Invalid backend ZIP root. Entries=$($zipItems -join ',')"}
 # Confirm that no validation file handle remains before SCM upload.
 $probe=$null
 try{$probe=[IO.File]::Open($zip,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)}catch{throw "Backend ZIP remains locked before upload: $($_.Exception.Message)"}finally{if($null -ne $probe){$probe.Dispose()}}
 [void](Deploy-ZipByScm -ResourceGroupName $script:State.PortalResourceGroupName -WebAppName $script:State.WebAppName -ZipPath $zip)
 Restart-AzWebApp -ResourceGroupName $script:State.PortalResourceGroupName -Name $script:State.WebAppName|Out-Null
 Log "Backend deployed and restarted: $($script:State.PortalUrl)" OK
}

function Verify-Backend{Need-Connection;Write-Host "Portal: $($script:State.PortalUrl)";Write-Host "MI Principal: $($script:State.ManagedIdentityPrincipalId)";Write-Host "Target: $(Target-Scope)";Write-Host "Target User: $($script:State.TargetUserUpn) [$($script:State.TargetUserObjectId)]";Write-Host "Approver: $($script:State.ApproverUpn)";Write-Host "Role: $($script:State.TargetRoleName)";Write-Host 'Browser E2E: request -> approver sign-in -> approve -> provision -> My roles activation.'}
function Inventory{Need-Connection;$scope=Target-Scope;$e=Arm GET "$scope/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=$($script:PimApi)";$a=Arm GET "$scope/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=$($script:PimApi)";$q=Arm GET "$scope/providers/Microsoft.Authorization/roleEligibilityScheduleRequests?api-version=$($script:PimApi)";$ev=@(Prop $e 'value' @());$av=@(Prop $a 'value' @());$qv=@(Prop $q 'value' @());Log "Inventory: Eligible=$($ev.Count), Active=$($av.Count), Requests=$($qv.Count)" OK;Ensure;$o=[pscustomobject]@{GeneratedUtc=Utc;Scope=$scope;Eligible=$ev;Active=$av;Requests=$qv};$p=Join-Path $OutputRoot "Inventory-$(Get-Date -Format yyyyMMdd-HHmmss).json";$o|ConvertTo-Json -Depth 40|Set-Content $p -Encoding UTF8;return $o}
function Evidence{Ensure;$d=Join-Path $OutputRoot "Evidence-$(Get-Date -Format yyyyMMdd-HHmmss)";[void](New-Item $d -ItemType Directory -Force);$script:State|ConvertTo-Json -Depth 30|Set-Content (Join-Path $d 'launcher-state.json') -Encoding UTF8;try{Inventory|ConvertTo-Json -Depth 40|Set-Content (Join-Path $d 'azure-pim-inventory.json') -Encoding UTF8}catch{$_.Exception.Message|Set-Content (Join-Path $d 'inventory-error.txt')};$manifest=foreach ($f in (Get-ChildItem $d -File)){$h=Get-FileHash $f.FullName -Algorithm SHA256;[pscustomobject]@{File=$f.Name;SHA256=$h.Hash;Bytes=$f.Length}};$manifest|Export-Csv (Join-Path $d 'SHA256-MANIFEST.csv') -NoTypeInformation -Encoding UTF8;$zip="$d.zip";Compress-Archive "$d/*" $zip -Force;$script:State.EvidenceFiles=@($script:State.EvidenceFiles)+$zip;Save-State;Log "Evidence: $zip" OK}
function Cleanup-Preview{[pscustomobject]@{TargetScope=(Target-Scope);ManagedIdentity=$script:State.ManagedIdentityPrincipalId;MiRoleAssignmentId=$script:State.MiRoleAssignmentId;PortalResourceGroup=$script:State.PortalResourceGroupName;OwnedPortalResourceGroup=$script:State.OwnedPortalResourceGroup;AuthAppId=$script:State.AuthAppId}|Format-List}
function Remove-TargetRg{
 Need-Connection
 if(-not $script:State.OwnedTargetResourceGroup){Log 'Target RG is not launcher-owned. Preserved.' WARN;return}
 if($script:State.ManagedIdentityPrincipalId){$miAssigned=@(Get-AzRoleAssignment -ObjectId $script:State.ManagedIdentityPrincipalId -Scope (Target-Scope) -ErrorAction SilentlyContinue);if($miAssigned.Count -gt 0){Log 'Managed Identity still has RBAC on Target RG. Run menu 91 first.' WARN;return}}
 if(-not(Exact "Delete launcher-owned V2 target RG '$($script:State.TargetResourceGroupName)'." 'DELETE-V2-TARGET-RG')){return}
 Remove-AzResourceGroup -Name $script:State.TargetResourceGroupName -Force -ErrorAction SilentlyContinue
 $script:State.OwnedTargetResourceGroup=$false;Save-State;Log 'V2 target RG deletion submitted.' OK
}
function Remove-MiRole{Need-Connection;if(-not$script:State.ManagedIdentityPrincipalId){return};if(-not(Exact 'Remove V2 Managed Identity scoped User Access Administrator.' 'REMOVE-V2-MI-RBAC')){return};Get-AzRoleAssignment -ObjectId $script:State.ManagedIdentityPrincipalId -Scope (Target-Scope) -RoleDefinitionName 'User Access Administrator' -ErrorAction SilentlyContinue|Remove-AzRoleAssignment -ErrorAction SilentlyContinue;$script:State.MiRoleAssignmentId=$null;Save-State;Log 'MI RBAC removed.' OK}
function Remove-Infra{Need-Connection;if(-not(Exact 'Delete V2 portal RG and V2 auth app registration. Target RG is preserved.' 'DELETE-V2-PORTAL-AUTH')){return};if($script:State.OwnedPortalResourceGroup){Remove-AzResourceGroup -Name $script:State.PortalResourceGroupName -Force -ErrorAction SilentlyContinue};if($script:State.AuthAppObjectId){Remove-AzADApplication -ObjectId $script:State.AuthAppObjectId -ErrorAction SilentlyContinue};Log 'V2 portal/auth cleanup submitted. Target RG preserved.' OK}
function Menu{Clear-Host;Write-Host '================================================================================';Write-Host ' Azure Resource PIM + Internal ITSM Portal v2.0.7 - FULL BACKEND EDITION';Write-Host ' Easy Auth | Managed Identity | ARM PIM API | Approval | Evidence Correlation';Write-Host '================================================================================';Write-Host '[P] Prerequisite check';Write-Host '[1] Architecture / security boundary';Write-Host '[2] Connect Azure';Write-Host '[3] Configure Target RG / User / Approver / Role';Write-Host '[4] Prepare/reuse Target RG and resolve objects';Write-Host '[5] Create App Service + System Managed Identity';Write-Host '[6] Create Entra App + Easy Auth';Write-Host '[7] Grant MI RG-scoped User Access Administrator';Write-Host '[8] Deploy Backend PIM API + ITSM Portal';Write-Host '[9] Show E2E portal / configuration';Write-Host '[10] Read-only Azure PIM inventory';Write-Host '[11] Export evidence ZIP + SHA-256';Write-Host '[13] Show state';Write-Host '[90] Cleanup preview';Write-Host '[91] Remove MI scoped RBAC';Write-Host '[92] Remove V2 Portal/Auth infra';Write-Host '[93] Remove launcher-owned V2 Target RG';Write-Host '[0] Exit';Write-Host "State: Sub=$($script:State.SubscriptionId); TargetRG=$($script:State.TargetResourceGroupName); WebApp=$($script:State.WebAppName)" -ForegroundColor DarkCyan}
Load-State
while($true){Menu;$c=Read-Host 'Select menu';try{switch($c){'P'{Test-Prereq;Pause-X}'p'{Test-Prereq;Pause-X}'1'{Show-Architecture;Pause-X}'2'{Connect-V2;Pause-X}'3'{Configure-V2;Pause-X}'4'{Ensure-TargetRg;Resolve-V2Objects;Pause-X}'5'{New-Infra;Pause-X}'6'{Set-EasyAuth;Pause-X}'7'{Grant-MiRole;Pause-X}'8'{Deploy-Backend;Pause-X}'9'{Verify-Backend;Pause-X}'10'{Inventory|Out-Null;Pause-X}'11'{Evidence;Pause-X}'13'{$script:State|ConvertTo-Json -Depth 30|Write-Host;Pause-X}'90'{Cleanup-Preview;Pause-X}'91'{Remove-MiRole;Pause-X}'92'{Remove-Infra;Pause-X}'93'{Remove-TargetRg;Pause-X}'0'{break}default{Log 'Invalid menu.' WARN;Pause-X}};if($c -eq '0'){break}}catch{Log $_.Exception.Message ERROR;if($_.ScriptStackTrace){Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray};Pause-X}}
