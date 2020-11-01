﻿<# 
 .Synopsis
  Restore Business Central Database(s) from artifacts
 .Description
  Restore Business Central Databases to an external SQL Server from articacts.
  Windows Authentication to the SQL Server is required.
 .Parameter artifactUrl
  Url for application artifact to use for locating database .bak file
 .Parameter databaseServer
  database Server on which you want to restore the database(s)
 .Parameter databaseInstance
  database Instance on the database Server on which you want to restore the database(s)
 .Parameter databasePrefix
  database prefix to avoid conflicts on the SQL Server
 .Parameter databaseName
  database name (prefix will be inserted before the name) on the SQL Server.
 .Parameter multitenant
  Include this switch if you want to split the database .bak file into an application database and a tenant template
 .Parameter async
  Include this parameter if you want to restore the database asynchronous. A file called <databasePrefix>databasescreated.txt will be created in the containerhelper folder when done
#>
function Restore-BcDatabaseFromArtifacts {
    Param(
        [Parameter(Mandatory=$true)]
        [string] $artifactUrl,
        [Parameter(Mandatory=$true)]
        [string] $databaseServer,
        [Parameter(Mandatory=$false)]
        [string] $databaseInstance = "",
        [Parameter(Mandatory=$false)]
        [string] $databasePrefix = "",
        [Parameter(Mandatory=$true)]
        [string] $databaseName,
        [Parameter(Mandatory=$false)]
        [switch] $multitenant,
        [switch] $async
    )

    if ($databaseServer -eq 'host.containerhelper.internal') {
        $databaseServer = 'localhost'
    }
    $successFileName = ""
    if ($async) {
        $successFileName = Join-Path $bcContainerHelperConfig.hostHelperFolder "$($databasePrefix)databasescreated.txt"
        if (Test-Path $successFileName) { Remove-Item $successFileName -Force }
    }
    Write-Host "Starting Database Restore job from $($artifactUrl.split('?')[0])"
    $job = Start-Job -ScriptBlock { Param( $artifactUrl, $databaseServer, $databaseInstance, $databasePrefix, $databaseName, $multitenant, $successFileName )
        Write-Host "Downloading Artifacts $($artifactUrl.Split('?')[0])"
        $artifactPath = Download-Artifacts $artifactUrl -includePlatform
        
        $ManagementModule = Get-Item -Path (Join-Path $artifactPath[1] "ServiceTier\program files\Microsoft Dynamics NAV\*\Service\Microsoft.Dynamics.Nav.Management.psm1")
        if (!($ManagementModule)) {
            throw "Unable to locate management module in artifacts"
        }
        
        $manifest = Get-Content -Path (Join-Path $artifactPath[0] "manifest.json") | ConvertFrom-Json
        $databasePath = Join-Path $artifactPath[0] $manifest.database
        if (!(Test-Path $databasePath)) {
            throw "Unable to locate database in artifacts"
        }
        
        Write-Host "Importing PowerShell module $($ManagementModule.FullName)"
        Import-Module $ManagementModule.FullName

        $databaseServerInstance = $databaseServer
        if ($databaseInstance) {
            $databaseServerInstance += "\$databaseInstance"
        }
        Import-Module sqlps
        $smoServer = New-Object Microsoft.SqlServer.Management.Smo.Server $databaseServerInstance

        $dbName = "$databasePrefix$databaseName"
        if ($multitenant) {
            $dbName = "$($databasePrefix)tenant"
        }
        Write-Host "Restoring database $dbName"
        New-NAVDatabase -DatabaseServer $databaseServer -DatabaseInstance $databaseInstance -DatabaseName $dbName -FilePath $databasePath -DestinationPath (Join-Path $smoServer.RootDirectory "DATA\$($databaseprefix -replace '[^a-zA-Z0-9]', '')") | Out-Null
   
        if ($multitenant) {
            $Smo = [reflection.assembly]::Load("Microsoft.SqlServer.Smo, Version=$($smoServer.VersionMajor).$($smoServer.VersionMinor).0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91")
            $SmoExtended = [reflection.assembly]::Load("Microsoft.SqlServer.SmoExtended, Version=$($smoServer.VersionMajor).$($smoServer.VersionMinor).0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91")
            $ConnectionInfo = [reflection.assembly]::Load("Microsoft.SqlServer.ConnectionInfo, Version=$($smoServer.VersionMajor).$($smoServer.VersionMinor).0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91")
            $SqlEnum = [reflection.assembly]::Load("Microsoft.SqlServer.SqlEnum, Version=$($smoServer.VersionMajor).$($smoServer.VersionMinor).0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91")
            
            $OnAssemblyResolve = [System.ResolveEventHandler] {
                param($sender, $e)
                if ($e.Name -like "Microsoft.SqlServer.Smo, Version=*, Culture=neutral, PublicKeyToken=89845dcd8080cc91") { return $Smo }
                if ($e.Name -like "Microsoft.SqlServer.SmoExtended, Version=*, Culture=neutral, PublicKeyToken=89845dcd8080cc91") { return $SmoExtended }
                if ($e.Name -like "Microsoft.SqlServer.ConnectionInfo, Version=*, Culture=neutral, PublicKeyToken=89845dcd8080cc91") { return $ConnectionInfo }
                if ($e.Name -like "Microsoft.SqlServer.SqlEnum, Version=*, Culture=neutral, PublicKeyToken=89845dcd8080cc91") { return $SqlEnum }
                foreach($a in [System.AppDomain]::CurrentDomain.GetAssemblies()) {
                    if ($a.FullName -eq $e.Name) { return $a }
                }
                return $null
            }
            [System.AppDomain]::CurrentDomain.add_AssemblyResolve($OnAssemblyResolve)
            
            Write-Host "Exporting Application to $databasePrefix$databaseName"
            Export-NAVApplication `
                -DatabaseServer $databaseServer `
                -DatabaseInstance $databaseInstance `
                -DatabaseName "$($databasePrefix)tenant" `
                -DestinationDatabaseName "$databasePrefix$databaseName" `
                -Force | Out-Null
            
            Write-Host "Removing Application from $($databasePrefix)tenant"
            Remove-NAVApplication `
                -DatabaseServer $databaseServer `
                -DatabaseInstance $databaseInstance `
                -DatabaseName "$($databasePrefix)tenant" `
                -Force | Out-Null
        }
        Write-Host "Success"
        if ($successFileName) {
            Set-Content -Path $successFileName -Value "Success"
        }
    } -ArgumentList $artifactUrl, $databaseServer, $databaseInstance, $databasePrefix, $databaseName, $multitenant, $successFileName

    if (!$async) {
        While ($job.State -eq "Running") {
            Start-Sleep -Seconds 1
            $job | Receive-Job
        }
        $job | Receive-Job
    }
}
Export-ModuleMember -Function Restore-BcDatabaseFromArtifacts
