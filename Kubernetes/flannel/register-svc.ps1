Param(
    [parameter(Mandatory = $true)] $ManagementIP,
    [ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] $NetworkMode="l2bridge",
    [parameter(Mandatory = $false)] $ClusterCIDR="10.244.0.0/16",
    [parameter(Mandatory = $false)] $KubeDnsServiceIP="10.96.0.10",
    [parameter(Mandatory = $false)] $LogDir="C:\k\logs",
    [parameter(Mandatory = $false)] $KubeletSvc="kubelet",
    [parameter(Mandatory = $false)] $KubeProxySvc="kube-proxy",
    [parameter(Mandatory = $false)] $KubeletFeatureGates="",
    [parameter(Mandatory = $false)] $NetworkName="cbr0",
    [parameter(Mandatory = $false)] $FlanneldSvc="flanneld",
    [parameter(Mandatory = $false)] $DceEngineSvc="dce-engine",
    [parameter(Mandatory = $false)] $ScriptsDir = "c:\k\scripts",
    [parameter(Mandatory = $false)] $KubernetessDir = "c:\k\kubernetes",
    [parameter(Mandatory = $false)] $CnidDir = "c:\k\cni",
    [parameter(Mandatory = $false)] $KubeConfigsDir = "c:\k\kubernetes\configs",
    [parameter(Mandatory = $false)] $NssmDir = "c:\k\utils"
)

$helper = "$ScriptsDir\helper.psm1"
ipmo $helper

$Hostname=$(hostname).ToLower()
$NetworkMode = $NetworkMode.ToLower()
cd $NssmDir

# register flanneld
CleanupOldNetwork -NetworkName $NetworkName

.\nssm.exe install $FlanneldSvc $CnidDir\flanneld.exe
.\nssm.exe set $FlanneldSvc AppParameters --kubeconfig-file=$KubeConfigsDir\config --iface=$ManagementIP --ip-masq=1 --kube-subnet-mgr=1
.\nssm.exe set $FlanneldSvc AppEnvironmentExtra NODE_NAME=$Hostname
.\nssm.exe set $FlanneldSvc AppDirectory $CnidDir
.\nssm.exe set $FlanneldSvc AppStdout $LogDir\$FlanneldSvc.log
.\nssm.exe set $FlanneldSvc AppStderr $LogDir\$FlanneldSvc.log
.\nssm.exe start $FlanneldSvc

Start-Sleep 2

WaitForNetwork -NetworkName $NetworkName


Start-Sleep 2

if ($NetworkMode -eq "overlay")
{
    GetSourceVip -ipAddress $ManagementIP -NetworkName $NetworkName
}


# register kubelet
.\nssm.exe install $KubeletSvc $KubernetessDir\kubelet.exe

$kubeletArgs = @(
    "--hostname-override=$(hostname)"
    '--v=6'
    '--pod-infra-container-image=kubeletwin/pause'
    '--resolv-conf=""'
    '--allow-privileged=true'
    '--enable-debugging-handlers'
    "--cluster-dns=$KubeDnsServiceIp"
    '--cluster-domain=cluster.local'
    "--kubeconfig=$KubeConfigsDir\config"
    '--hairpin-mode=promiscuous-bridge'
    '--image-pull-progress-deadline=20m'
    '--cgroups-per-qos=false'
    "--log-dir=$LogDir"
    '--logtostderr=false'
    '--enforce-node-allocatable=""'
    '--network-plugin=cni'
    "--cni-bin-dir=$CnidDir"
    "--cni-conf-dir=$CnidDir\config"
    "--node-ip=$(Get-MgmtIpAddress)"
)
if ($KubeletFeatureGates -ne "")
{
    $kubeletArgs += "--feature-gates=$KubeletFeatureGates"
}

.\nssm.exe set $KubeletSvc AppParameters $kubeletArgs
.\nssm.exe set $KubeletSvc AppDirectory $KubernetessDir
.\nssm.exe set $KubeletSvc Start SERVICE_DELAYED_START
.\nssm.exe start $KubeletSvc

Start-Sleep 2

# register kube-proxy
.\nssm.exe install $KubeProxySvc $KubernetessDir\kube-proxy.exe
.\nssm.exe set $KubeProxySvc AppDirectory $KubernetessDir

if ($NetworkMode -eq "l2bridge")
{
    .\nssm.exe set $KubeProxySvc AppEnvironmentExtra KUBE_NETWORK=cbr0
    .\nssm.exe set $KubeProxySvc AppParameters --v=4 --proxy-mode=kernelspace --hostname-override=$Hostname --kubeconfig=$KubeConfigsDir\config --cluster-cidr=$ClusterCIDR --log-dir=$LogDir --logtostderr=false
}
elseif ($NetworkMode -eq "overlay")
{
    if((Test-Path c:/k/sourceVip.json)) 
    {
        $sourceVipJSON = Get-Content sourceVip.json | ConvertFrom-Json 
        $sourceVip = $sourceVipJSON.ip4.ip.Split("/")[0]
    }
    .\nssm.exe set $KubeProxySvc AppParameters --v=4 --proxy-mode=kernelspace --feature-gates="WinOverlay=true" --hostname-override=$Hostname --kubeconfig=$KubeConfigsDir\config --network-name=vxlan0 --source-vip=$sourceVip --enable-dsr=false --cluster-cidr=$ClusterCIDR --log-dir=$LogDir --logtostderr=false
}
.\nssm.exe set $KubeProxySvc DependOnService $KubeletSvc
.\nssm.exe set $KubeProxySvc Start SERVICE_DELAYED_START
.\nssm.exe start $KubeProxySvc

Start-Sleep 2



# register dce-engine
.\nssm.exe install $DceEngineSvc C:\k\dce\dce-engine.exe
.\nssm.exe set $DceEngineSvc AppParameters install
.\nssm.exe set $DceEngineSvc AppDirectory C:\k\dce
.\nssm.exe set $DceEngineSvc AppStdout $LogDir\dce-engine.log
.\nssm.exe set $DceEngineSvc AppStderr $LogDir\dce-engine.log
.\nssm.exe set $DceEngineSvc DependOnService docker
.\nssm.exe set $DceEngineSvc Start SERVICE_DELAYED_START
.\nssm.exe start $DceEngineSvc

$env:path += ";c:\k\dce"
$newPath = "c:\k\dce;" +[Environment]::GetEnvironmentVariable("PATH",[EnvironmentVariableTarget]::Machine)
[Environment]::SetEnvironmentVariable("PATH", $newPath,[EnvironmentVariableTarget]::Machine)

Start-Sleep 2