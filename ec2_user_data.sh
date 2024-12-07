#!/bin/bash
set -x

# Variables de entorno
echo "Cluster Name: $CLUSTER_NAME"
echo "AWS Region: $AWS_REGION"
echo "Node Type: $NODE_TYPE"
echo "Node Count: $NODE_COUNT"

# Función para esperar a que apt esté disponible
wait_for_apt() {
  while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
    echo "Esperando a que otras operaciones de apt terminen..."
    sleep 5
  done
}

# Función para logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> /home/ubuntu/logfile.log
}

# Función para manejar errores
handle_error() {
    log "ERROR: $1"
    exit 1
}

# Actualizar el sistema
log "Actualizando el sistema..."
sudo apt-get update && sudo apt-get upgrade -y || handle_error "No se pudo actualizar el sistema"

# Instalar unzip
log "INSTALANDO Unzip"
wait_for_apt
sudo apt-get update
sudo apt-get install -y unzip
unzip -v

# Instalar dependencias
log "INSTALANDO dependencias..."
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common || handle_error "No se pudieron instalar las dependencias"

## Instalar Docker
log "INSTALANDO Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh || handle_error "No se pudo descargar el script de Docker"
sudo sh get-docker.sh || handle_error "No se pudo instalar Docker"
sudo usermod -aG docker ubuntu || handle_error "No se pudo añadir el usuario al grupo docker"

echo "INSTALANDO Docker Compose"
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version

# Instalar kubectl
log "INSTALANDO kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" || handle_error "No se pudo descargar kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || handle_error "No se pudo instalar kubectl"

# Instalar AWS CLI
log "INSTALANDO AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" || handle_error "No se pudo descargar AWS CLI"
unzip awscliv2.zip || handle_error "No se pudo descomprimir AWS CLI"
sudo ./aws/install || handle_error "No se pudo instalar AWS CLI"

# Instalar aws-iam-authenticator
curl -o aws-iam-authenticator https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/aws-iam-authenticator
chmod +x ./aws-iam-authenticator
sudo mv ./aws-iam-authenticator /usr/local/bin

# Crear el cluster EKS utilizando AWS CLI
log "Creando cluster EKS..."
aws eks create-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/$EKS_CLUSTER_ROLE \
  --resources-vpc-config subnetIds=$SUBNET_IDS,securityGroupIds=$SECURITY_GROUP_IDS \
  --kubernetes-version 1.30 || handle_error "No se pudo crear el cluster EKS"

log "Esperando a que el cluster EKS esté disponible..."
# Esperamos a que el clúster esté en estado activo
aws eks wait cluster-active --name $CLUSTER_NAME --region $AWS_REGION || handle_error "El cluster EKS no se activó correctamente"

# Crear el grupo de nodos
log "Creando grupo de nodos..."
aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name tarea3-nodes \
  --node-role arn:aws:iam::$AWS_ACCOUNT_ID:role/$EKS_NODE_ROLE \
  --subnets $SUBNET_IDS \
  --instance-types $NODE_TYPE \
  --scaling-config minSize=1,maxSize=$NODE_COUNT,desiredSize=$NODE_COUNT \
  --region $AWS_REGION || handle_error "No se pudo crear el grupo de nodos"

log "Esperando a que el grupo de nodos esté disponible..."
# Esperamos a que el grupo de nodos esté en estado activo
aws eks wait nodegroup-active --cluster-name $CLUSTER_NAME --nodegroup-name tarea3-nodes --region $AWS_REGION || handle_error "El grupo de nodos no se activó correctamente"

# Configuración de kubectl
log "Configurando kubectl para el nuevo cluster..."
if ! aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION; then
    log "Error al actualizar kubeconfig"
    exit 1
fi

log "Contenido de kubeconfig:"
cat ~/.kube/config | while read line; do log "$line"; done

log "Versión de kubectl:"
kubectl version --client | while read line; do log "$line"; done

# Verificar que los nodos estén listos
log "Verificando que los nodos estén listos..."
kubectl get nodes --watch &
PID=$!
sleep 60
kill $PID

log "Versión de AWS CLI:"
aws --version

log "Probando conexión al cluster:"
if ! kubectl get nodes; then
    log "Error al conectar con el cluster"
    exit 1
fi

log "Configuración completada. El cluster EKS está listo para usar."

# Instalar Helm
log "Instalando Helm"
if ! curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash; then
    handle_error "Failed to install Helm"
fi
helm version

# Asegurarse de que las configuraciones estén disponibles para el usuario ubuntu
mkdir -p /home/ubuntu/.kube
mkdir -p /root/.kube
sudo cp /root/.kube/config /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config

# Añadir kubectl al PATH del usuario ubuntu
log 'export PATH=$PATH:/usr/local/bin' >> /home/ubuntu/.bashrc
source /home/ubuntu/.bashrc

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

log "Configuración del cluster EKS completada."
log "Todas las herramientas necesarias han sido instaladas y el cluster está listo."
