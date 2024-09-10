#!/bin/bash

# Função para verificar e abrir portas
check_and_open_ports() {
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
}

# Função para solicitar e validar domínio
get_domain() {
    while true; do
        read -p "Digite o domínio que será utilizado: " domain
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
    read -p "Digite seu endereço de e-mail para o Certbot: " email
    echo $email
}

# Função para solicitar credenciais
get_credentials() {
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

# Configurar variáveis de ambiente
echo "DOMAIN=$domain" > .env
echo "EMAIL=$email" >> .env
echo "ADMIN_USER=$(echo $credentials | cut -d':' -f1)" >> .env
echo "ADMIN_PASSWORD=$(echo $credentials | cut -d':' -f2)" >> .env

# Usar as mesmas credenciais para todas as aplicações
echo "KEYCLOAK_USER=$ADMIN_USER" >> .env
echo "KEYCLOAK_PASSWORD=$ADMIN_PASSWORD" >> .env
echo "GRAFANA_ADMIN_USER=$ADMIN_USER" >> .env
echo "GRAFANA_ADMIN_PASSWORD=$ADMIN_PASSWORD" >> .env
echo "APISIX_DASHBOARD_USER=$ADMIN_USER" >> .env
echo "APISIX_DASHBOARD_PASSWORD=$ADMIN_PASSWORD" >> .env

# Substituir variáveis nos arquivos de configuração
sed -i "s/\${DOMAIN}/$domain/g" docker/nginx/nginx.conf
sed -i "s/\${ADMIN_USER}/$ADMIN_USER/g" docker/dashboard/conf.yaml docker/keycloak/realm-export.json
sed -i "s/\${ADMIN_PASSWORD}/$ADMIN_PASSWORD/g" docker/dashboard/conf.yaml docker/keycloak/realm-export.json

# Iniciar os serviços
docker-compose up -d

# Gerar certificados SSL
docker-compose run --rm certbot certonly --webroot -w /var/www/certbot \
    --email $email --agree-tos --no-eff-email \
    -d $domain -d www.$domain

# Reiniciar Nginx para aplicar os certificados
docker-compose restart nginx

echo "Instalação concluída. Acesse:"
echo "- APISIX: https://$domain"
echo "- APISIX Dashboard: https://$domain/apisix/dashboard"
echo "- Keycloak: https://$domain:8080"
echo "- Grafana: http://$domain:3000"
echo ""
echo "Use as seguintes credenciais para todas as aplicações:"
echo "Usuário: $ADMIN_USER"
echo "Senha: $ADMIN_PASSWORD"