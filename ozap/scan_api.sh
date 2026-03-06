#!/bin/bash
# ==========================================
# OWASP ZAP API Scanner (curl-based)
# Lê alvos de targets.conf e gera relatórios
# ==========================================

# Configurações
ZAP_API_URL="http://localhost:8080"
ZAP_API_KEY="1234567890"
REPORT_DIR="./zap_reports"
TARGETS_FILE="./targets.conf"
LOG_FILE="./logs/scan_api_$(date +%Y%m%d).log"
SPIDER_TIMEOUT=300      # 5 minutos para spider
ASCAN_TIMEOUT=600       # 10 minutos para active scan
SLEEP_INTERVAL=5        # Segundos entre verificações

# Cria diretórios
mkdir -p "$REPORT_DIR"
mkdir -p "./logs"

# Função para limpar o contexto do ZAP via API
clean_zap_context() {
    log "🧹 Limpando contexto do ZAP..."

    # Remove todas as URLs do histórico
    curl -s "${ZAP_API_URL}/JSON/core/action/removeAllSites/?apikey=${ZAP_API_KEY}" > /dev/null

    # Limpa sessões de spider/scan
    curl -s "${ZAP_API_URL}/JSON/spider/action/clear/?apikey=${ZAP_API_KEY}" > /dev/null
    curl -s "${ZAP_API_URL}/JSON/ascan/action/clear/?apikey=${ZAP_API_KEY}" > /dev/null

    log "✅ Contexto do ZAP limpo"
}

# Função de Log
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Função para aguardar o ZAP estar disponível
wait_for_zap() {
    log "Verificando conexão com ZAP API..."
    for i in $(seq 1 20); do
        if curl -s "${ZAP_API_URL}/JSON/core/view/version/?apikey=${ZAP_API_KEY}" | grep -q "version"; then
            log "✅ ZAP API disponível"
            return 0
        fi
        sleep 3
    done
    log "❌ ERRO: ZAP API não respondeu"
    return 1
}

# Função para verificar se URL está acessível
check_url() {
    local url=$1
    if curl -s --head --max-time 10 "$url" | grep -q "HTTP"; then
        return 0
    else
        return 1
    fi
}

