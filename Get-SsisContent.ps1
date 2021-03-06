﻿<#
.Synopsis
   Extract Task and component information from SSIS (dtsx) files.
.DESCRIPTION
   The purpose of this cmdlet is to extract information regarding tasks and components from
   SSIS files (dtsx). The information can be used for statistical analysis or when you need to
   search for some components in a set of SSIS files.
.EXAMPLE
   Get-ChildItem -Path C:\work\release\etl *.dtsx -Recurse | get-SsisContent | Sort-Object Category, ComponentType | Group-Object Category, ComponentType  | Select-Object Name, Count | Format-Table -AutoSize

   Name                                                          Count
   ----                                                          -----
   Data Flow Component, Aggregate                                    6
   Data Flow Component, Checksum Transformation                     94
   Data Flow Component, Conditional Split                          308
   Data Flow Component, Copy Column                                  4
   Data Flow Component, Data Conversion                             31
   Data Flow Component, Derived Column                            1430
   Data Flow Component, Executes a custom script.                   15
   Data Flow Component, Extracts data from a raw file.              15
   Data Flow Component, Flat File Destination                        6
   Data Flow Component, Flat File Source                           185
   Data Flow Component, http://ssismhash.codeplex.com/               5
   Data Flow Component, Kimball Method Slowly Changing Dimension    22
   Data Flow Component, Lookup                                     614
   Data Flow Component, Merge                                        1
   Data Flow Component, Merge Join                                   6
   Data Flow Component, Multicast                                   20
   Data Flow Component, OLE DB Command                              97
   Data Flow Component, OLE DB Destination                         573
   Data Flow Component, OLE DB Source                              356
   Data Flow Component, Recordset Destination                       22
   Data Flow Component, Row Count                                  603
   Data Flow Component, Slowly Changing Dimension                   11
   Data Flow Component, Sort                                        24
   Data Flow Component, Union All                                  218
   Task, Data Flow Task                                            436
   Task, Execute Package Task                                      937
   Task, Execute Process Task                                        3
   Task, Execute SQL Task                                         1247
   
   (What kind of components does the SSIS files contain and how many in total)

.EXAMPLE

   Get-ChildItem -Path C:\work\release\etl *.dtsx -Recurse | get-SsisContent | Where-Object { $_.ComponentType -eq  'Kimball Method Slowly Changing Dimension' } | Select-Object FileName, TaskName | Format-List *

   FileName : {C:\work\release\etl\File1.dtsx}
   TaskName : DFT - Load Person

   FileName : {C:\work\release\etl\File1.dtsx}
   TaskName : DFT - Load Branch

   FileName : {C:\work\release\etl\File2.dtsx}
   TaskName : DFT - Load counterparty

   (Which SSIS files uses the "Kimball Method Slowly Changing Dimension" component?)

