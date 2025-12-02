#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

check_env() {
    log "Проверка переменных окружения..."
    
    if [ -z "$MATRIX_DOMAIN" ]; then
        error "MATRIX_DOMAIN не установлен"
    fi
    
    if [ -z "$POSTGRES_PASSWORD" ]; then
        error "POSTGRES_PASSWORD не установлен"
    fi
    
    log "Переменные окружения проверены"
}

create_directories() {
    log "Создание необходимых директорий..."
    
    mkdir -p data logs ssl nginx/sites-available coturn
    chmod 755 data logs
    
    log "Директории созданы"
}

generate_synapse_config() {
    log "Генерация конфигурации Synapse..."
    
    if [ ! -f "data/homeserver.yaml" ]; then
        docker run --rm \
            -v $(pwd)/data:/data \
            -e SYNAPSE_SERVER_NAME=$MATRIX_DOMAIN \
            -e SYNAPSE_REPORT_STATS=no \
            matrixdotorg/synapse:latest generate
        
        cat >> data/homeserver.yaml << EOF

database:
  name: psycopg2
  args:
    user: synapse
    password: $POSTGRES_PASSWORD
    database: synapse
    host: db
    port: 5432
    cp_min: 5
    cp_max: 10

redis:
  enabled: true
  host: redis
  port: 6379

enable_registration: false
enable_registration_without_verification: false

max_upload_size: 50M
media_store_path: /data/media_store

turn_uris: [ "turn:${TURN_DOMAIN}:3478?transport=udp", "turn:${TURN_DOMAIN}:3478?transport=tcp" ]
turn_shared_secret: "${COTURN_SECRET}"
turn_user_lifetime: 86400000
turn_allow_guests: True

log_config: /data/log_config.yaml
EOF
        
        log "Конфигурация Synapse сгенерирована"
    else
        log "Конфигурация Synapse уже существует"
    fi
}

setup_ssl() {
    log "Настройка SSL сертификатов..."
    
    if [ ! -f "ssl/fullchain.pem" ]; then
        warn "SSL сертификаты не найдены. Создаем самоподписанные для тестирования..."
        
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout ssl/privkey.pem \
            -out ssl/fullchain.pem \
            -subj "/C=RU/ST=State/L=City/O=Organization/CN=$MATRIX_DOMAIN"
        
        warn "Созданы самоподписанные сертификаты. Замените на Let's Encrypt!"
    fi
}

update_nginx_config() {
    log "Обновление конфигурации nginx..."
    
    envsubst '${MATRIX_DOMAIN}' < nginx/sites-available/synapse.conf > nginx/sites-available/synapse_final.conf
    
    log "Конфигурация nginx обновлена"
}

start_services() {
    log "Запуск сервисов..."
    
    docker-compose -f docker-compose.prod.yml down
    docker-compose -f docker-compose.prod.yml pull
    docker-compose -f docker-compose.prod.yml up -d
    
    log "Сервисы запущены"
}

health_check() {
    log "Проверка здоровья сервисов..."
    
    sleep 30
    
    if docker-compose -f docker-compose.prod.yml ps | grep -q "Up"; then
        log "Сервисы работают корректно"
        
        if curl -f http://localhost:8008/health > /dev/null 2>&1; then
            log "Synapse доступен"
        else
            warn "Synapse недоступен, проверьте логи"
        fi
    else
        error "Некоторые сервисы не запустились"
    fi
}

main() {
    log "Начало развертывания Synapse..."
    
    check_env
    create_directories
    generate_synapse_config
    setup_ssl
    update_nginx_config
    start_services
    health_check
    
    log "Развертывание завершено успешно!"
    log "Synapse доступен по адресу: https://$MATRIX_DOMAIN"
}

main "$@"