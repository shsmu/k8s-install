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


echo """
cluster-info:
  master-01:        ${CP0_IP}
  master-02:        ${CP1_IP}
  master-02:        ${CP2_IP}
  VIP:              ${VIP}
  Net Interface:    ${NET_IF}
  CIDR:             ${CIDR}
"""
echo -n 'Please print "yes" to continue or "no" to cancel: '
read AGREE
while [ "${AGREE}" != "yes" ]; do
        if [ "${AGREE}" == "no" ]; then
                exit 0;
        else
                echo -n 'Please print "yes" to continue or "no" to cancel: '
                read AGREE
        fi
done


MASTER_IP=${CP0_IP}
PREFIX_HOSTNAME="prod-k8s"

WORKER_NUM=${#WORKER_IP[@]}


alias cp='cp -f'
alias mv='mv -f'

URL="http://repo.sanyu.com:8080"
KUBE_VERSION='v1.12.0-rc.1'

yum -y install wget

hostnamectl set-hostname ${PREFIX_HOSTNAME}-master-0

wget --timestamping \
  http://pkg.cfssl.org/R1.2/cfssl_linux-amd64 \
  http://pkg.cfssl.org/R1.2/cfssljson_linux-amd64

chmod +x cfssl_linux-amd64 cfssljson_linux-amd64
sudo mv cfssl_linux-amd64 /usr/local/bin/cfssl
sudo mv cfssljson_linux-amd64 /usr/local/bin/cfssljson

wget --timestamping \
  $URL/kubernetes-release/release/${KUBE_VERSION}/bin/linux/amd64/kubectl

chmod +x kubectl
sudo mv kubectl /usr/local/bin/

cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "China",
      "L": "Shanghai",
      "O": "Kubernetes",
      "OU": "Shanghai",
      "ST": "Shanghai"
    }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca
for item in ${WORKER_IP[@]}; do scp ca* root@$item: ; done

cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "China",
      "L": "Shanghai",
      "O": "system:masters",
      "OU": "Kubernetes",
      "ST": "Shanghai"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin


for ((i=0;i<$WORKER_NUM;i++))
  do
  cat > worker-$(($i+1))-csr.json <<EOF
{
  "CN": "system:node:${PREFIX_HOSTNAME}-node-$(($i+1))",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "China",
      "L": "Shanghai",
      "O": "system:nodes",
      "OU": "Kubernetes",
      "ST": "Shanghai"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=${PREFIX_HOSTNAME}-node-$(($i+1)),${WORKER_IP[$i]} \
  -profile=kubernetes \
  worker-$(($i+1))-csr.json | cfssljson -bare worker-$(($i+1))

scp worker-$(($i+1))* root@${WORKER_IP[$i]}:

done

cat > kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "China",
      "L": "Shanghai",
      "O": "system:node-proxier",
      "OU": "Kubernetes",
      "ST": "Shanghai"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy

for ((i=0;i<$WORKER_NUM;i++))
  do 
    scp kube-proxy* root@${WORKER_IP[$i]}:
done

cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "China",
      "L": "Shanghai",
      "O": "Kubernetes",
      "OU": "Kubernetes",
      "ST": "Shanghai"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=10.250.0.1,${MASTER_IP},127.0.0.1,kubernetes.default \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes

for ((i=0;i<$WORKER_NUM;i++))
  do 

kubectl config set-cluster kubernetes-training \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://${MASTER_IP}:6443 \
  --kubeconfig=worker-$(($i+1)).kubeconfig

kubectl config set-credentials system:node:worker-$(($i+1)) \
  --client-certificate=worker-$(($i+1)).pem \
  --client-key=worker-$(($i+1))-key.pem \
  --embed-certs=true \
  --kubeconfig=worker-$(($i+1)).kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-training \
  --user=system:node:worker-$(($i+1)) \
  --kubeconfig=worker-$(($i+1)).kubeconfig

kubectl config use-context default --kubeconfig=worker-$(($i+1)).kubeconfig

scp worker-$(($i+1)).kubeconfig root@${WORKER_IP[$i]}:

done

kubectl config set-cluster kubernetes-training \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://${MASTER_IP}:6443 \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-credentials kube-proxy \
  --client-certificate=kube-proxy.pem \
  --client-key=kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-training \
  --user=kube-proxy \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

for ((i=0;i<$WORKER_NUM;i++))
  do 
    scp kube-proxy.kubeconfig root@${WORKER_IP[$i]}:
done

ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF

wget --timestamping \
  $URL/etcd-io/etcd/releases/download/v3.2.24/etcd-v3.2.24-linux-amd64.tar.gz

tar -xvf etcd-v3.2.24-linux-amd64.tar.gz
sudo mv etcd-v3.2.24-linux-amd64/etcd* /usr/local/bin/
rm -rf etcd-v3.2.24-linux-amd64 etcd-v3.2.24-linux-amd64.tar.gz

sudo mkdir -p /etc/etcd /var/lib/etcd
sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/

cat > etcd.service <<EOF
[Unit]
Description=etcd
Documentation=https://github.com/coreos
[Service]
ExecStart=/usr/local/bin/etcd \\
  --name master \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${MASTER_IP}:2380 \\
  --listen-peer-urls https://${MASTER_IP}:2380 \\
  --listen-client-urls https://${MASTER_IP}:2379,http://127.0.0.1:2379 \\
  --advertise-client-urls https://${MASTER_IP}:2379,http://127.0.0.1:2379 \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

sudo mv etcd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

ETCDCTL_API=3 etcdctl member list

wget --timestamping \
  "$URL/kubernetes-release/release/${KUBE_VERSION}/bin/linux/amd64/kube-apiserver" \
  "$URL/kubernetes-release/release/${KUBE_VERSION}/bin/linux/amd64/kube-scheduler" \
  "$URL/kubernetes-release/release/${KUBE_VERSION}/bin/linux/amd64/kube-controller-manager"

chmod +x kube-apiserver kube-controller-manager kube-scheduler
sudo mv kube-apiserver kube-controller-manager kube-scheduler /usr/local/bin/

sudo mkdir -p /var/lib/kubernetes/
sudo cp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem encryption-config.yaml \
  /var/lib/kubernetes/

cat > kube-apiserver.service <<EOF
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes
[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --admission-control=Initializers,NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --advertise-address=${MASTER_IP} \\
  --allow-privileged=true \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-swagger-ui=true \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=http://127.0.0.1:2379 \\
  --event-ttl=1h \\
  --experimental-encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --insecure-bind-address=127.0.0.1 \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --kubelet-https=true \\
  --runtime-config=api/all \\
  --service-account-key-file=/var/lib/kubernetes/ca-key.pem \\
  --service-cluster-ip-range=10.250.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

sudo mv kube-apiserver.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kube-apiserver
sudo systemctl start kube-apiserver

cat > kube-controller-manager.service <<EOF
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes
[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --address=0.0.0.0 \\
  --allocate-node-cidrs=true \\
  --cluster-cidr=10.244.0.0/16 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --leader-elect=true \\
  --master=http://127.0.0.1:8080 \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/ca-key.pem \\
  --service-cluster-ip-range=10.250.0.0/24 \\
  --v=2
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

sudo mv kube-controller-manager.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kube-controller-manager
sudo systemctl start kube-controller-manager

cat > kube-scheduler.service <<EOF
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes
[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --leader-elect=true \\
  --master=http://127.0.0.1:8080 \\
  --v=2
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

sudo mv kube-scheduler.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable kube-scheduler
sudo systemctl start kube-scheduler