.OUTPUTS
SsisTools.SsisContent
- FileName = Name of the file
- Category = Task, Data flow component, Variable, Package Configuration or Connection
- TaskName = Name of the task in the Control flow
- ComponentName = Name of the component in the Data Flow Task. Taskname for Control flow tasks
- ComponentType = Type of component, e.g "OLE DB Source"
#>
function Get-SsisContent
{
    [CmdletBinding(SupportsShouldProcess=$false, 
                  PositionalBinding=$false)]
     
    [OutputType('SsisTools.SsisContent')]

    Param
    (

        <#
          File names to search. Only *.dtsx files are queried, others are ignored.
          This parameter can be Pipelined to the script, e.g by Get-ChildItem.
        #>
        [Parameter(Mandatory,
                   ValueFromPipeline,
                   ValueFromPipelineByPropertyName,
                   ValueFromRemainingArguments=$false,
                   Position=0)]
        [ValidateScript({Test-path $_})]
        [Alias("FileName", "FullName")]
        [String[]]$Path,

        <#
        { "All", "Task", "Package configuration", "Connection", "Variable", "Data Flow Component" }
   
        What kind of categories should be queried?
        #>
        [ValidateSet("All", "Task", "Package configuration", "Connection", "Variable", "Data Flow Component")]
        [string[]]$Category = "All"

    )

    Begin
    {
    }

    Process
    {

        # Private functions used in processing

        function shouldProcess
        {
            Param(
                [string[]]$categories,
                [string]$category
            )

            ($categories -contains $category -or $categories -contains "All")
        }


        function writeContentObject
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Position=2)]
                [string]$taskName,

                [Parameter(Position=3)]
                [string]$category,

                [Parameter(Position=4)]
                [string]$componentType,

                [Parameter(Position=5)]
                [string]$componentName
            )

            $prop = @{
                'FileName'=$fileName
                'Category'=$category
                'ComponentType'=$componentType
                'TaskName'=$taskName
                'ComponentName'=$componentName
            }
            $obj=New-Object -TypeName PSObject -Property $prop
            $obj.PSObject.TypeNames.Insert(0,’SsisTools.SsisContent’)
            Write-Output $obj
        }


        function ExtractTasks2008
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )

            $xml.SelectNodes("/DTS:Executable//DTS:Executable/DTS:Property[@DTS:Name='ObjectName']", $ns) | ForEach-Object {
                $taskName = $_.InnerText
                $taskContact = $_.SelectSingleNode("../DTS:Property[@DTS:Name='TaskContact']", $ns).InnerText
                $taskDescription = $_.SelectSingleNode("../DTS:Property[@DTS:Name='Description']", $ns).InnerText
                $executableType = $_.SelectSingleNode("../@DTS:ExecutableType", $ns).Value.ToString()

                [System.Xml.xmlElement]$taskExecutePackageTaskObjectData = $_.SelectSingleNode("../DTS:ObjectData/ExecutePackageTask", $ns)

                if ($taskExecutePackageTaskObjectData -ne $null) {
                    $taskType = "Execute Package Task"
                }
                elseif ($executableType -eq "STOCK:SEQUENCE") {
                    $taskType = "Sequence Container"
                }
                elseif ($executableType -eq "STOCK:FOREACHLOOP") {
                    $taskType = "For each loop"
                }
                # Some task have bad contact info - use Description for these
                elseif ($taskDescription -in ("Data Flow Task", "Script Task", "Foreach Loop Container") -or $taskContact -like "Microsoft*" ) {
                    $taskType = $taskDescription
                }
                else {
                    $taskType = ($taskContact -split ";")[0]
                }

                writeContentObject $fileName $taskName 'Task' $taskType $taskName
            }
        }


        function ExtractTasks2014
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )

            $xml.SelectNodes("/DTS:Executable//DTS:Executable", $ns) | ForEach-Object {
                $taskName = $_.GetAttribute("DTS:ObjectName")
                $taskContact = $_.GetAttribute("DTS:TaskContact")
                $taskDescription = $_.GetAttribute("DTS:Description")
                $executableType = $_.GetAttribute("DTS:ExecutableType")

                [System.Xml.xmlElement]$taskExecutePackageTaskObjectData = $_.SelectSingleNode("DTS:ObjectData/ExecutePackageTask", $ns)

                if ($taskExecutePackageTaskObjectData -ne $null) {
                    $taskType = "Execute Package Task"
                }
                elseif ($executableType -eq "STOCK:SEQUENCE") {
                    $taskType = "Sequence Container"
                }
                elseif ($executableType -eq "STOCK:FOREACHLOOP") {
                    $taskType = "For each loop"
                }
                elseif ($executableType -eq "Microsoft.ScriptTask") {
                    $taskType = "Script Task"
                }
                # Some task have bad contact info - use Description for these
                elseif ($taskDescription -in ("Data Flow Task", "Script Task", "Foreach Loop Container") -or $taskContact -like "Microsoft*" ) {
                    $taskType = $taskDescription
                }
                else {
                    $taskType = ($taskContact -split ";")[0]
                }

                writeContentObject $fileName $taskName 'Task' $taskType $taskName
            }
        }


        function ExtractVariables2008
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )

            $xml.SelectNodes("//DTS:Variable/DTS:Property[@DTS:Name='Namespace' and text() != 'System']/..", $ns) | ForEach-Object {
                $variableName = $_.SelectSingleNode("DTS:Property[@DTS:Name='ObjectName']", $ns).InnerText
                $namespace = $_.SelectSingleNode("DTS:Property[@DTS:Name='Namespace']", $ns).InnerText

                writeContentObject $fileName $variableName 'Variable' "${namespace}Variable" $variableName
            }
        }


        function ExtractVariables2014
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )

            $xml.SelectNodes("//DTS:Variables/DTS:Variable[@DTS:Namespace != 'System']", $ns) | ForEach-Object {
                $variableName = $_.GetAttribute("DTS:ObjectName")
                $namespace = $_.GetAttribute("DTS:Namespace")

                writeContentObject $fileName $variableName 'Variable' "${namespace}Variable" $variableName
            }
        }


        function ExtractConfigurations2008
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )

            $xml.SelectNodes("//DTS:Configuration/DTS:Property[@DTS:Name='ConfigurationString']/..", $ns) | ForEach-Object {
                $configurationString = $_.SelectSingleNode("DTS:Property[@DTS:Name='ConfigurationString']", $ns).InnerText
                $configurationName = $_.SelectSingleNode("DTS:Property[@DTS:Name='ObjectName']", $ns).InnerText
                $configurationTypeInt = $_.SelectSingleNode("DTS:Property[@DTS:Name='ConfigurationType']", $ns).InnerText

                $configurationType = switch ($configurationTypeInt) {
                    0 {"Parent package variable"}
                    2 {"Environment variable"}
                    5 {"Indirect XML configuration file"}
                    default {"Unknown $configurationTypeInt"}
                }

                writeContentObject $fileName $configurationName 'Package configuration' $configurationType $configurationString
            }
        }


        function ExtractConfigurations2014
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )

            $xml.SelectNodes("//DTS:Configuration", $ns) | ForEach-Object {
                $configurationString = $_.GetAttribute("DTS:ConfigurationString")
                $configurationName = $_.GetAttribute("DTS:ObjectName")
                $configurationTypeInt = $_.GetAttribute("DTS:ConfigurationType")

                if ($configurationTypeInt -eq "") {
                    # The ConfigurationType 0 seems to be removed in SSIS 2014.
                    $configurationTypeInt = 0
                }

                $configurationType = switch ($configurationTypeInt) {
                    0 {"Parent package variable"}
                    2 {"Environment variable"}
                    5 {"Indirect XML configuration file"}
                    default {"Unknown $configurationTypeInt"}
                }

                writeContentObject $fileName $configurationName 'Package configuration' $configurationType $configurationString
            }
        }


        function ExtractConnections2008
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )

            $xml.SelectNodes("/DTS:Executable/DTS:ConnectionManager", $ns) | ForEach-Object {
                $connectionName = $_.SelectSingleNode("DTS:Property[@DTS:Name='ObjectName']", $ns).InnerText
                # FILE, FLATFILE, FTP, OLE DB
                $creationName = $_.SelectSingleNode("DTS:Property[@DTS:Name='CreationName']", $ns).InnerText

                writeContentObject $fileName $connectionName 'Connection' $creationName $connectionName
            }
        }


        function ExtractConnections2014
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )


            $xml.SelectNodes("/DTS:Executable/DTS:ConnectionManagers/DTS:ConnectionManager", $ns) | ForEach-Object {
                $connectionName = $_.GetAttribute("DTS:ObjectName")
                # FILE, FLATFILE, FTP, OLE DB
                $creationName = $_.GetAttribute("DTS:CreationName")

                writeContentObject $fileName $connectionName 'Connection' $creationName $connectionName
            }
        }


        function ExtractDataFlowComponents2008
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )

            $xml.SelectNodes("//components/component", $ns) | ForEach-Object {
                $componentName = $_.SelectSingleNode("@name", $ns).Value.ToString()
                $componentDescription = $_.SelectSingleNode("@description", $ns).Value.ToString()
                $taskName = $_.SelectSingleNode("../../../../DTS:Property[@DTS:Name='ObjectName']", $ns).InnerText
                $contactInfo = $_.SelectSingleNode("@contactInfo", $ns).Value.ToString()

                $componentType = ($contactInfo -split ";")[0]
                if ($componentType -eq "") {
                    $componentType = $ComponentDescription
                }

                # Still no component type? Use Component name (Kimball SCD)
                if ($componentType -eq "") {
                   $componentType = $componentName
                }

                writeContentObject $fileName $taskName 'Data Flow Component' $componentType $componentName
            }
        }


        function ExtractDataFlowComponents2014
        {
            Param(
                [Parameter(Position=1)]
                [string]$fileName,

                [Parameter(Mandatory, Position=2)]
                [xml]$xml,

                [Parameter(Mandatory, Position=3)]
                [Xml.XmlNamespaceManager]$ns
            )

            $xml.SelectNodes("//components/component", $ns) | ForEach-Object {
                $componentName = $_.SelectSingleNode("@name", $ns).Value.ToString()
                $componentDescription = $_.GetAttribute("description")
                $dftTask = $_.SelectSingleNode("../../../..")
                $taskName = $dftTask.GetAttribute("DTS:ObjectName")
                $contactInfo = $_.GetAttribute("contactInfo")

                $componentType = ($contactInfo -split ";")[0]
                if ($componentType -eq "") {
                    $componentType = $ComponentDescription
                }

                # Still no component type? Use Component name (Kimball SCD)
                if ($componentType -eq "") {
                    $componentType = $componentName
                }

                writeContentObject $fileName $taskName 'Data Flow Component' $componentType $componentName
            }
        }


        if ($Path -like "*.dtsx") {
            Write-Verbose "File: $Path"

            [xml]$xml = Get-Content -Path $Path

            $ns = new-object Xml.XmlNamespaceManager ($xml.NameTable)
            $ns.AddNamespace("SQLTask", "www.microsoft.com/sqlserver/dts/tasks/sqltask")
            $ns.AddNamespace("DTS", "www.microsoft.com/SqlServer/Dts")

            $PackageFormatVersion = $xml.SelectSingleNode("/DTS:Executable/DTS:Property[@DTS:Name='PackageFormatVersion']", $ns).InnerText

            if ($PackageFormatVersion -notin ("3", "8")) {
                Write-Verbose "Warning: $Path has unsupported PackageFormatVersion: ${PackageFormatVersion}. Ignoring file"
            }
            else {

                # Control flow tasks
                if (shouldProcess $Category 'Task') {
                    switch ($PackageFormatVersion) {
                        "3" {ExtractTasks2008 $Path[0] $xml $ns}
                        "8" {ExtractTasks2014 $Path[0] $xml $ns}
                        default {}
                    }
                }


                # Variables
                if (shouldProcess $Category 'Variable') {
                    switch ($PackageFormatVersion) {
                        "3" {ExtractVariables2008 $Path[0] $xml $ns}
                        "8" {ExtractVariables2014 $Path[0] $xml $ns}
                        default {}
                    }
                }

                # Configurations
                if (shouldProcess $Category 'Package configuration') {
                    switch ($PackageFormatVersion) {
                        "3" {ExtractConfigurations2008 $Path[0] $xml $ns}
                        "8" {ExtractConfigurations2014 $Path[0] $xml $ns}
                        default {}
                    }
                }


                # Connections
                if (shouldProcess $Category 'Connection') {
                    switch ($PackageFormatVersion) {
                        "3" {ExtractConnections2008 $Path[0] $xml $ns}
                        "8" {ExtractConnections2014 $Path[0] $xml $ns}
                        default {}
                    }
                }


                # Data flow components
                if (shouldProcess $Category 'Data Flow Component') {
                    switch ($PackageFormatVersion) {
                        "3" {ExtractDataFlowComponents2008 $Path[0] $xml $ns}
                        "8" {ExtractDataFlowComponents2014 $Path[0] $xml $ns}
                        default {}
                    }
                }
            }
        }
        else {
            Write-Verbose "File $Path is not a dtsx file"
        }
    }

    End
    {
    }
}
