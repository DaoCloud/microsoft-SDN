Param(
    [parameter(Mandatory = $true)] $ManagementIP,
    [parameter(Mandatory = $true)] $ControllerIP,
    [ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] [parameter(Mandatory = $false)] $NetworkMode="l2bridge",
    [parameter(Mandatory = $false)] $ClusterCIDR="172.28.0.0/16",
    [parameter(Mandatory = $false)] $KubeDnsServiceIP="10.96.0.2",
    [parameter(Mandatory = $false)] $ServiceCIDR="10.96.0.0/12",
    [parameter(Mandatory = $false)] $InterfaceName="Ethernet",
    [parameter(Mandatory = $false)] $LogDir = "C:\logs",
    [parameter(Mandatory = $false)] $DeployAsService = $false,
    [parameter(Mandatory = $false)] $KubeletSvc="kubelet",
    [parameter(Mandatory = $false)] $KubeProxySvc="kube-proxy",
    [parameter(Mandatory = $false)] $FlanneldSvc="flanneld",
    [parameter(Mandatory = $false)] $KubeletFeatureGates = ""
)

$NetworkMode = $NetworkMode.ToLower()
$NetworkName = "cbr0"

$ScriptsDir = "c:\k\scripts"
$GithubSDNRepository = 'microsoft-SDN'
if ((Test-Path env:GITHUB_SDN_REPOSITORY) -and ($env:GITHUB_SDN_REPOSITORY -ne ''))
{
    $GithubSDNRepository = $env:GITHUB_SDN_REPOSITORY
}

if ($NetworkMode -eq "overlay")
{
    $NetworkName = "vxlan0"
}

if (!(Test-Path $LogDir))
{
    mkdir $LogDir
}

$env:path += ";c:\k\utils;c:\k\dce;"
$newPath = "c:\k\utils;c:\k\dce;" +[Environment]::GetEnvironmentVariable("PATH",[EnvironmentVariableTarget]::Machine)
[Environment]::SetEnvironmentVariable("PATH", $newPath,[EnvironmentVariableTarget]::Machine)


# generate dce-engine config
dce-engine config --controller_addr $ControllerIP --management_ip $ManagementIP

# Use helpers to setup binaries, conf files etc.
$helper = "$ScriptsDir\helper.psm1"
if (!(Test-Path $helper))
{
    Start-BitsTransfer "https://raw.githubusercontent.com/$GithubSDNRepository/master/Kubernetes/windows/helper.psm1" -Destination "$helper"
}
ipmo $helper

$install = "$ScriptsDir\install.ps1"
if (!(Test-Path $install))
{
    Start-BitsTransfer "https://raw.githubusercontent.com/$GithubSDNRepository/master/Kubernetes/windows/install.ps1" -Destination "$install"
}

# Download files, move them, & prepare network
powershell $install -NetworkMode $NetworkMode -clusterCIDR $ClusterCIDR -KubeDnsServiceIP $KubeDnsServiceIP -serviceCIDR $ServiceCIDR -InterfaceName $InterfaceName -LogDir $LogDir

# Register node
powershell $ScriptsDir\start-kubelet.ps1 -RegisterOnly -NetworkMode $NetworkMode
ipmo $ScriptsDir\hns.psm1

Start-Sleep 10

start powershell $ScriptsDir\InstallImages.ps1

if($DeployAsService){
    $registersceArgs = @(
        "$ScriptsDir\register-svc.ps1"
        "-ManagementIP $ManagementIP"
        "-NetworkMode $NetworkMode"
        "-ClusterCIDR $ClusterCIDR"
        "-KubeDnsServiceIP $KubeDnsServiceIP"
        "-LogDir $LogDir"
        "-KubeletSvc $KubeletSvc"
        "-KubeProxySvc $KubeProxySvc"
        "-FlanneldSvc $FlanneldSvc"
    )
    start powershell -ArgumentList  " -File  $registersceArgs "
    if ($NetworkMode -eq "overlay")
    {
        GetSourceVip -ipAddress $ManagementIP -NetworkName $NetworkName
    }
    Start-Sleep 5

    echo 'add smb drivers to kubelet-plugins dirctories'
    
    $max_try_count = 5
    while ($max_try_count -gt 0) {
        # 添加 smb 存储驱动到指定目录,如果'C:\usr\libexec\kubernetes\kubelet-plugins\volume\exec\' 不存在，说明kubelet还没有准备好，重试几次
        if(Test-Path 'C:\usr\libexec\kubernetes\kubelet-plugins\volume\exec\'){
            mv c:\k\smb_driver\* C:\usr\libexec\kubernetes\kubelet-plugins\volume\exec\
            exit
        }else {
            if($max_try_count==1){
                throw ("The kubelet plugins dir is not exist, please check the kubelet and copy smb drivers manual")
                exit
            }
            echo "waiting the kubelet create the plugins dir -------------$max_try_count"
            Start-Sleep (6 - $max_try_count) * 2
            $max_try_count -= 1
        }
    }

    
}

# Start Infra services
# Start Flanneld
StartFlanneld -ipaddress $ManagementIP -NetworkName $NetworkName
Start-Sleep 1
if ($NetworkMode -eq "overlay")
{
    GetSourceVip -ipAddress $ManagementIP -NetworkName $NetworkName
}

# Start kubelet
$startKubeletArgs = "-File $ScriptsDir\start-kubelet.ps1 -NetworkMode $NetworkMode -KubeDnsServiceIP $KubeDnsServiceIP -LogDir $LogDir"
if ($KubeletFeatureGates -ne "")
{
    $startKubeletArgs += " -KubeletFeatureGates $KubeletFeatureGates"
}
Start powershell -ArgumentList $startKubeletArgs
Start-Sleep 10

# Start kube-proxy
start powershell -ArgumentList " -File $ScriptsDir\start-kubeproxy.ps1 -NetworkMode $NetworkMode -clusterCIDR $ClusterCIDR -NetworkName $NetworkName -LogDir $LogDir"
