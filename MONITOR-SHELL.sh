#!/bin/bash

# sysnet-dashboard.sh - Monitor Persistente de Sistema e Rede - IPS EDITION
# Focado em baixo consumo de CPU para rodar 24/7
# Requer: ss (iproute2), bc

# --- CONFIGURAÇÃO ---
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
REFRESH=3  # Segundos entre atualizações

# Se não achou interface, pega a primeira não-lo
if [ -z "$INTERFACE" ]; then 
    INTERFACE=$(ls /sys/class/net/ | grep -v lo | head -n1)
fi

# --- CORES E FORMATAÇÃO ESTILO IPS ---
C_RESET="\033[0m"
C_GREEN="\033[38;5;46m"
C_RED="\033[38;5;196m"
C_BLUE="\033[38;5;39m"
C_YELLOW="\033[38;5;226m"
C_ORANGE="\033[38;5;208m"
C_PURPLE="\033[38;5;129m"
C_CYAN="\033[38;5;51m"
C_GRAY="\033[38;5;240m"
C_WHITE="\033[1;37m"
C_BG_HEADER="\033[48;5;232m\033[38;5;159m"
C_BG_SECTION="\033[48;5;236m"
C_BORDER="\033[38;5;245m"

# Esconde cursor e configura terminal
tput civis
clear
stty -echo

# Captura saída
trap cleanup SIGINT SIGTERM

cleanup() {
    tput cnorm
    tput sgr0
    stty echo
    clear
    echo "Monitoramento encerrado."
    exit 0
}

# Funções de Desenho Melhoradas
draw_bar() {
    local val=$1; local max=$2; local width=$3; local color=$4
    if (( $(echo "$max <= 0" | bc -l) )); then max=1; fi
    if (( $(echo "$val < 0" | bc -l) )); then val=0; fi
    
    local pct=$(echo "scale=2; $val / $max" | bc -l)
    local filled=$(echo "$pct * $width" | bc | awk '{print int($1+0.5)}')
    
    if [ "$filled" -gt "$width" ]; then filled=$width; fi
    if [ "$filled" -lt 0 ]; then filled=0; fi
    
    local bar=""
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=filled; i<width; i++)); do bar="${bar}░"; done
    echo -e "${color}${bar}${C_RESET}"
}

draw_sparkline() {
    local values=("$@")
    local sparkchars=" ▂▃▄▅▆▇█"
    local result=""
    local max=0
    
    # Encontra o valor máximo
    for val in "${values[@]}"; do
        if [ "$val" -gt "$max" ]; then max=$val; fi
    done
    
    if [ "$max" -eq 0 ]; then max=1; fi
    
    for val in "${values[@]}"; do
        local index=$(( (val * 7) / max ))
        if [ $index -gt 7 ]; then index=7; fi
        if [ $index -lt 0 ]; then index=0; fi
        result="${result}${sparkchars:$index:1}"
    done
    echo -e "${C_CYAN}$result${C_RESET}"
}

format_bytes() {
    local b=$1
    if [ "$b" -lt 1024 ]; then echo "${b} B/s"; return; fi
    local kb=$(echo "scale=1; $b / 1024" | bc)
    if [ $(echo "$kb < 1024" | bc) -eq 1 ]; then echo "${kb} KB/s"; return; fi
    local mb=$(echo "scale=1; $kb / 1024" | bc)
    if [ $(echo "$mb < 1024" | bc) -eq 1 ]; then echo "${mb} MB/s"; return; fi
    local gb=$(echo "scale=1; $mb / 1024" | bc)
    echo "${gb} GB/s"
}

format_bytes_human() {
    local b=$1
    if [ "$b" -lt 1024 ]; then echo "${b} B"; return; fi
    local kb=$(echo "scale=1; $b / 1024" | bc)
    if [ $(echo "$kb < 1024" | bc) -eq 1 ]; then echo "${kb} KB"; return; fi
    local mb=$(echo "scale=1; $kb / 1024" | bc)
    if [ $(echo "$mb < 1024" | bc) -eq 1 ]; then echo "${mb} MB"; return; fi
    local gb=$(echo "scale=1; $mb / 1024" | bc)
    echo "${gb} GB"
}

