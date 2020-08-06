Import-Module ActiveDirectory

#Global Variables
$Days = -1 # Variable to set account to expire in 'x' days
$expirationDate = (Get-Date).AddDays($Days) #Expiration date is today plus the number of days
$csvOutput = "C:\Scripts_Output\" #CSV Output Directory
$furloughedUserCsv = Join-Path $csvOutput "userinfo.csv" #CSV that holds all individual user data
$furloughedUserLicenses = Join-Path $csvOutput "licenses.csv" #CSV that holds all individual license data
$furloughedUserIntuneDevices = Join-Path $csvOutput "devices.csv" #CSV that holds all registered Intune Devices
$furloughedQueue = 'Furloughed Queue' #Temporary AD Group for processing Furloughed Users
$furloughedUsers = 'Furloughed Users' #Permanent AD Group that handles GPO Applicaiton and such
$supportEmail = 'support email address'
$smtpServer = 'smtp server address'

# Get the Service Principal connection details for the Connection name
$servicePrincipalConnection = Get-AutomationConnection -Name 'AzureRunAsConnection'
$credUser = "#username"
$credPass = ConvertTo-SecureString -String "#password" -AsPlainText -Force
$exchCred = New-Object -TypeName System.Management.Automation.PSCredential -Argumentlist ($credUser,$credPass)

#Log in to Azure AD with Credential
Connect-AzureAD -Credential $exchCred

#Connect MSOnline
Connect-MsolService -Credential $exchCred

#Log in to Exchange Online
Connect-ExchangeOnline -Credential $exchCred

#Log in to Sharepoint Online
Connect-SPOService -Url https://kimraycloud-admin.sharepoint.com -Credential $exchCred

#Log into Graph for Intune Management
Connect-MSGraph -Credential $exchCred

#Poll AD for members of Terminated Queue
$users = Get-ADGroupMember -Identity $furloughedQueue | Where-Object objectclass -eq 'user' | Get-ADUser -Properties * | Select-Object Displayname, Givenname, Surname, sAMAccountName, userPrincipalName, Enabled, EmployeeNumber, EmailAddress, telephonenumber, Department, StreetAddress, Title, @{Name="ManagerEmail";Expression={(get-aduser -property emailaddress $_.manager).emailaddress}} 

