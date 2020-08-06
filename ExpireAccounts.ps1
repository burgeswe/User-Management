#requires -Modules ActiveDirectory

# Ask for username input
$user = Read-Host -Prompt 'Input the user name'

# Variable to set account to expire in 'x' days
$Days = -1

# expiration date is today plus or minus the number of days
$expirationDate = (Get-Date).AddDays($Days)

Set-ADUser -Identity $user -AccountExpirationDate $expirationDate