format_duration() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        local minutes=$((seconds / 60))
        local secs=$((seconds % 60))
        echo "${minutes}m${secs}s"
    else
        local hours=$((seconds / 3600))
        local minutes=$(( (seconds % 3600) / 60 ))
        echo "${hours}h${minutes}m"
    fi
}

get_cpu_usage() {
    read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
    local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
    local active=$((user + nice + system + iowait + irq + softirq + steal))
    
    local diff_total=$((total - PREV_TOTAL))
    local diff_active=$((active - PREV_ACTIVE))
    
    local usage=0
    if [ "$diff_total" -ne 0 ]; then
        usage=$(( (diff_active * 100) / diff_total ))
    fi
    
    PREV_TOTAL=$total
    PREV_ACTIVE=$active
    echo $usage
}

get_detailed_network_stats() {
    local interface=$1
    # Estatísticas detalhadas da interface
    RX_BYTES=$(cat /sys/class/net/$interface/statistics/rx_bytes)
    TX_BYTES=$(cat /sys/class/net/$interface/statistics/tx_bytes)
    RX_PACKETS=$(cat /sys/class/net/$interface/statistics/rx_packets)
    TX_PACKETS=$(cat /sys/class/net/$interface/statistics/tx_packets)
    RX_ERRORS=$(cat /sys/class/net/$interface/statistics/rx_errors)
    TX_ERRORS=$(cat /sys/class/net/$interface/statistics/tx_errors)
    RX_DROPPED=$(cat /sys/class/net/$interface/statistics/rx_dropped)
    TX_DROPPED=$(cat /sys/class/net/$interface/statistics/tx_dropped)
}

# --- FUNÇÃO AJUSTADA: RETORNA TODAS AS CONEXÕES (NÃO SÓ ESTAB) ---
get_established_connections() {
    ss -atunp | awk '
    NR > 1 {
        proto = $1
        state = $2
        local_addr = $5
        remote_addr = $6
        pid_process = $7

        pid = "N/A"
        process = "N/A"

        if (pid_process ~ "users:") {
            if (match(pid_process, /\(\([^)]+\)\)/)) {
                process_info = substr(pid_process, RSTART+2, RLENGTH-4)
                split(process_info, parts, ",")
                process = parts[1]
                gsub(/"/, "", process)
                for (i in parts) {
                    if (parts[i] ~ /^[0-9]+$/) {
                        pid = parts[i]
                        break
                    }
                }
            }
        }

        split(local_addr, local_parts, ":")
        split(remote_addr, remote_parts, ":")

        local_ip    = local_parts[1]
        local_port  = local_parts[2]
        remote_ip   = remote_parts[1]
        remote_port = remote_parts[2]

        connection_time=1
        tx_packets=0
        rx_packets=0

        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n",
            proto, state, local_ip, local_port, remote_ip, remote_port,
            pid, process, connection_time, tx_packets, rx_packets
    }'
}


# Versão alternativa que usa netstat (mais compatível)
get_established_connections_netstat() {
    netstat -tunp 2>/dev/null | awk '
    /^tcp/ || /^udp/ {
        proto = $1
        local_addr = $4
        remote_addr = $5

        # netstat às vezes tem STATE, às vezes não (ex: UDP)
        state = "-"
        pid_process = ""

        if (NF >= 7) {
            state = $6
            pid_process = $7
        } else if (NF == 6) {
            state = "-"
            pid_process = $6
        }

        pid = "N/A"
        process = "N/A"
        if (pid_process ~ "/") {
            split(pid_process, a, "/")
            pid = a[1]
            process = a[2]
        }

        split(local_addr, local_parts, ":")
        split(remote_addr, remote_parts, ":")

        local_ip = local_parts[1]
        local_port = local_parts[2]
        remote_ip = remote_parts[1]
        remote_port = remote_parts[2]

        connection_time=1
        tx_packets=0
        rx_packets=0

        printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n",
            proto, state, local_ip, local_port, remote_ip, remote_port,
            pid, process, connection_time, tx_packets, rx_packets
    }'
}

get_network_usage_by_process() {
    :
}

# Arrays para sparklines
CPU_HISTORY=()
RX_HISTORY=()
TX_HISTORY=()

