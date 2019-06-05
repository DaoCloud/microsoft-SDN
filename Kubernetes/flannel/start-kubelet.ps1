Param(
    [ValidateSet("l2bridge", "overlay",IgnoreCase = $true)] [parameter(Mandatory = $true)] $NetworkMode,
    [parameter(Mandatory = $false)] $KubeDnsServiceIP="10.96.0.10",
    [parameter(Mandatory = $false)] $LogDir = "C:\k",
    [parameter(Mandatory = $false)] $KubeletFeatureGates = "",
    [parameter(Mandatory = $false)] $ScriptsDir = "c:\k\scripts",
    [parameter(Mandatory = $false)] $KubernetessDir = "c:\k\kubernetes",
    [switch] $RegisterOnly
)

$GithubSDNRepository = 'Microsoft/SDN'
if ((Test-Path env:GITHUB_SDN_REPOSITORY) -and ($env:GITHUB_SDN_REPOSITORY -ne ''))
{
    $GithubSDNRepository = $env:GITHUB_SDN_REPOSITORY
}

$helper = "$ScriptsDir\helper.psm1"
if (!(Test-Path $helper))
{
    Start-BitsTransfer "https://raw.githubusercontent.com/$GithubSDNRepository/master/Kubernetes/windows/helper.psm1" -Destination "$helper"
}
ipmo $helper

if ($RegisterOnly.IsPresent)
{
    RegisterNode
    exit
}

$kubeletArgs = @(
    "--hostname-override=$(hostname)"
    '--v=6'
    '--pod-infra-container-image=kubeletwin/pause'
    '--resolv-conf=""'
    '--allow-privileged=true'
    '--enable-debugging-handlers'
    "--cluster-dns=$KubeDnsServiceIp"
    '--cluster-domain=cluster.local'
    '--kubeconfig=c:\k\config'
    '--hairpin-mode=promiscuous-bridge'
    '--image-pull-progress-deadline=20m'
    '--cgroups-per-qos=false'
    "--log-dir=$LogDir"
    '--logtostderr=false'
    '--enforce-node-allocatable=""'
    '--network-plugin=cni'
    '--cni-bin-dir="c:\k\cni"'
    '--cni-conf-dir="c:\k\cni\config"'
    "--node-ip=$(Get-MgmtIpAddress)"
)

if ($KubeletFeatureGates -ne "")
{
    $kubeletArgs += "--feature-gates=$KubeletFeatureGates"
}

& c:\k\kubelet.exe $kubeletArgs