foreach ($user in $users)
{

#Grabs all important info from AD and creates a csv to attach in an email later
Get-ADUser -Identity $user.sAMAccountName  -Properties * | Select-Object Displayname, Givenname, Surname, sAMAccountName, userPrincipalName, Enabled, EmployeeNumber, EmailAddress, telephoneNumber, Department, StreetAddress, Title, @{Name="ManagerEmail";Expression={(get-aduser -property emailaddress $_.manager).emailaddress}} | Export-Csv $furloughedUserCsv -NoTypeInformation
#Sets Employees Expiration date as today - expirationDate
Set-ADUser -Identity $user.sAMAccountName -AccountExpirationDate $expirationDate

#If user has an extension add it to the email later
if ([string]::IsNullOrWhiteSpace($telephoneNumber))
    {
        $phoneWarn = 'The user has no extension'
    }
else 
    {
        $phoneWarn = "The user has an extension that will need to be monitored, $($telephoneNumber)"
    }

##Find the associated Azure AD account and remove all Azure AD refresh tokens from it - AzureAD
	Get-AzureADUser -ObjectId $user.userPrincipalName | Revoke-AzureADUserAllRefreshToken | Set-AzureADUser -AccountEnabled $false

##Disable access to ActiveSync, Outlook Mobile, and OWA for Mobile to prevent more email - Connect-ExchangeOnlineShell
    Set-CASMailbox $user.UserPrincipalName -OWAEnabled $false -OutlookMobileEnabled $false -OWAforDevicesEnabled $false -ActiveSyncEnabled $false -EwsEnabled $false -MAPIEnabled $false -ImapEnabled $false -PopEnabled $false
##Set mailbox as shared  - Connect-ExchangeOnlineShell
    Set-Mailbox -Identity $user.UserPrincipalName -Type shared
##Add Manager to Shared Mailbox - Connect-ExchangeOnlineShell
    Add-MailboxPermission -Identity $user.UserPrincipalName -User $user.ManagerEmail -AccessRights FullAccess
##Cancel Meetings started by the removed user - Connect-ExchangeOnlineShell
    Remove-CalendarEvents -Identity $user.UserPrincipalName -CancelOrganizedMeetings -QueryWindowInDays 1825 -confirm:$False

##Send Furloughed User's Manager a link to the employee's OneDrive - Connect-SPOService
    $onedrive = Get-SPOSite -IncludePersonalSite $True -Limit All -Filter "Url -like 'my.sharepoint.com/personal/'" | Where-Object {$_.Owner -eq $user.UserPrincipalName} | Select-Object -ExpandProperty Url
    Set-SPOUser -Site $onedrive -LoginName $user.ManagerEmail -IsSiteCollectionAdmin $True -ErrorAction SilentlyContinue

##Export all Azure Licenses for user to attach to email - AzureAD
    Get-AzureADUser -ObjectId $user.UserPrincipalName | Select-Object -ExpandProperty AssignedPlans | Export-Csv $furloughedUserLicenses -NoTypeInformation

##Export all Intune Registered devices to attach to email - Graph API for Intune
    Get-IntuneManagedDevice | Where-Object {$_.emailAddress -like $user.UserPrincipalName} | Export-Csv $furloughedUserIntuneDevices -NoTypeInformation

#Send Email to admins to let them know that the user task is complete
$EmailBody = @"
<h1>User Furloughed</h1>
This is an automated e-mail let you know that the account $($User.UserPrincipalName) has been furloghed. 
<br /><br />
Their mailbox has been converted to a shared mailbox and the manager $($user.ManagerEmail) has full access.  
<br /><br />
$($user.ManagerEmail) has also been assigned ownership of the OneDrive for Business of the account. Please navigate to the following URL : $($onedrive)
<br /><br />
A list of the users O365 licenses has been attached to this email, as well as the full list of Employee Details
<br />
Any devices the user had registered in Intune are also attached to this email for review
<br /><br />
The following actions have been taken:
<br /><br />
1.  The account password is no longer active
<br />
2.  The account has been disabled in AzureAD
<br />
3.  All Azure tokens have been revoked for current sessions
<br />
4.  The following services have been disabled in Exchange Online:  ActiveSync - Outlook Mobile - OWA - IMAP - POP
<br />
5.  All active calendar events created on the account in the last 5 years have been cancelled
<br />
6.  The mailbox for the account has been converted to shared and the users manager has full access
<br />
7.  The personal OneDrive site for the user has had its security reset and $($user.ManagerEmail) has full access to it for the next 30 days before it archives
<br /><br />
<font color ="red"><h2> The user account is still present!  Additional steps will happen if their status changes.</h2></font>
<br /><br />
<font color="blue">
$($phoneWarn)
</font>
<br /><br />
If there are any issues with this account after this please put in a ticket at $($supportEmail)
<br /><br />
Thank you,
<br /><br />
IT Department
<br /><br />
<i>Note:  This is an automated email.  Please don't reply, this address may not be monitored for correspondence</i>
<br />
"@

#Email Variables
$FromAddress = ("")
$Recipients = @("")
$BccRecipients = @("")

$EmailParameters = @{

    To = $Recipients
    Bcc = $BccRecipients
    From = $FromAddress
    Attachments = @("$furloughedUserCsv", "$furloughedUserLicenses", "$furloughedUserIntuneDevices")	
    Subject = "User Furloughed: $($User.Displayname)"
    Body = $EmailBody
    BodyAsHtml = $true
    SmtpServer = $smtpServer
    Port = "25"
}

Send-MailMessage @EmailParameters

#Move users from Furloughed Queue to Furloughed Users Security Group
Remove-ADGroupMember -Identity $furloughedQueue -Members $user.sAMAccountName -Confirm:$false
Add-ADGroupMember -Identity $furloughedUsers -Members $user.sAMAccountName -Confirm:$false

}