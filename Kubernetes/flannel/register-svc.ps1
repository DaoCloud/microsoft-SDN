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

nssm install $FlanneldSvc $CnidDir\flanneld.exe
nssm set $FlanneldSvc AppParameters --kubeconfig-file=$KubeConfigsDir\config --iface=$ManagementIP --ip-masq=1 --kube-subnet-mgr=1
nssm set $FlanneldSvc AppEnvironmentExtra NODE_NAME=$Hostname
nssm set $FlanneldSvc AppDirectory $CnidDir
nssm set $FlanneldSvc AppStdout $LogDir\$FlanneldSvc.log
nssm set $FlanneldSvc AppStderr $LogDir\$FlanneldSvc.log
nssm start $FlanneldSvc

Start-Sleep 2

WaitForNetwork -NetworkName $NetworkName

Start-Sleep 1

if ($NetworkMode -eq "overlay")
{
    GetSourceVip -ipAddress $ManagementIP -NetworkName $NetworkName
}


# register kubelet
nssm install $KubeletSvc $KubernetessDir\kubelet.exe

$kubeletArgs = @(
    "--hostname-override=$(hostname)"
    '--v=6'
    '--pod-infra-container-image=kubeletwin/pause'
    '--resolv-conf=""'
    '--enable-debugging-handlers'
    "--cluster-dns=$KubeDnsServiceIp"
    '--cluster-domain=cluster.local'
    "--kubeconfig=$KubeConfigsDir\config"
    '--hairpin-mode=promiscuous-bridge'
    '--image-pull-progress-deadline=20m'
    '--cgroups-per-qos=false'
    "--log-dir=$LogDir"
    "--log_file=$LogDir\kubelet.log"
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

nssm set $KubeletSvc AppParameters $kubeletArgs
nssm set $KubeletSvc AppDirectory $KubernetessDir
nssm set $KubeletSvc Start SERVICE_DELAYED_START
nssm start $KubeletSvc

Start-Sleep 2

# register kube-proxy
nssm install $KubeProxySvc $KubernetessDir\kube-proxy.exe
nssm set $KubeProxySvc AppDirectory $KubernetessDir
$kubeproxyArgs = @(
    '--v=4'
    '--proxy-mode=kernelspace'
    "--hostname-override=$(hostname)"
    "--kubeconfig=$KubeConfigsDir\config"
    "--cluster-cidr=$ClusterCIDR"
    "--log-dir=$LogDir"
    "--log-file=$LogDir\kube-proxy.log"
    '--logtostderr=false'
    )

if ($NetworkMode -eq "l2bridge")
{
    $env:KUBE_NETWORK=$networkName
    nssm set $KubeProxySvc AppEnvironmentExtra KUBE_NETWORK=$networkName
}
elseif ($NetworkMode -eq "overlay")
{
    if((Test-Path c:/k/sourceVip.json)) 
    {
        $sourceVipJSON = Get-Content sourceVip.json | ConvertFrom-Json 
        $sourceVip = $sourceVipJSON.ip4.ip.Split("/")[0]
    }
    $kubeproxyArgs += @(
        '--feature-gates="WinOverlay=true"'
        '--network-name=vxlan0'
        "--source-vip=$sourceVip"
        '--enable-dsr=false'
        )
}

nssm set $KubeProxySvc AppParameters $kubeproxyArgs
nssm set $KubeProxySvc DependOnService $KubeletSvc
nssm set $KubeProxySvc Start SERVICE_DELAYED_START
nssm start $KubeProxySvc

Start-Sleep 2



# register dce-engine
nssm install $DceEngineSvc C:\k\dce\dce-engine.exe
nssm set $DceEngineSvc AppParameters install
nssm set $DceEngineSvc AppDirectory C:\k\dce
nssm set $DceEngineSvc AppStdout $LogDir\dce-engine.log
nssm set $DceEngineSvc AppStderr $LogDir\dce-engine.log
nssm set $DceEngineSvc DependOnService docker
nssm set $DceEngineSvc Start SERVICE_DELAYED_START
nssm start $DceEngineSvc
 

Start-Sleep 2