# Inicializa variáveis
R1=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
T1=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
RX_TOTAL=$R1
TX_TOTAL=$T1
PREV_TOTAL=0
PREV_ACTIVE=0
get_cpu_usage > /dev/null

# Limpa a tela completamente
clear

# --- LOOP PRINCIPAL ---
while true; do
    # Coleta de dados
    R2=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)
    T2=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
    RX_SPEED=$(( (R2 - R1) / REFRESH ))
    TX_SPEED=$(( (T2 - T1) / REFRESH ))
    R1=$R2; T1=$T2
    
    # Totais acumulados
    RX_TOTAL=$R2
    TX_TOTAL=$T2
    
    # Atualiza histórico para sparklines
    CPU_PERC=$(get_cpu_usage)
    CPU_HISTORY+=($CPU_PERC)
    RX_HISTORY+=($((RX_SPEED/1024)))  # Converte para KB para sparkline
    TX_HISTORY+=($((TX_SPEED/1024)))
    
    # Mantém apenas os últimos 8 valores
    if [ ${#CPU_HISTORY[@]} -gt 8 ]; then
        CPU_HISTORY=("${CPU_HISTORY[@]:1}")
        RX_HISTORY=("${RX_HISTORY[@]:1}")
        TX_HISTORY=("${TX_HISTORY[@]:1}")
    fi
    
    # Memória
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    MEM_FREE=$(free -m | awk '/Mem:/ {print $4}')
    MEM_CACHED=$(free -m | awk '/Mem:/ {print $6}')
    MEM_AVAIL=$(free -m | awk '/Mem:/ {print $7}')
    
    # Swap
    SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
    SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
    
    # Conexões de rede detalhadas
    CONN_TOTAL=$(ss -tun | wc -l | awk '{print $1 - 1}')
    CONN_EST=$(ss -tun state established | wc -l | awk '{print $1 - 1}')
    CONN_WAIT=$(ss -tun state time-wait | wc -l | awk '{print $1 - 1}')
    CONN_LISTEN=$(ss -tun state listening | wc -l | awk '{print $1 - 1}')
    CONN_OTHER=$((CONN_TOTAL - CONN_EST - CONN_WAIT - CONN_LISTEN))
    
    # Estatísticas detalhadas da interface
    get_detailed_network_stats $INTERFACE
    
    # Conexões detalhadas - tenta ss primeiro, depois netstat
    if command -v ss >/dev/null 2>&1; then
        ESTABLISHED_CONNS=$(get_established_connections)
    else
        ESTABLISHED_CONNS=$(get_established_connections_netstat)
    fi
    
    # Load Average
    LOAD_AVG=$(cat /proc/loadavg | cut -d' ' -f1-3)
    
    # Uptime
    UPTIME=$(uptime -p | sed 's/up //')
    UPTIME_RAW=$(cat /proc/uptime | cut -d' ' -f1)
    
    # Tempo atual
    CURRENT_TIME=$(date '+%H:%M:%S')

    # Move cursor para home (0,0) para redesenhar
    tput cup 0 0
    
    # --- CABEÇALHO ---
    echo -e "${C_BG_HEADER}${C_WHITE} 🖥️  SYSTEM MONITOR IPS PRO v3.0 ${C_RESET} ${C_GRAY}| ${C_CYAN}$CURRENT_TIME${C_RESET}"
    echo -e "${C_GRAY} Uptime: $UPTIME ${C_GRAY}| ${C_GREEN}Load: $LOAD_AVG${C_RESET}"
    echo -e "${C_BORDER}════════════════════════════════════════════════════════════${C_RESET}"
    
    # SEÇÃO: RECURSOS DO SISTEMA
    echo -e "${C_BG_SECTION}${C_WHITE}📈 RECURSOS DO SISTEMA${C_RESET}"
    
    # CPU com sparkline
    CPU_SPARK=$(draw_sparkline "${CPU_HISTORY[@]}")
    CPU_BAR=$(draw_bar $CPU_PERC 100 20 $C_CYAN)
    printf " CPU:  [%-20s] ${C_CYAN}%3d%%${C_RESET} %s\n" "$CPU_BAR" "$CPU_PERC" "$CPU_SPARK"
    
    # Memória
    MEM_PERC=$(( (MEM_USED * 100) / MEM_TOTAL ))
    MEM_BAR=$(draw_bar $MEM_PERC 100 20 $C_GREEN)
    printf " RAM:  [%-20s] ${C_GREEN}%3d%%${C_RESET} ${C_GRAY}(%dM Livre)${C_RESET}\n" "$MEM_BAR" "$MEM_PERC" "$MEM_AVAIL"
    
    # Swap (se existir)
    if [ "$SWAP_TOTAL" -gt 0 ]; then
        SWAP_PERC=$(( (SWAP_USED * 100) / SWAP_TOTAL ))
        SWAP_BAR=$(draw_bar $SWAP_PERC 100 20 $C_ORANGE)
        printf " SWAP: [%-20s] ${C_ORANGE}%3d%%${C_RESET}\n" "$SWAP_BAR" "$SWAP_PERC"
    fi
    
    echo -e "${C_BORDER}────────────────────────────────────────────────────────────${C_RESET}"
    
    # SEÇÃO: REDE
    echo -e "${C_BG_SECTION}${C_WHITE}🌐 REDE - ${C_YELLOW}$INTERFACE${C_RESET}"
    
    RX_FMT=$(format_bytes $RX_SPEED)
    TX_FMT=$(format_bytes $TX_SPEED)
    RX_TOTAL_FMT=$(format_bytes_human $RX_TOTAL)
    TX_TOTAL_FMT=$(format_bytes_human $TX_TOTAL)
    
    # Sparklines para rede
    RX_SPARK=$(draw_sparkline "${RX_HISTORY[@]}")
    TX_SPARK=$(draw_sparkline "${TX_HISTORY[@]}")
    
    # Barras de velocidade (escala dinâmica)
    NET_MAX=$(( $(echo "$RX_SPEED $TX_SPEED" | awk '{if ($1 > $2) print $1; else print $2}') ))
    if [ $NET_MAX -eq 0 ]; then NET_MAX=1; fi
    
    RX_BAR=$(draw_bar $RX_SPEED $NET_MAX 15 $C_GREEN)
    TX_BAR=$(draw_bar $TX_SPEED $NET_MAX 15 $C_YELLOW)
    
    printf " ${C_GREEN}⬇️ RX:${C_RESET} %-12s [%-15s] %s\n" "$RX_FMT" "$RX_BAR" "$RX_SPARK"
    printf " ${C_YELLOW}⬆️ TX:${C_RESET} %-12s [%-15s] %s\n" "$TX_FMT" "$TX_BAR" "$TX_SPARK"
    printf " ${C_GRAY}Total:${C_RESET} ⬇${RX_TOTAL_FMT} ⬆${TX_TOTAL_FMT}\n"
    
    # Estatísticas detalhadas de rede
    echo -e " ${C_GRAY}Pacotes:${C_RESET} ${C_GREEN}⬇${RX_PACKETS} ${C_YELLOW}⬆${TX_PACKETS}${C_RESET}"
    if [ $RX_ERRORS -gt 0 ] || [ $TX_ERRORS -gt 0 ]; then
        echo -e " ${C_RED}Erros:${C_RESET} ${C_RED}⬇${RX_ERRORS} ⬆${TX_ERRORS}${C_RESET}"
    fi
    
    echo -e "${C_BORDER}────────────────────────────────────────────────────────────${C_RESET}"
    
    # SEÇÃO: CONEXÕES DE REDE
    echo -e "${C_BG_SECTION}${C_WHITE}🔗 CONEXÕES DE REDE${C_RESET}"
    printf " Total: ${C_WHITE}%-4d${C_RESET} " "$CONN_TOTAL"
    printf "Estabelecidas: ${C_GREEN}%-4d${C_RESET} " "$CONN_EST"
    printf "Listening: ${C_BLUE}%-4d${C_RESET} " "$CONN_LISTEN"
    printf "Time-Wait: ${C_ORANGE}%-4d${C_RESET}\n" "$CONN_WAIT"
    
    # Conexões detalhadas - agora mostra TODAS as conexões
    if [ "$CONN_TOTAL" -gt 0 ]; then
        echo -e "${C_BG_SECTION}${C_WHITE}🔌 TODAS AS CONEXÕES ATIVAS (${CONN_TOTAL} conexões)${C_RESET}"
        
        # Cabeçalho de colunas (agora com estado)
        printf " ${C_CYAN}%-5s${C_RESET} " "Proto"
        printf "${C_PURPLE}%-12s${C_RESET} " "Estado"
        printf "${C_GREEN}%-25s${C_RESET}" "Local"
        printf " ${C_YELLOW}%-25s${C_RESET}" "Remote"
        printf " ${C_WHITE}%-15s${C_RESET}\n" "Processo"
        
        echo -e "${C_BORDER}─────────────────────────────────────────────────────────────────────────────────${C_RESET}"
        
        conn_count=0
        IFS=$'\n'
        for conn in $ESTABLISHED_CONNS; do
            IFS='|' read proto state local_ip local_port remote_ip remote_port pid process connection_time tx_packets rx_packets <<< "$conn"
            
            # Garante que os valores sejam numéricos para evitar erros
            connection_time=$(echo "$connection_time" | grep -E '^[0-9]+$' || echo "0")
            tx_packets=$(echo "$tx_packets" | grep -E '^[0-9]+$' || echo "0")
            rx_packets=$(echo "$rx_packets" | grep -E '^[0-9]+$' || echo "0")
            
            # Formata os endereços
            local_display="${local_ip}:${local_port}"
            remote_display="${remote_ip}:${remote_port}"
            
            # Limita o tamanho para caber na tela
            local_display="${local_display:0:24}"
            remote_display="${remote_display:0:24}"
            process_display="${process:0:20}"
            
            printf " ${C_CYAN}%-5s${C_RESET} " "$proto"
            printf "${C_PURPLE}%-12s${CRESET} " "$state"
            printf "${C_GREEN}%-25s${C_RESET}" "$local_display"
            printf " ${C_YELLOW}%-25s${C_RESET}" "$remote_display"
            printf " ${C_WHITE}%-15s${CRESET}\n" "$process_display"
            
            conn_count=$((conn_count + 1))
        done
        unset IFS
        echo -e "${C_GRAY}Total de conexões exibidas: $conn_count${C_RESET}"
    else
        echo -e " ${C_GRAY}Nenhuma conexão ativa${C_RESET}"
    fi
    
    echo -e "${C_BORDER}────────────────────────────────────────────────────────────${C_RESET}"
    
    # SEÇÃO: TOP PROCESSOS - VERSÃO CORRIGIDA
    echo -e "${C_BG_SECTION}${C_WHITE}🚀 TOP PROCESSOS${CRESET}"
    # Usando uma abordagem mais robusta para extrair os dados do ps
    ps -eo pid,comm,%cpu,%mem --sort=-%cpu --no-headers | head -5 | while read line; do
        # Extrai os campos de forma segura
        pid=$(echo "$line" | awk '{print $1}')
        cmd=$(echo "$line" | awk '{$1=""; print $0}' | awk '{
            # Remove os campos de CPU e MEM que estão no final
            for(i=1;i<=NF-2;i++) printf $i " ";
            print ""
        }' | sed 's/^ *//;s/ *$//')
        
        # Pega CPU e MEM dos últimos campos
        cpu=$(echo "$line" | awk '{print $(NF-1)}')
        mem=$(echo "$line" | awk '{print $NF}')
        
        # Limita o comando a 25 caracteres
        cmd_display="${cmd:0:25}"
        
        # Garante que CPU e MEM são números válidos
        if [[ ! "$cpu" =~ ^[0-9.]+$ ]]; then
            cpu="0.0"
        fi
        
        if [[ ! "$mem" =~ ^[0-9.]+$ ]]; then
            mem="0.0"
        fi
        
        # Formata a saída de forma segura
        printf " PID:%-6s ${C_CYAN}%-25s${CRESET} CPU:${C_RED}%5.1f%%${CRESET} RAM:${C_ORANGE}%5.1f%%${CRESET}\n" \
               "$pid" "$cmd_display" "$cpu" "$mem"
    done
    
    echo -e "${C_BORDER}════════════════════════════════════════════════════════════${CRESET}"
    echo -e "${C_GRAY} Atualizado: $(date '+%H:%M:%S') | Interface: $INTERFACE | ${C_RED}Ctrl+C para sair${CRESET}"
    
    # Limpa o resto da tela
    tput ed
    
    sleep $REFRESH
done

