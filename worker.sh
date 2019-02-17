#!/bin/bash

function check_parm()
{
  if [ "${2}" == "" ]; then
    echo -n "${1}"
    return 1
  else
    return 0
  fi
}

if [ -f ./cluster-info ]; then
        source ./cluster-info
fi

PREFIX_HOSTNAME="prod-k8s"

WORKER_NUM=${#WORKER_IP[@]}

NUM=1
for ((i=0;i<$WORKER_NUM;i++))
do
   ip addr | grep ${WORKER_IP[i]}  && hostnamectl set-hostname ${PREFIX_HOSTNAME}-node-$(($i+1)) && NUM=$(($i+1))
done

alias cp='cp -f'
alias mv='mv -f'

URL="http://repo.sanyu.com:8080"
KUBE_VERSION='v1.12.0-rc.1'

yum -y install wget

sudo yum install -y yum-utils device-mapper-persistent-data lvm2

sudo yum-config-manager -y --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo

sudo yum makecache fast
sudo yum -y install docker-ce

sudo systemctl enable docker
sudo systemctl start docker
#The following commands will install kubelet, kube-proxy.
sudo yum install -y socat

wget --timestamping \
  $URL/kubernetes-release/release/${KUBE_VERSION}/bin/linux/amd64/kube-proxy \
  $URL/kubernetes-release/release/${KUBE_VERSION}/bin/linux/amd64/kubectl \
  $URL/kubernetes-release/release/${KUBE_VERSION}/bin/linux/amd64/kubelet

sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes

chmod +x kubectl kube-proxy kubelet
sudo mv kubectl kube-proxy kubelet /usr/local/bin/

sudo cp worker-${NUM}-key.pem worker-${NUM}.pem /var/lib/kubelet/
sudo cp worker-${NUM}.kubeconfig /var/lib/kubelet/kubeconfig
sudo cp ca.pem /var/lib/kubernetes/

cat > kubelet.service <<EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=docker.service
Requires=docker.service
[Service]
ExecStart=/usr/local/bin/kubelet \\
  --allow-privileged=true \\
  --anonymous-auth=false \\
  --authorization-mode=Webhook \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --cluster-dns=10.250.0.10 \\
  --cluster-domain=cluster.local \\
  --image-pull-progress-deadline=2m \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --network-plugin=cni \\
  --register-node=true \\
  --runtime-request-timeout=15m \\
  --pod-infra-container-image=docker.io/kubernetes/pause \\
  --tls-cert-file=/var/lib/kubelet/worker-${NUM}.pem \\
  --tls-private-key-file=/var/lib/kubelet/worker-${NUM}-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# Turnning off swap is required by kubelet.
swapoff -a

sudo mv kubelet.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kubelet
sudo systemctl start kubelet

sudo cp kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig
sudo cp worker-${NUM}-key.pem worker-${NUM}.pem /var/lib/kubelet/

cat > kube-proxy.service <<EOF
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes
[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --cluster-cidr=10.244.0.0/16 \\
  --kubeconfig=/var/lib/kube-proxy/kubeconfig \\
  --proxy-mode=iptables \\
  --v=2
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

sudo mv kube-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kube-proxy
sudo systemctl start kube-proxy

