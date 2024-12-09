#!/bin/bash
set -e  # Salir inmediatamente si algún comando falla

# Variables de entorno
echo "Cluster Name: $CLUSTER_NAME"
echo "AWS Region: $AWS_REGION"
echo "Node Type: $NODE_TYPE"
echo "Node Count: $NODE_COUNT"

# Función para logging
log() {
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1"
    echo "[$timestamp] $1" >> /home/ubuntu/logfile.log
}

# Función para manejar errores
handle_error() {
    log "ERROR: $1"
    exit 1
}

# Función para esperar que apt esté disponible
wait_for_apt() {
    while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 ; do
        log "Esperando a que otras operaciones de apt terminen..."
        sleep 5
    done
}

# Verificar si un comando está disponible
check_command() {
    if ! command -v "$1" &>/dev/null; then
        log "$1 no está instalado. Intentando instalar..."
        return 1
    fi
    return 0
}

# Actualizar el sistema
log "Actualizando el sistema..."
sudo apt-get update && sudo apt-get upgrade -y || handle_error "No se pudo actualizar el sistema"

# Función para instalar paquetes
install_package() {
    local package=$1
    log "Instalando $package..."
    sudo apt-get install -y "$package" || handle_error "No se pudo instalar $package"
}

# Instalar herramientas necesarias
install_essential_tools() {
    log "Instalando dependencias básicas..."
    install_package "apt-transport-https"
    install_package "ca-certificates"
    install_package "curl"
    install_package "software-properties-common"
}

# Instalación de unzip
log "Instalando Unzip..."
wait_for_apt
install_package "unzip"

# Instalación de Docker
log "Instalando Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh || handle_error "No se pudo descargar el script de Docker"
sudo sh get-docker.sh || handle_error "No se pudo instalar Docker"
sudo usermod -aG docker ubuntu || handle_error "No se pudo añadir el usuario al grupo docker"
check_command "docker"

# Instalación de Docker Compose
log "Instalando Docker Compose..."
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
check_command "docker-compose"

# Instalación de kubectl
log "Instalando kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" || handle_error "No se pudo descargar kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || handle_error "No se pudo instalar kubectl"
check_command "kubectl"

# Instalación de eksctl
log "Instalando eksctl..."
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp || handle_error "No se pudo descargar eksctl"
sudo mv /tmp/eksctl /usr/local/bin || handle_error "No se pudo mover eksctl a /usr/local/bin"
check_command "eksctl"

# Instalación de AWS CLI
log "Instalando AWS CLI..."
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" || handle_error "No se pudo descargar AWS CLI"
unzip awscliv2.zip || handle_error "No se pudo descomprimir AWS CLI"
sudo ./aws/install || handle_error "No se pudo instalar AWS CLI"
check_command "aws"

# Instalación de aws-iam-authenticator
log "Instalando aws-iam-authenticator..."
curl -o aws-iam-authenticator https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/aws-iam-authenticator
chmod +x ./aws-iam-authenticator
sudo mv ./aws-iam-authenticator /usr/local/bin
check_command "aws-iam-authenticator"

# Crear cluster EKS
log "Creando cluster EKS..."
eksctl create cluster \
  --name $CLUSTER_NAME \
  --version 1.30 \
  --region $AWS_REGION \
  --nodegroup-name tarea3-nodes \
  --node-type $NODE_TYPE \
  --nodes $NODE_COUNT || handle_error "Error al crear el cluster EKS"

# Validar la creación del cluster
log "Verificando el estado del cluster EKS..."
cluster_status=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query "cluster.status" --output text)

if [[ "$cluster_status" != "ACTIVE" ]]; then
    handle_error "El cluster no está activo. Estado actual: $cluster_status. El cluster puede no haberse creado correctamente."
fi

log "El cluster EKS '$CLUSTER_NAME' ha sido creado y está activo."

# Configurar kubectl
log "Configurando kubectl..."
if ! aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION; then
    handle_error "Error al actualizar kubeconfig"
fi

# Mostrar contenido de kubeconfig
log "Contenido de kubeconfig:"
cat ~/.kube/config | while read line; do log "$line"; done

# Verificar que los nodos estén listos
log "Verificando que los nodos estén listos..."
kubectl get nodes --watch &
PID=$!
sleep 60
kill $PID

log "Versión de AWS CLI:"
aws --version

log "Probando conexión al cluster..."
if ! kubectl get nodes; then
    handle_error "Error al conectar con el cluster"
fi

log "Configuración completada. El cluster EKS está listo para usar."

# Instalación de Helm
log "Instalando Helm..."
if ! curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash; then
    handle_error "No se pudo instalar Helm"
fi
helm version

# Asegurar que las configuraciones estén disponibles para el usuario ubuntu
log "Configurando acceso para el usuario ubuntu..."
# mkdir -p /home/ubuntu/.kube
# mkdir -p /root/.kube
# sudo cp /root/.kube/config /home/ubuntu/.kube/config
# sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config

mkdir -p /home/ubuntu/.kube
sudo cp /root/.kube/config /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config


# Añadir kubectl al PATH del usuario ubuntu
log 'export PATH=$PATH:/usr/local/bin' >> /home/ubuntu/.bashrc
source /home/ubuntu/.bashrc

# Actualizar kubeconfig de AWS
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

# Crear un contexto asociado con el namespace 'tarea-3'
kubectl config set-context tarea-3-context --namespace=tarea-3 --cluster=$CLUSTER_NAME --user=aws

# Establecer 'tarea-3-context' como el contexto por defecto
kubectl config use-context tarea-3-context

log "Configuración del cluster EKS completada."
log "Todas las herramientas necesarias han sido instaladas y el cluster está listo."
