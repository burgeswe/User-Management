Import-Module ActiveDirectory

#Global Variables
$csvOutput = "C:\Scripts_Output\" #CSV Output Directory
$newUserCsv = Join-Path $csvOutput "userinfo.csv" #CSV that holds all individual user data
$newUserQueue = 'New User Queue' #AD Group that supplies new user accounts
$idpUrl = 'url of identity provider'
$forgotPwlink = 'url of forgot password link'
$serviceEmail = 'email of service desk'
$smtpServer = 'smtp server address'

#Poll AD for members of New Users Queue
$users = Get-ADGroupMember -Identity $newUserQueue | Where-Object objectclass -eq 'user' | Get-ADUser -Properties * | Select-Object Displayname, Givenname, Surname, sAMAccountName, userPrincipalName, distinguishedName, Enabled, EmployeeNumber, EmailAddress, Department, StreetAddress, Title, @{Name="ManagerEmail";Expression={(get-aduser -property emailaddress $_.manager).emailaddress}}

foreach ($user in $users)
{

#Generate random password
function Get-RandomCharacters($length, $characters) {
    $random = 1..$length | ForEach-Object { Get-Random -Maximum $characters.length }
    $private:ofs=""
    return [String]$characters[$random]
}
 
function Scramble-String([string]$inputString){     
    $characterArray = $inputString.ToCharArray()   
    $scrambledStringArray = $characterArray | Get-Random -Count $characterArray.Length     
    $outputString = -join $scrambledStringArray
    return $outputString 
}
 
$password = Get-RandomCharacters -length 4 -characters 'abcdefghkmnprstuvwxyz'
$password += Get-RandomCharacters -length 2 -characters 'ABCDEFGHKMNPRSTUVWXYZ'
$password += Get-RandomCharacters -length 1 -characters '123456789'
$password += Get-RandomCharacters -length 1 -characters '!&?@#'
$password = Scramble-String $password

Get-ADUser -Properties * | Select-Object Displayname, Givenname, Surname, sAMAccountName, userPrincipalName, distinguishedName, Enabled, EmployeeNumber, EmailAddress, Department, StreetAddress, Title, @{Name="ManagerEmail";Expression={(get-aduser -property emailaddress $_.manager).emailaddress}} | Export-Csv $newUserCsv -NoTypeInformation

#Sets account to never Expire, sets randomly generated password, exports info to csv for later
Set-ADuser -Identity $user.sAMAccountName -ChangePasswordAtLogon $false
Clear-ADAccountExpiration -Identity $user.sAMAccountName
Set-ADAccountPassword -Identity $user.sAMAccountName -Reset -NewPassword (ConvertTo-SecureString -AsPlainText $password -Force)

#Send Email to the personal email address of the user, as well as Will and Seth to let them know setup is complete

$EmailBody = @"
<h1>New Employee Account Activation:  $($user.Displayname)</h1>
This is an automated e-mail let you know that the account $($user.UserPrincipalName) has been created. 
<br />
The account password is:
<br /><br />
<h2>$($password)</h2>
You will need to register for Identity Management at $($idpUrl)
<br />
For this process you will need the Okta Verify App, or access to a mobile device for Multifactor Authentication
<br />
Okta Verify can be downloaded from the <a href="https://itunes.apple.com/ca/app/okta-verify/id490179405"> Apple App Store</a>or <a href="https://play.google.com/store/apps/details?id=com.okta.android.auth"> Google Play</a>
<br />
<h2><u>This user account is not completely set up!</u></h2>
<br />
<font color=blue><h2>Actions such as copying file share and distribution group membership from another user or setting up Office 365 licenses will need manual intervention</h2>
<br>
<font color=red><u><h2>At this time no further action will be taken without additional requests</h2></u></font>
<br />
<br /><br />
To reset the password after registration, the user can can use any computer on campus or go to $($forgotPwlink)
<br /><br />
If there are any issues with this account please put in a ticket at $($serviceEmail)
<br /><br />
Welcome!
<br /><br />
<i>Note:  This is an automated email.  Please don't reply, this address will not be monitored for correspondance</i>
"@

$FromAddress = ("")
$Subject = "New User Account - $($User.Displayname)"
$Recipients = @("")
#$Recipients = @("$($user.displayName) <$($user.EmailAddress)>")
$BccRecipients = @("")
$attachments = @("$newUserCsv")	
$Subject = "New User Onboarding - $($User.Displayname)"
$attachments = @("$newUserCsv")	

$EmailParameters = @{

    To = $Recipients
    Bcc = $BccRecipients
    From = $FromAddress
    Attachments = $attachments
    Subject = $Subject
    Body = $EmailBody
    BodyAsHtml = $true
    SmtpServer = $smtpServer
    Port = "25"
}

Send-MailMessage @EmailParameters

#Move users to Processed sub-OU
#Move-ADObject -Identity $user.distinguishedName -TargetPath "OU=Processed,OU=SubOU,DC=domain,DC=com"
#Remove users from New User Queue
Remove-ADGroupMember -Identity $newUserQueue -Members $user.sAMAccountName -Confirm:$false

}