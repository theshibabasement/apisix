#!/bin/bash

set -e

# Função para imprimir mensagens de status
print_status() {
    echo "--- $1"
}

# Função para verificar e abrir portas
check_and_open_ports() {
    print_status "Verificando e abrindo portas..."
    local ports=(80 443 9080 9180 9090 9091 2379 8080 3000)
    for port in "${ports[@]}"; do
        if ! sudo ufw status | grep -q "$port"; then
            sudo ufw allow $port
            echo "Porta $port aberta"
        else
            echo "Porta $port já está aberta"
        fi
    done
    sudo ufw reload
    print_status "Verificação de portas concluída"
}

# Função para solicitar e validar domínio
get_domain() {
    print_status "Solicitando informações do domínio..."
    while true; do
        read -p "Digite o domínio que será utilizado (ex: apisix.lime.my.id): " domain
        echo "Domínio digitado: $domain"
        read -p "Você confirma que o DNS já está configurado para o servidor? (s/n): " confirm
        if [[ $confirm =~ ^[Ss]$ ]]; then
            break
        else
            echo "Por favor, configure o DNS antes de continuar."
        fi
    done
    echo $domain
}

# Função para solicitar informações do Certbot
get_certbot_info() {
    print_status "Solicitando informações do Certbot..."
    read -p "Digite seu endereço de e-mail para o Certbot: " email
    echo $email
}

# Função para solicitar credenciais
get_credentials() {
    print_status "Solicitando credenciais..."
    while true; do
        read -p "Digite o nome de usuário para todas as aplicações: " username
        read -s -p "Digite a senha para todas as aplicações: " password
        echo
        read -s -p "Confirme a senha: " password_confirm
        echo
        if [[ "$password" == "$password_confirm" ]]; then
            break
        else
            echo "As senhas não coincidem. Tente novamente."
        fi
    done
    echo "$username:$password"
}

# Verificar e abrir portas
check_and_open_ports

# Solicitar informações
domain=$(get_domain)
email=$(get_certbot_info)
credentials=$(get_credentials)

print_status "Configurando variáveis de ambiente..."
# Configurar variáveis de ambiente
echo "DOMAIN=$domain" > .env
echo "EMAIL=$email" >> .env
echo "ADMIN_USER=$(echo $credentials | cut -d':' -f1)" >> .env
echo "ADMIN_PASSWORD=$(echo $credentials | cut -d':' -f2)" >> .env

# Usar as mesmas credenciais para todas as aplicações
echo "KEYCLOAK_USER=$(echo $credentials | cut -d':' -f1)" >> .env
echo "KEYCLOAK_PASSWORD=$(echo $credentials | cut -d':' -f2)" >> .env
echo "GRAFANA_ADMIN_USER=$(echo $credentials | cut -d':' -f1)" >> .env
echo "GRAFANA_ADMIN_PASSWORD=$(echo $credentials | cut -d':' -f2)" >> .env
echo "APISIX_DASHBOARD_USER=$(echo $credentials | cut -d':' -f1)" >> .env
echo "APISIX_DASHBOARD_PASSWORD=$(echo $credentials | cut -d':' -f2)" >> .env

print_status "Preparando arquivos de configuração..."

# Nginx configuration
mkdir -p docker/nginx
cat > docker/nginx/nginx.conf << EOL
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl;
    server_name DOMAIN_PLACEHOLDER;

    ssl_certificate /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/DOMAIN_PLACEHOLDER/privkey.pem;

    location / {
        proxy_pass http://apisix:9080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /apisix/dashboard {
        proxy_pass http://apisix-dashboard:9000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

# Dashboard configuration
mkdir -p docker/dashboard
cat > docker/dashboard/conf.yaml << EOL
conf:
  listen:
    host: 0.0.0.0
    port: 9000
  etcd:
    endpoints:
      - "etcd:2379"
  log:
    error_log:
      level: warn
      file_path: logs/error.log
    access_log:
      file_path: logs/access.log
authentication:
  secret: ADMIN_PASSWORD_PLACEHOLDER
  expire_time: 3600
  users:
    - username: ADMIN_USER_PLACEHOLDER
      password: ADMIN_PASSWORD_PLACEHOLDER
EOL

# Keycloak configuration
mkdir -p docker/keycloak
cat > docker/keycloak/realm-export.json << EOL
{
  "realm": "apisix",
  "enabled": true,
  "sslRequired": "external",
  "registrationAllowed": false,
  "privateKey": "MIIEowIBAAKCAQEAiU...",
  "publicKey": "MIIBIjANBgkqhki...",
  "clients": [
    {
      "clientId": "apisix",
      "enabled": true,
      "clientAuthenticatorType": "client-secret",
      "secret": "ADMIN_PASSWORD_PLACEHOLDER",
      "redirectUris": [
        "https://DOMAIN_PLACEHOLDER/*"
      ],
      "webOrigins": [
        "https://DOMAIN_PLACEHOLDER"
      ],
      "protocol": "openid-connect"
    }
  ]
}
EOL

print_status "Substituindo variáveis nos arquivos de configuração..."
# Substituir variáveis nos arquivos de configuração
sed -i "s|DOMAIN_PLACEHOLDER|$domain|g" docker/nginx/nginx.conf docker/keycloak/realm-export.json
sed -i "s|ADMIN_USER_PLACEHOLDER|$(echo $credentials | cut -d':' -f1)|g" docker/dashboard/conf.yaml
sed -i "s|ADMIN_PASSWORD_PLACEHOLDER|$(echo $credentials | cut -d':' -f2)|g" docker/dashboard/conf.yaml docker/keycloak/realm-export.json

print_status "Iniciando os serviços..."
# Iniciar o Nginx primeiro
docker-compose up -d nginx

print_status "Aguardando Nginx iniciar..."
sleep 10  # Dar tempo para o Nginx iniciar completamente

print_status "Gerando certificados SSL..."
# Gerar certificados SSL
docker-compose run --rm certbot certonly --webroot -w /var/www/certbot \
    --email $email --agree-tos --no-eff-email --force-renewal \
    -d $domain -d www.$domain

print_status "Reiniciando todos os serviços..."
docker-compose up -d

print_status "Verificando status dos serviços..."
docker-compose ps

print_status "Instalação concluída!"
echo "Acesse:"
echo "- APISIX: https://$domain"
echo "- APISIX Dashboard: https://$domain/apisix/dashboard"
echo "- Keycloak: https://$domain:8080"
echo "- Grafana: http://$domain:3000"
echo ""
echo "Use as seguintes credenciais para todas as aplicações:"
echo "Usuário: $(echo $credentials | cut -d':' -f1)"
echo "Senha: $(echo $credentials | cut -d':' -f2)"

print_status "Se algum serviço não estiver rodando, você pode tentar reiniciá-lo com:"
echo "docker-compose restart <nome_do_serviço>"

print_status "Para ver os logs de um serviço específico, use:"
echo "docker-compose logs <nome_do_serviço>"

print_status "Para ver os logs de todos os serviços, use:"
echo "docker-compose logs"

print_status "Lembre-se de configurar seu DNS para apontar para o IP deste servidor."
echo "IP do servidor: $(curl -s ifconfig.me)"
