#!/bin/bash

# Verifica se o Git está instalado
if ! command -v git &> /dev/null; then
    echo "Git não está instalado. Instalando..."
    sudo apt-get update
    sudo apt-get install -y git
fi

# Clona o repositório
git clone https://github.com/theshibabasement/apisix.git
cd apisix

# Executa o script de instalação
chmod +x setup.sh
./setup.sh