# Função para aguardar conclusão do spider
wait_for_spider() {
    local scan_id=$1
    local elapsed=0
    
    log "🕷️  Spider iniciado (ID: ${scan_id}), aguardando conclusão..."
    
    while [ $elapsed -lt $SPIDER_TIMEOUT ]; do
        status=$(curl -s "${ZAP_API_URL}/JSON/spider/view/status/?scanId=${scan_id}&apikey=${ZAP_API_KEY}" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        
        if [ "$status" = "100" ]; then
            log "✅ Spider concluído (100%)"
            return 0
        fi
        
        log "📊 Spider: ${status}% (${elapsed}s)"
        sleep $SLEEP_INTERVAL
        elapsed=$((elapsed + SLEEP_INTERVAL))
    done
    
    log "⚠️  Timeout do spider (${SPIDER_TIMEOUT}s), continuando..."
    return 1
}

# Função para aguardar conclusão do active scan
wait_for_ascan() {
    local scan_id=$1
    local elapsed=0
    
    log "⚔️  Active Scan iniciado (ID: ${scan_id}), aguardando conclusão..."
    
    while [ $elapsed -lt $ASCAN_TIMEOUT ]; do
        status=$(curl -s "${ZAP_API_URL}/JSON/ascan/view/status/?scanId=${scan_id}&apikey=${ZAP_API_KEY}" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        
        if [ "$status" = "100" ]; then
            log "✅ Active Scan concluído (100%)"
            return 0
        fi
        
        log "📊 Active Scan: ${status}% (${elapsed}s)"
        sleep $SLEEP_INTERVAL
        elapsed=$((elapsed + SLEEP_INTERVAL))
    done
    
    log "⚠️  Timeout do active scan (${ASCAN_TIMEOUT}s), gerando relatório parcial..."
    return 1
}

# Função principal de scan via API
run_api_scan() {
    local name=$1
    local url=$2
    local scan_type=$3
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local report_file="${REPORT_DIR}/${name}_${timestamp}.html"
    
    log "=== Iniciando scan para ${name}: ${url} (tipo: ${scan_type}) ==="
    
    # Verifica se URL está acessível
    if ! check_url "$url"; then
        log "❌ URL não respondeu: ${url}"
        return 1
    fi
    
    # 1. Iniciar Spider (sempre necessário para mapear o site)
    log "🕷️  Iniciando Spider..."
    spider_response=$(curl -s "${ZAP_API_URL}/JSON/spider/action/scan/?url=${url}&apikey=${ZAP_API_KEY}")
    spider_id=$(echo "$spider_response" | grep -o '"scan":"[^"]*"' | cut -d'"' -f4)
    
    if [ -z "$spider_id" ]; then
        log "❌ Falha ao iniciar spider"
        return 1
    fi
    
    wait_for_spider "$spider_id"
    
    # 2. Active Scan (apenas se tipo for 'full')
    if [ "$scan_type" = "full" ]; then
        log "⚔️  Iniciando Active Scan..."
        ascan_response=$(curl -s "${ZAP_API_URL}/JSON/ascan/action/scan/?url=${url}&apikey=${ZAP_API_KEY}")
        ascan_id=$(echo "$ascan_response" | grep -o '"scan":"[^"]*"' | cut -d'"' -f4)
        
        if [ -n "$ascan_id" ]; then
            wait_for_ascan "$ascan_id"
        else
            log "⚠️  Falha ao iniciar active scan, pulando..."
        fi
    elif [ "$scan_type" = "spider_only" ]; then
        log "ℹ️  Modo spider_only: pulando active scan"
    fi
    
    # Pequena pausa para ZAP processar resultados
    sleep 10
    
    # 3. Gerar Relatório HTML
    log "📄 Gerando relatório HTML..."
    if curl -s "${ZAP_API_URL}/OTHER/core/other/htmlreport/?apikey=${ZAP_API_KEY}" -o "$report_file"; then
        if [ -s "$report_file" ]; then
            log "✅ Relatório salvo: ${report_file}"
            
            # Contagem rápida de alertas
            alerts=$(curl -s "${ZAP_API_URL}/JSON/core/view/numberOfAlerts/?baseurl=${url}&apikey=${ZAP_API_KEY}")
            log "📊 Alertas encontrados: ${alerts}"
            return 0
        fi
    fi
    
    log "❌ Falha ao gerar relatório"
    return 1
}

# Função para limpar relatórios antigos
cleanup_old_reports() {
    local retention_days=7
    log "🧹 Limpando relatórios com mais de ${retention_days} dias..."
    find "$REPORT_DIR" -name "*.html" -type f -mtime +${retention_days} -delete 2>/dev/null
    log "✅ Limpeza concluída"
}

# ==========================================
# MAIN
# ==========================================

log "🚀 OWASP ZAP API Scanner - Iniciando"

# Verifica ZAP
if ! wait_for_zap; then
    exit 1
fi

# Verifica arquivo de alvos
if [ ! -f "$TARGETS_FILE" ]; then
    log "❌ Arquivo ${TARGETS_FILE} não encontrado!"
    exit 1
fi

# Processa cada alvo
while IFS='|' read -r name url scan_type || [ -n "$name" ]; do
    # Pula linhas vazias e comentários
    case "$name" in
        ''|\#*) continue ;;
    esac
    
    # Define tipo padrão se não especificado
    scan_type=${scan_type:-baseline}
    
    run_api_scan "$name" "$url" "$scan_type"
    
    # Delay entre scans
    log "⏳ Aguardando 10s antes do próximo scan..."
    sleep 10
    
done < "$TARGETS_FILE"

# Limpeza final
cleanup_old_reports

log "🏁 Processo concluído!"
